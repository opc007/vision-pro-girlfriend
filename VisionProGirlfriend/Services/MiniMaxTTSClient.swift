import Foundation

enum MiniMaxTTSError: LocalizedError {
    case missingAPIKey
    case badURL
    case server(code: Int, message: String)
    case timedOut(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "没有读到 MINIMAX_API_KEY 环境变量。"
        case .badURL:
            return "MINIMAX_WS_BASE_URL 拼出来的 WebSocket 地址不合法。"
        case let .server(code, message):
            return "MiniMax 返回错误 \(code)：\(message)"
        case let .timedOut(what):
            return "等待 MiniMax \(what) 超时。"
        case let .transport(message):
            return "MiniMax WebSocket 连接异常：\(message)"
        }
    }
}

protocol MiniMaxTTSClientDelegate: AnyObject {
    /// 攒够一整句时回调，音频是已经 hex 解码过的 MP3。
    func ttsClient(_ client: MiniMaxTTSClient, didProduceSentence mp3Data: Data)
    /// 会话状态变化，用来更新 UI 提示。
    func ttsClient(_ client: MiniMaxTTSClient, didChangeState state: MiniMaxTTSClient.State)
}

/// MiniMax 双向流式 TTS（`/ws/v1/t2a_v2_bidi`）。
///
/// 为什么是双向：服务端自己按标点攒句，所以可以把 DeepSeek 的流式 token 直接灌进来，
/// 不用客户端判断句子边界。
///
/// 事件流：
/// `connected_success` → 发 `task_start` → `task_started` → 发若干 `task_continue`
/// → 音频走 `task_continued` → 一轮结束发 `task_flush` → `task_flushed`（连接还在，下一轮继续用）
/// 打断发 `task_cancel`；彻底关闭发 `task_finish`。
/// 服务端不会主动发 ping，空闲约 120 秒会被踢（2201），所以这里自己每 30 秒 ping 一次。
final class MiniMaxTTSClient {

    enum State: Equatable {
        case idle
        case connecting
        case ready
        case speaking
        case failed(String)
    }

    weak var delegate: MiniMaxTTSClientDelegate?

    let audioPlayer: TTSAudioPlayer

    private let config: AppConfig
    private let session: URLSession
    private let stateQueue = DispatchQueue(label: "com.opc007.visionpro.tts-ws")

    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var flushTask: DispatchWorkItem?
    private var retryTask: DispatchWorkItem?

    /// 最近一条 task_continue 的原文，2205 时要重发
    private var lastSentText = ""
    private var retryCount = 0

    private var state: State = .idle
    private var pendingText = ""
    private var sentenceBuffer = Data()

    /// 等待某个服务端事件的地方。每个等待者有独立 token，
    /// 超时块只会干掉自己那一个，不会误伤后来注册的。
    private struct EventWaiter {
        let id: UUID
        let event: String
        let continuation: CheckedContinuation<Void, Error>
    }

    private var waiters: [UUID: EventWaiter] = [:]

    /// token 合并发送的间隔，120ms 足够把一串 token 攒成一条 task_continue。
    private let coalesceInterval: TimeInterval = 0.12

    init(config: AppConfig, audioPlayer: TTSAudioPlayer) {
        self.config = config
        self.audioPlayer = audioPlayer
        let configuration = URLSessionConfiguration.default
        // 断网时立刻失败，不要挂在 waitsForConnectivity 上干等
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
    }

