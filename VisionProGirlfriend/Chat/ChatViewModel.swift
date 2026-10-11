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
    /// 权限弹窗 + 引擎启动这一段的进行中标记（这段时间里 `isListening` 还是 false）
    private var isStartingListening = false
    /// 按住说话松手早于「真的开始」时置位，等开始了立刻收
    private var stopWhenListeningStarts = false
    /// 授权等待超时的看门狗
    private var permissionWatchdog: Task<Void, Never>?

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

        // 模拟器上这个经常是 false（没装离线模型），只是个提示，不是开关
        speechAvailable = speechRecognizer.isAvailable(localeIdentifier: config.asrLocale)

        var notes: [String] = []
        if !speechAvailable {
            notes.append("这台设备可能不支持 \(config.asrLocale) 离线识别，仍可试一次语音输入")
        }
        if !config.missingKeysDescription.isEmpty {
            notes.append("还差 Key：\(config.missingKeysShort)")
        }
        statusText = notes.isEmpty
            ? "\(config.deepSeekModel) · \(config.minimaxModel)（\(config.minimaxVoiceID)）"
            : notes.joined(separator: " · ")
    }

    // MARK: - 语音输入

    /// 按住说话：**按下**就开麦。这一下必须先把她的声音停掉，
    /// 否则麦克风会把她自己正在说的话听进来，然后当成你说的话发出去。
    @MainActor
    func beginHoldToTalk() {
        guard !isListening, !isStartingListening else { return }
        stopWhenListeningStarts = false
        if isReplying || isSpeaking {
            interruptSpeaking()
        }
        startListening()
    }

    /// 按住说话：**松手**就收尾，识别结果会自动发出去。
    /// （说完停顿 1.6 秒也会自己收，所以松手早一点晚一点都能用）
    @MainActor
    func endHoldToTalk() {
        if isListening {
            speechRecognizer.stop()
            return
        }
        // ⚠️ 关键：按下之后要等权限弹窗 + 引擎启动，`isListening` 这会儿往往
        // 还是 false。如果这时候直接 return，松手就被吞了 —— 麦克风会一直开着，
        // 用户表现就是「松手了但还在听 / 一直不发送」。
        // 所以记下来，等真的开始了立刻收。
        guard isStartingListening else { return }
        stopWhenListeningStarts = true
        statusText = "松手了，正在收尾…"
    }

    /// 识别中想反悔：丢掉这次识别，不发送。
    @MainActor
    func cancelListening() {
        guard isListening else { return }
        speechRecognizer.cancel()
        handleListeningStopped()
        statusText = "这次没发送"
    }

    /// 轻点一下：开麦并保持，再轻点一下才收。
    /// 和「按住说话」共存——按得久走按住路径，按得松走这个路径。
    @MainActor
    func toggleListening() {
        if isListening {
            speechRecognizer.stop()
        } else {
            beginHoldToTalk()
        }
    }

    @MainActor
    func startListening() {
        guard !isListening, !isStartingListening else { return }
        isStartingListening = true
        stopWhenListeningStarts = false

        // `isAvailable == false` 在模拟器上是常态，所以**不能**因此就不开麦：
        // 照样往下走，真起不来再给明确原因。（以前在这里直接 return，
        // 再加上按钮上的 `.disabled`，用户点麦就是一点反应都没有）
        if !speechAvailable {
            speechAvailable = speechRecognizer.isAvailable(localeIdentifier: config.asrLocale)
        }

        statusText = "正在开麦…"
        startPermissionWatchdog()

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

    /// 权限弹窗在模拟器上不一定弹得出来，等下去用户只会觉得「没反应」。
    /// 超时就直接告诉他去哪儿开，别让人干等。
    private func startPermissionWatchdog() {
        permissionWatchdog?.cancel()
        permissionWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled else { return }
            guard let self, self.isStartingListening, !self.isListening else { return }
            self.isStartingListening = false
            self.statusText = "开麦卡住了：没等到麦克风 / 语音识别授权。到「设置 ▸ 隐私与安全性」里把麦克风和语音识别打开，再点一次麦克风。"
        }
    }

    @MainActor
    private func handleListeningStarted() {
        isStartingListening = false
        permissionWatchdog?.cancel()
        permissionWatchdog = nil
        isListening = true
        refreshAvatarState()
        partialSpeechText = ""

        // 按住说话松手比「真的开始」早：这时立刻收，否则麦克风一直开着
        if stopWhenListeningStarts {
            stopWhenListeningStarts = false
            speechRecognizer.stop()
            return
        }

        statusText = "在听，说完停顿一下就行"
        startMicLevelPolling()
    }

    @MainActor
    private func handleListeningStopped() {
        isListening = false
        isStartingListening = false
        stopWhenListeningStarts = false
        permissionWatchdog?.cancel()
        permissionWatchdog = nil
        refreshAvatarState()
        partialSpeechText = ""
        micLevelTask?.cancel()
        micLevelTask = nil
        micLevel = 0
    }

    @MainActor
    private func handleSpeechDenied() {
        isStartingListening = false
        stopWhenListeningStarts = false
        permissionWatchdog?.cancel()
        permissionWatchdog = nil
        isListening = false
        statusText = "需要麦克风和语音识别权限才能说话。到「设置 ▸ 隐私与安全性」里把麦克风和语音识别打开，或者继续打字。"
    }

    @MainActor
    private func handleSpeechError(_ error: Error) {
        handleListeningStopped()
        statusText = FriendlyError.message(for: error, context: .speech)
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
        permissionWatchdog?.cancel()
        permissionWatchdog = nil
        isStartingListening = false
        stopWhenListeningStarts = false
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
        // 之前无条件设成「已打断」，而开麦路径也会调它，
        // 于是「正在开麦…」的提示会被立刻盖掉，用户只看到「已打断」
        let hadSomething = isReplying || isSpeaking

        turnTask?.cancel()
        turnTask = nil
        currentTurnID = nil
        ttsClient?.interrupt()
        audioPlayer.stopAll()
        isReplying = false
        isSpeaking = false
        refreshAvatarState()
        if hadSomething {
            statusText = "已打断"
        }
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
        let text = FriendlyError.message(for: error, context: .chat)
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
            statusText = FriendlyError.ttsHint(forStateMessage: message)
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
