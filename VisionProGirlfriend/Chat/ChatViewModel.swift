import Foundation
import SwiftUI

/// 聊天窗口的 ViewModel。
///
/// 职责分工：
/// - `SpeechRecognizerService` 负责麦克风 → 文字
/// - `DeepSeekClient` 负责拿流式文本
/// - `MiniMaxTTSClient` 负责把文本变成声音
/// - `TTSAudioPlayer` 负责在设备上播，并把音量喂给口型
///
/// 所有会改 UI 状态的方法都标了 `@MainActor`；`init` 保持非隔离，
/// 这样 `@StateObject` / `@EnvironmentObject` 注入时不会有 actor 隔离问题。
final class ChatViewModel: ObservableObject {

    @Published private(set) var messages: [ChatMessage] = []
    @Published var input: String = ""
    @Published private(set) var isReplying = false
    @Published private(set) var isSpeaking = false
    @Published private(set) var statusText = "准备中…"

    /// 语音输入相关
    @Published private(set) var isListening = false
    @Published private(set) var partialSpeechText = ""
    @Published private(set) var speechAvailable = true
    /// 麦克风电平，给 UI 画条
    @Published private(set) var micLevel: Float = 0

    let audioPlayer = TTSAudioPlayer()
    let speechRecognizer = SpeechRecognizerService()
    /// 3D 该摆什么姿态。渲染线程读，ViewModel 写。
    let avatarState = AvatarStateSignal()

    private let config: AppConfig
    private let deepSeekClient: DeepSeekClient
    private var ttsClient: MiniMaxTTSClient?
    private var turnTask: Task<Void, Never>?
    private var currentTurnID: UUID?
    private var micLevelTask: Task<Void, Never>?

    private let greeting = "你好呀，我是七宝～今天想聊点什么？"

    /// 发给模型的历史预算（字符数）。超了就把最早的丢掉，长对话不会把 token 撑爆。
    private let historyCharBudget = 4_000

    /// 3D 姿态只有一条推导路径，避免各处改了状态忘了同步
    private func refreshAvatarState() {
        let state: AvatarState
        if isSpeaking { state = .speaking }
        else if isListening { state = .listening }
        else if isReplying { state = .thinking }
        else { state = .idle }
        avatarState.set(state)
    }