    deinit {
        receiveTask?.cancel()
        pingTask?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil)
        // 万一还有人挂着 await，把它们放掉，不然那个 Task 会永远等下去
        let pending = waiters
        waiters = [:]
        for waiter in pending.values {
            waiter.continuation.resume(throwing: CancellationError())
        }
    }

    // MARK: - 对外接口

    /// 确保连接已建立且收到 `task_started`。可以放心重复调用，不会重发 task_start。
    func ensureStarted() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stateQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                switch self.state {
                case .ready, .speaking:
                    continuation.resume()
                case .connecting:
                    self.register(event: "task_started", continuation: continuation, timeout: 15)
                default:
                    self.register(event: "task_started", continuation: continuation, timeout: 15)
                    self.connectLocked()
                }
            }
        }
    }

    /// 逐 token 喂文本。内部按 ~120ms 合并成 `task_continue` 发出去。
    /// 连接还没就绪时会先攒着，`task_started` 之后自动补发。
    func append(_ text: String) {
        guard !text.isEmpty else { return }
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.pendingText += text
            guard self.flushTask == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.flushTask = nil
                self.flushPendingTextLocked()
            }
            self.flushTask = work
            self.stateQueue.asyncAfter(deadline: .now() + self.coalesceInterval, execute: work)
        }
    }

    /// 一轮说完了。催出服务端缓冲区里的尾句，音频下完就回来。
    /// 注意不能用 `task_finish`——那会关掉连接，多轮对话要复用同一条连接。
    func endTurn() async {
        try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stateQueue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                self.flushTask?.cancel()
                self.flushTask = nil
                self.flushPendingTextLocked()

                guard self.state == .ready || self.state == .speaking else {
                    continuation.resume()
                    return
                }
                self.register(event: "task_flushed", continuation: continuation, timeout: 8)
                self.send(["event": "task_flush"])
            }
        }
    }

    /// 用户插话：丢掉没发出去的文本、丢掉攒着的音频，并通知服务端中断合成。
    func interrupt() {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.flushTask?.cancel()
            self.flushTask = nil
            self.retryTask?.cancel()
            self.retryTask = nil
            self.lastSentText = ""
            self.retryCount = 0
            self.pendingText = ""
            self.sentenceBuffer.removeAll()
            self.audioPlayer.stopAll()
            if self.state == .ready || self.state == .speaking {
                self.send(["event": "task_cancel"])
            }
        }
    }

    /// 彻底断开（App 退出、用户主动关闭语音）。
    func stop() {
        stateQueue.async { [weak self] in
            guard let self else { return }
            if self.state == .ready || self.state == .speaking {
                self.send(["event": "task_finish"])
            }
            self.closeLocked()
        }
    }

    // MARK: - 连接

    private func connectLocked() {
        guard config.hasMiniMaxKey else {
            failLocked(MiniMaxTTSError.missingAPIKey)
            return
        }
        guard let url = config.minimaxBidiTTSURL else {
            failLocked(MiniMaxTTSError.badURL)
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(config.minimaxAPIKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20

        let task = session.webSocketTask(with: request)
        socket = task
        transition(to: .connecting)
        task.resume()

        startReceiveLoop(task)
        startPingLoop(task)
    }

    private func startReceiveLoop(_ task: URLSessionWebSocketTask) {
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    // 必须先强绑定出常量 self：weak 捕获是个 var，
                    // 直接把它塞进下面嵌套的 async 闭包里在 Swift 5 下也是编译错误。
                    guard let self else { return }
                    switch message {
                    case let .string(text):
                        self.stateQueue.async { self.handle(text: text) }
                    case let .data(data):
                        guard let text = String(data: data, encoding: .utf8) else { continue }
                        self.stateQueue.async { self.handle(text: text) }
                    @unknown default:
                        continue
                    }
                } catch {
                    guard let self else { return }
                    self.stateQueue.async {
                        self.failLocked(MiniMaxTTSError.transport(error.localizedDescription))
                    }
                    return
                }
            }
        }
    }

    private func startPingLoop(_ task: URLSessionWebSocketTask) {
        // 服务端不会主动发 ping，空闲约 120 秒会返回 2201 断开，这里自己保活。
        pingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                guard !Task.isCancelled else { return }
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    task.sendPing { _ in continuation.resume() }
                }
            }
        }
    }

    // MARK: - 收事件

    private func handle(text: String) {
        guard let data = text.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }

        let event = json["event"] as? String
        let audioHex = (json["data"] as? [String: Any])?["audio"] as? String
        // 官方文档里音频帧的样例有的带 event、有的不带，只要带 data.audio 就当音频帧处理，
        // 否则会整段音频被丢掉。
        let isAudioFrame = (event == nil || event == "task_continued")

        if let base = json["base_resp"] as? [String: Any],
           let code = (base["status_code"] as? NSNumber)?.intValue,
           code != 0 {
            // 2205 = 待合成文本堆太多了（发得比合成快）。
            // 官方说明这是软失败：连接和会话都不关，只要晚点重发这一条 task_continue。
            if code == 2205 {
                scheduleRetryLocked()
                return
            }
            failLocked(MiniMaxTTSError.server(code: code, message: (base["status_msg"] as? String) ?? "未知错误"))
            return
        }

        if isAudioFrame {
            if let audioHex, !audioHex.isEmpty {
                if let bytes = Data(hexEncoded: audioHex) {
                    sentenceBuffer.append(bytes)
                } else {
                    NSLog("[TTS] 音频 hex 解码失败，长度 \(audioHex.count)")
                }
            }
            if (json["is_final"] as? NSNumber)?.boolValue == true {
                flushSentenceLocked()
            }
        }

        guard let event else { return }

        switch event {
        case "connected_success":
            sendTaskStartLocked()

        case "task_started":
            transition(to: .ready)
            resumeWaiters(for: "task_started", with: .success(()))
            flushPendingTextLocked()

        case "task_continued", "sentence_start":
            // 音频帧上面已经处理完了
            break

        case "sentence_end":
            flushSentenceLocked()

        case "task_canceled":
            flushSentenceLocked()
            transition(to: .ready)
            resumeWaiters(for: "task_canceled", with: .success(()))

        case "task_flushed":
            flushSentenceLocked()
            transition(to: .ready)
            resumeWaiters(for: "task_flushed", with: .success(()))

        case "task_finished":
            flushSentenceLocked()
            resumeWaiters(for: "task_finished", with: .success(()))
            closeLocked()

        case "task_failed":
            let message = ((json["base_resp"] as? [String: Any])?["status_msg"] as? String) ?? "task_failed"
            failLocked(MiniMaxTTSError.server(code: -1, message: message))

        default:
            break
        }
    }

    // MARK: - 发事件

    private func sendTaskStartLocked() {
        send([
            "event": "task_start",
            "model": config.minimaxModel,
            "language_boost": "Chinese",
            "voice_setting": [
                "voice_id": config.minimaxVoiceID,
                "speed": 1.0,
                "vol": 1.0,
                "pitch": 0
            ],
            "audio_setting": [
                "sample_rate": 32000,
                "bitrate": 128000,
                "format": "mp3",
                "channel": 1
            ],
            "session_id": "visionpro-\(UUID().uuidString.prefix(8))"
        ])
    }

    private func flushPendingTextLocked() {
        guard state == .ready || state == .speaking else { return }
        let text = pendingText
        pendingText = ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // 注意：原文标点必须保留，MiniMax 靠标点断句，删掉会导致朗读一顿一顿的。
        lastSentText = text
        retryCount = 0
        send(["event": "task_continue", "text": text])
    }

    /// 2205 的退避重发：晚一点把上一条 task_continue 再发一遍，不重连也不重发 task_start。
    private func scheduleRetryLocked() {
        guard !lastSentText.isEmpty else { return }
        guard retryCount < 3 else {
            NSLog("[TTS] 2205 重试 3 次仍失败，放弃这一条")
            return
        }
        retryCount += 1
        retryTask?.cancel()
        let text = lastSentText
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.send(["event": "task_continue", "text": text])
        }
        retryTask = work
        let delay = 0.6 * Double(retryCount)
        NSLog("[TTS] 2205，第 \(retryCount) 次重发，\(delay) 秒后")
        stateQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func send(_ payload: [String: Any]) {
        guard let socket,
              JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8)
        else { return }

        socket.send(.string(text)) { [weak self] error in
            guard let error, let self else { return }
            self.stateQueue.async {
                self.failLocked(MiniMaxTTSError.transport(error.localizedDescription))
            }
        }
    }

    // MARK: - 状态机辅助

    private func flushSentenceLocked() {
        guard !sentenceBuffer.isEmpty else { return }
        let data = sentenceBuffer
        sentenceBuffer.removeAll(keepingCapacity: true)
        transition(to: .speaking)
        delegate?.ttsClient(self, didProduceSentence: data)
    }

    private func transition(to newState: State) {
        guard newState != state else { return }
        state = newState
        delegate?.ttsClient(self, didChangeState: newState)
    }

    private func register(event: String, continuation: CheckedContinuation<Void, Error>, timeout: TimeInterval) {
        let id = UUID()
        waiters[id] = EventWaiter(id: id, event: event, continuation: continuation)

        stateQueue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            // 按 token 取，取不到说明这个等待者已经被事件或别的超时块收走了
            guard let self, let waiter = self.waiters.removeValue(forKey: id) else { return }
            waiter.continuation.resume(throwing: MiniMaxTTSError.timedOut(event))
        }
    }

    private func resumeWaiters(for event: String, with result: Result<Void, Error>) {
        let ids = waiters.values.filter { $0.event == event }.map(\.id)
        for id in ids {
            guard let waiter = waiters.removeValue(forKey: id) else { continue }
            waiter.continuation.resume(with: result)
        }
    }

    private func resumeAllWaiters(with result: Result<Void, Error>) {
        let all = waiters
        waiters = [:]
        for waiter in all.values {
            waiter.continuation.resume(with: result)
        }
    }

    private func closeLocked() {
        // 先把还挂着的人放掉，再拆连接，否则他们会干等到超时
        resumeAllWaiters(with: .failure(CancellationError()))
        cancelPendingWorkLocked()
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        pendingText = ""
        sentenceBuffer.removeAll()
        transition(to: .idle)
    }

    private func failLocked(_ error: Error) {
        resumeAllWaiters(with: .failure(error))
        cancelPendingWorkLocked()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        pendingText = ""
        sentenceBuffer.removeAll()
        transition(to: .failed(error.localizedDescription))
    }

    private func cancelPendingWorkLocked() {
        receiveTask?.cancel()
        receiveTask = nil
        pingTask?.cancel()
        pingTask = nil
        flushTask?.cancel()
        flushTask = nil
        retryTask?.cancel()
        retryTask = nil
        lastSentText = ""
        retryCount = 0
    }
}
