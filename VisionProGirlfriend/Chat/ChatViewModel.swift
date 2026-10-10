import Foundation
import SwiftUI

/// 聊天窗口的 ViewModel。
///
/// 职责分工：
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
    @Published private(set) var statusText = "准备中…"

    let audioPlayer = TTSAudioPlayer()

    private let config: AppConfig
    private let deepSeekClient: DeepSeekClient
    private var ttsClient: MiniMaxTTSClient?
    private var turnTask: Task<Void, Never>?
    private var currentTurnID: UUID?

    private let greeting = "你好呀，我是七宝～今天想聊点什么？"

    init(config: AppConfig = AppConfig()) {
        self.config = config
        self.deepSeekClient = DeepSeekClient(config: config)
        self.messages = [ChatMessage(role: .assistant, text: greeting)]

        let client = MiniMaxTTSClient(config: config, audioPlayer: audioPlayer)
        client.delegate = self
        self.ttsClient = client
    }

    // MARK: - 生命周期

    @MainActor
    func bootstrap() {
        audioPlayer.prepare()

        if !config.missingKeysDescription.isEmpty {
            statusText = config.missingKeysDescription
        } else {
            statusText = "\(config.deepSeekModel) · \(config.minimaxModel)（\(config.minimaxVoiceID)）"
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
        ttsClient?.stop()
        audioPlayer.stopAll()
    }

    // MARK: - 发送

    @MainActor
    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isReplying else { return }

        input = ""
        isReplying = true
        messages.append(ChatMessage(role: .user, text: text))

        // 第一轮把招呼语换掉，别让模型把招呼语当上下文
        if messages.count == 2, messages.first?.text == greeting {
            messages.removeFirst()
        }

        // 第一个是七宝的人设，后面才是这轮对话
        var history = [DeepSeekClient.Message(role: "system", content: config.personaPrompt)]
        history.append(contentsOf: messages.map {
            DeepSeekClient.Message(role: $0.role.rawValue, content: $0.text)
        })
        let replyID = UUID()
        messages.append(ChatMessage(id: replyID, role: .assistant, text: ""))

        statusText = "七宝正在想…"
        audioPlayer.stopAll()

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
                    tts.append(delta)
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
        statusText = "重新开始"
    }

    // MARK: - 内部

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
        statusText = audioPlayer.isSpeaking ? "七宝在说…" : "想好要聊什么了吗？"
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
        statusText = text
    }

    @MainActor
    private func handleSentence(_ mp3Data: Data) {
        audioPlayer.enqueue(mp3: mp3Data)
        if isReplying { statusText = "七宝在说…" }
    }

    @MainActor
    private func handleState(_ state: MiniMaxTTSClient.State) {
        switch state {
        case let .failed(message):
            statusText = "语音连接异常：\(message)"
        case .ready, .idle:
            if !isReplying { statusText = "想好要聊什么了吗？" }
        case .connecting:
            statusText = "语音通道连接中…"
        case .speaking:
            statusText = "七宝在说…"
        }
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