    init(config: AppConfig = AppConfig()) {
        self.config = config
        self.deepSeekClient = DeepSeekClient(config: config)
        self.messages = [ChatMessage(role: .assistant, text: greeting)]

        let client = MiniMaxTTSClient(config: config, audioPlayer: audioPlayer)
        client.delegate = self
        self.ttsClient = client

        speechRecognizer.delegate = self

        // 真的播完一段（不是「刚排进队列」），再把状态切回空闲
        audioPlayer.setPlaybackFinishedHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.handlePlaybackFinished()
            }
        }
    }

    // MARK: - 生命周期

    @MainActor
    func bootstrap() {
        audioPlayer.prepare()

        speechAvailable = speechRecognizer.isAvailable(localeIdentifier: config.asrLocale)
        if !speechAvailable {
            statusText = "这台设备不支持 \(config.asrLocale) 语音识别，先用文字聊。"
            return
        }

        if !config.missingKeysDescription.isEmpty {
            statusText = config.missingKeysDescription
        } else {
            statusText = "\(config.deepSeekModel) · \(config.minimaxModel)（\(config.minimaxVoiceID)）"
        }
    }

    // MARK: - 语音输入

    /// 点一下开始，再点一下结束。说完停顿 1.6 秒也会自己结束。
    @MainActor
    func toggleListening() {
        if isListening {
            speechRecognizer.stop()
            return
        }
        startListening()
    }

    @MainActor
    func startListening() {
        guard !isListening else { return }

        if !speechAvailable {
            speechAvailable = speechRecognizer.isAvailable(localeIdentifier: config.asrLocale)
            if !speechAvailable {
                statusText = "这台设备不支持 \(config.asrLocale) 语音识别。"
                return
            }
        }

        statusText = "正在开麦…"

        Task { [weak self] in
            guard let self else { return }

            let granted = await self.speechRecognizer.requestAuthorization()
            guard granted else {
                self.handleSpeechDenied()
                return
            }

            // 边听边插话：她正在说的话先停下来，不然会把自己的声音当成你说的话
            self.interruptSpeaking()

            do {
                try self.speechRecognizer.start(localeIdentifier: self.config.asrLocale)
                self.handleListeningStarted()
            } catch {
                self.handleSpeechError(error)
            }
        }
    }

    @MainActor
    private func handleListeningStarted() {
        isListening = true
        refreshAvatarState()
        partialSpeechText = ""
        statusText = "在听，说完停顿一下就行"
        startMicLevelPolling()
    }

    @MainActor
    private func handleListeningStopped() {
        isListening = false
        refreshAvatarState()
        partialSpeechText = ""
        micLevelTask?.cancel()
        micLevelTask = nil
        micLevel = 0
    }

    @MainActor
    private func handleSpeechDenied() {
        isListening = false
        statusText = "需要麦克风和语音识别权限才能说话。设置里开一下，或者继续打字。"
    }

    @MainActor
    private func handleSpeechError(_ error: Error) {
        handleListeningStopped()
        statusText = error.localizedDescription
    }

    /// 电平条的数据源在音频线程上，定时搬一次到主线程
    @MainActor
    private func startMicLevelPolling() {
        micLevelTask?.cancel()
        micLevelTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let level = self.speechRecognizer.inputLevel.value
                if abs(level - self.micLevel) > 0.02 {
                    self.micLevel = level
                }
                try? await Task.sleep(nanoseconds: 60_000_000)
            }
        }
    }

    @MainActor
    func setNote(_ note: String) {
        statusText = note
    }

    @MainActor
    func shutdown() {
        turnTask?.cancel()
        turnTask = nil
        micLevelTask?.cancel()
        micLevelTask = nil
        speechRecognizer.cancel()
        isListening = false
        avatarState.set(.idle)
        ttsClient?.stop()
        audioPlayer.stopAll()
    }

    // MARK: - 发送

    @MainActor
    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isReplying else { return }
        input = ""
        startTurn(with: text)
    }

    /// 打字和语音最终都汇到这里
    @MainActor
    private func startTurn(with text: String) {
        guard !text.isEmpty, !isReplying else { return }

        isReplying = true
        refreshAvatarState()
        messages.append(ChatMessage(role: .user, text: text))

        // 第一轮把招呼语换掉，别让模型把招呼语当上下文
        if messages.count == 2, messages.first?.text == greeting {
            messages.removeFirst()
        }

        // 第一个是七宝的人设，后面才是这轮对话（超预算的从最早的开始丢）
        let history = buildHistory()
        let replyID = UUID()
        messages.append(ChatMessage(id: replyID, role: .assistant, text: ""))

        statusText = "七宝正在想…"
        audioPlayer.stopAll()
        isSpeaking = false
        refreshAvatarState()

        guard let tts = ttsClient else {
            statusText = "语音通道没建起来"
            return
        }

        // 记下这一轮的编号：被新的一轮/打断顶掉之后，旧任务回来的收尾就不要再改 UI 了。
        let turnID = UUID()
        currentTurnID = turnID

        turnTask?.cancel()
        turnTask = Task { [weak self] in
            guard let self else { return }
            do {
                // 先把语音通道拉起来，别等模型出字了才开始连
                try await tts.ensureStarted()

                try await self.deepSeekClient.stream(messages: history) { delta in
                    // 气泡里显示原文，喂给 TTS 的是清洗过的版本
                    tts.append(SpeechTextSanitizer.sanitize(delta))
                    Task { @MainActor [weak self] in
                        self?.appendToReply(delta, id: replyID)
                    }
                }

                await tts.endTurn()
                self.finishTurn(replyID: replyID, turnID: turnID)
            } catch let error as URLError where error.code == .cancelled {
                self.finishTurn(replyID: replyID, turnID: turnID)
            } catch is CancellationError {
                self.finishTurn(replyID: replyID, turnID: turnID)
            } catch {
                self.failTurn(error, replyID: replyID, turnID: turnID)
            }
        }
    }

    /// 插话打断：文本、音频、这一轮生成全停。
    @MainActor
    func interruptSpeaking() {
        turnTask?.cancel()
        turnTask = nil
        currentTurnID = nil
        ttsClient?.interrupt()
        audioPlayer.stopAll()
        isReplying = false
        isSpeaking = false
        refreshAvatarState()
        statusText = "已打断"
    }

    @MainActor
    func clearChat() {
        turnTask?.cancel()
        currentTurnID = nil
        ttsClient?.interrupt()
        audioPlayer.stopAll()
        messages = [ChatMessage(role: .assistant, text: greeting)]
        isReplying = false
        isSpeaking = false
        refreshAvatarState()
        statusText = "重新开始"
    }

    // MARK: - 内部

    /// 拼这次要发给 DeepSeek 的消息。
    /// 第一条永远是七宝的人设；对话历史按字符预算从新到旧取，超预算的最早那条丢掉。
    @MainActor
    private func buildHistory() -> [DeepSeekClient.Message] {
        var history = [DeepSeekClient.Message(role: "system", content: config.personaPrompt)]

        var used = 0
        var picked: [ChatMessage] = []
        for message in messages.reversed() {
            guard !message.text.isEmpty else { continue }
            let cost = message.text.count
            // picked 为空时无条件收下，保证最新那条（用户刚发的）在里面
            if used + cost > historyCharBudget, !picked.isEmpty { break }
            used += cost
            picked.append(message)
        }

        history.append(contentsOf: picked.reversed().map {
            DeepSeekClient.Message(role: $0.role.rawValue, content: $0.text)
        })
        return history
    }

    @MainActor
    private func appendToReply(_ delta: String, id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text += delta
    }

    @MainActor
    private func finishTurn(replyID: UUID, turnID: UUID) {
        guard currentTurnID == turnID else { return }
        if let index = messages.firstIndex(where: { $0.id == replyID }),
           messages[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages[index].text = "（没拿到内容，检查一下 Key 和网络）"
        }
        isReplying = false
        refreshAvatarState()
        statusText = isSpeaking ? "七宝在说…" : "想好要聊什么了吗？"
    }

    @MainActor
    private func failTurn(_ error: Error, replyID: UUID, turnID: UUID) {
        guard currentTurnID == turnID else { return }
        let text = "出错了：\(error.localizedDescription)"
        if let index = messages.firstIndex(where: { $0.id == replyID }) {
            if messages[index].text.isEmpty {
                messages[index].text = text
            } else {
                messages[index].text += "\n\n（\(text)）"
            }
        }
        isReplying = false
        refreshAvatarState()
        statusText = text
    }

    @MainActor
    private func handleSentence(_ mp3Data: Data) {
        audioPlayer.enqueue(mp3: mp3Data)
        isSpeaking = true
        refreshAvatarState()
        if isReplying { statusText = "七宝在说…" }
    }

    /// 播放器确认真的播完了（已留了静音间隔，不会每句跳一次）
    @MainActor
    private func handlePlaybackFinished() {
        isSpeaking = audioPlayer.isSpeaking
        refreshAvatarState()
        if isReplying { statusText = "七宝在说…" }
        else { statusText = "想好要聊什么了吗？" }
    }

    @MainActor
    private func handleState(_ state: MiniMaxTTSClient.State) {
        switch state {
        case let .failed(message):
            statusText = "语音连接异常：\(message)"
        case .ready, .idle:
            if !isReplying, !isListening, !isSpeaking { statusText = "想好要聊什么了吗？" }
        case .connecting:
            statusText = "语音通道连接中…"
        case .speaking:
            statusText = "七宝在说…"
        }
    }

    // MARK: - 语音识别结果

    @MainActor
    private func handleSpeechPartial(_ text: String) {
        partialSpeechText = text
    }

    /// 识别结束：直接当成一轮用户发言发出去
    @MainActor
    private func handleSpeechFinal(_ text: String) {
        handleListeningStopped()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusText = "没听清，再说一次？"
            return
        }
        // 她可能还在说上一句。先插话再发，否则 startTurn 的 !isReplying
        // 会把这句话静默吞掉 —— 用户说了话却什么都没发生。
        if isReplying {
            interruptSpeaking()
        }
        startTurn(with: trimmed)
    }

    @MainActor
    private func handleSpeechFailure(_ message: String) {
        handleListeningStopped()
        statusText = "语音输入出错：\(message)"
    }
}

// MARK: - MiniMaxTTSClientDelegate

extension ChatViewModel: MiniMaxTTSClientDelegate {

    nonisolated func ttsClient(_ client: MiniMaxTTSClient, didProduceSentence mp3Data: Data) {
        Task { @MainActor [weak self] in
            self?.handleSentence(mp3Data)
        }
    }

    nonisolated func ttsClient(_ client: MiniMaxTTSClient, didChangeState state: MiniMaxTTSClient.State) {
        Task { @MainActor [weak self] in
            self?.handleState(state)
        }
    }
}

// MARK: - SpeechRecognizerServiceDelegate

extension ChatViewModel: SpeechRecognizerServiceDelegate {

    nonisolated func speechRecognizer(_ service: SpeechRecognizerService, didUpdatePartialText text: String) {
        Task { @MainActor [weak self] in
            self?.handleSpeechPartial(text)
        }
    }

    nonisolated func speechRecognizer(_ service: SpeechRecognizerService, didFinishWith text: String) {
        Task { @MainActor [weak self] in
            self?.handleSpeechFinal(text)
        }
    }

    nonisolated func speechRecognizer(_ service: SpeechRecognizerService, didFailWith message: String) {
        Task { @MainActor [weak self] in
            self?.handleSpeechFailure(message)
        }
    }
}
