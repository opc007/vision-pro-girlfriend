import AVFoundation
import Foundation
import Speech

protocol SpeechRecognizerServiceDelegate: AnyObject {
    /// 识别中的临时结果，会被后续结果覆盖
    func speechRecognizer(_ service: SpeechRecognizerService, didUpdatePartialText text: String)
    /// 停止后拿到最终文本（可能为空）
    func speechRecognizer(_ service: SpeechRecognizerService, didFinishWith text: String)
    func speechRecognizer(_ service: SpeechRecognizerService, didFailWith message: String)
}

/// 语音输入：麦克风 → `SFSpeechRecognizer` → 文字 → 接现有的 DeepSeek → TTS 流程。
///
/// 用的是系统 Speech。模拟器上走 Apple 的服务端识别（所以模拟器要联网）；
/// 真机如果装了对应语言的离线模型会自动切离线，更快也不用把音频传出设备。
///
/// 生命周期：
/// - `start()`：装 tap、起引擎，流式出临时结果
/// - `stop()`：拆 tap + `endAudio()`，等一次最终结果；等不到就退回最后听到的临时结果
/// - `cancel()`：直接丢掉
final class SpeechRecognizerService {

    enum ServiceError: LocalizedError {
        case speechNotAuthorized
        case microphoneNotAuthorized
        case recognizerUnavailable(String)
        case engineStartFailed(String)

        var errorDescription: String? {
            switch self {
            case .speechNotAuthorized:
                return "没有语音识别权限，去「设置 ▸ 隐私与安全性 ▸ 语音识别」里打开。"
            case .microphoneNotAuthorized:
                return "没有麦克风权限，去「设置 ▸ 隐私与安全性 ▸ 麦克风」里打开。"
            case let .recognizerUnavailable(locale):
                return "这台设备不支持 \(locale) 语音识别。"
            case let .engineStartFailed(reason):
                return "麦克风打不开：\(reason)"
            }
        }
    }

    weak var delegate: SpeechRecognizerServiceDelegate?

    /// 麦克风输入电平 0…1，画电平条用
    let inputLevel = LevelSignal()

    /// 说太久自动收尾
    var maxDuration: TimeInterval = 30
    /// 静音多久算说完（秒）。说完自动结束，不用再点一次麦克风。
    var silenceTimeout: TimeInterval = 1.6
    /// 低��这个音量算「没在说话」
    private let voiceThreshold: Float = 0.12

    private(set) var isListening = false

    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var watchdog: DispatchSourceTimer?
    private var finalTimeout: DispatchWorkItem?

    private let lock = NSLock()
    private var latestPartial = ""
    private var hasInputTap = false
    private var isFinishing = false
    private var finalDelivered = false
    private var startedAt: Date = .distantPast
    private var lastVoiceActivity: Date = .distantPast

    // MARK: - 可用性

    func isAvailable(localeIdentifier: String) -> Bool {
        SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))?.isAvailable ?? false
    }

    /// 语音识别 + 麦克风两项权限
    @discardableResult
    func requestAuthorization() async -> Bool {
        let speechGranted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        guard speechGranted else { return false }
        return await AudioSessionController.requestMicrophonePermission()
    }

    // MARK: - 录音

    func start(localeIdentifier: String) throws {
        lock.lock()
        let alreadyListening = isListening
        lock.unlock()
        guard !alreadyListening else { return }

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)),
              recognizer.isAvailable else {
            throw ServiceError.recognizerUnavailable(localeIdentifier)
        }

        lock.lock()
        latestPartial = ""
        finalDelivered = false
        isFinishing = false
        startedAt = Date()
        lastVoiceActivity = Date()
        lock.unlock()
        inputLevel.update(0)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        // 真机装了离线模型就走离线：更快，音频也不出设备。
        // 模拟器通常没有离线模型，硬开会直接识别失败，所以先问一句。
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let result {
                let text = result.bestTranscription.formattedString
                self.lock.lock()
                self.latestPartial = text
                self.lock.unlock()

                if result.isFinal {
                    self.deliverFinal(text)
                } else {
                    self.delegate?.speechRecognizer(self, didUpdatePartialText: text)
                }
            }

            if let error {
                // 我们主动 stop/cancel 引来的错误不算失败
                self.lock.lock()
                let expected = self.isFinishing
                self.lock.unlock()
                if !expected {
                    self.fail(error.localizedDescription)
                }
                self.cleanUp()
            }
        }

        // 音频：先把会话切到录音态，再装 tap
        AudioSessionController.activateForRecording()

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            request.append(buffer)
            self.updateInputLevel(buffer)
        }
        hasInputTap = true

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            cleanUp()
            throw ServiceError.engineStartFailed(error.localizedDescription)
        }

        lock.lock()
        isListening = true
        lock.unlock()

        startWatchdog()
    }

    /// 主动结束：拆 tap + `endAudio()`，等一次最终结果
    func stop() {
        lock.lock()
        guard isListening, !isFinishing else {
            lock.unlock()
            return
        }
        isFinishing = true
        lock.unlock()

        removeInputTap()
        audioEngine.stop()
        recognitionRequest?.endAudio()

        // 万一最终结果不来，就把最后听到的临时结果交出去，总比整句吞掉强
        finalTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let text = self.latestPartial
            self.lock.unlock()
            self.deliverFinal(text)
        }
        finalTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    /// 直接丢掉，不产出文本
    func cancel() {
        lock.lock()
        isFinishing = true
        lock.unlock()

        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        cleanUp()
    }

    // MARK: - 内部

    private var currentlyListening: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isListening
    }

    private func updateInputLevel(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        var sumOfSquares: Float = 0
        for index in 0..<frames {
            let sample = samples[index]
            sumOfSquares += sample * sample
        }
        let rms = (sumOfSquares / Float(frames)).squareRoot()
        let decibels: Float = 20 * log10(max(rms, 1e-6))
        let level = min(max((decibels + 55) / 55, 0), 1)

        inputLevel.update(level)

        if level > voiceThreshold {
            lock.lock()
            lastVoiceActivity = Date()
            lock.unlock()
        }
    }

    /// 看门狗：说完一段自动收尾，同时兜底最长时长
    private func startWatchdog() {
        watchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 0.3, repeating: 0.3)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.currentlyListening else {
                timer.cancel()
                return
            }

            self.lock.lock()
            let startedAt = self.startedAt
            let lastVoice = self.lastVoiceActivity
            let text = self.latestPartial
            self.lock.unlock()

            if Date().timeIntervalSince(startedAt) >= self.maxDuration {
                self.stop()
                return
            }
            // 还没听清任何东西就别急着收，否则一开口就被判成静音
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            if Date().timeIntervalSince(lastVoice) >= self.silenceTimeout {
                self.stop()
            }
        }
        watchdog = timer
        timer.resume()
    }

    private func deliverFinal(_ text: String) {
        lock.lock()
        guard !finalDelivered else {
            lock.unlock()
            return
        }
        finalDelivered = true
        lock.unlock()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        cleanUp()
        delegate?.speechRecognizer(self, didFinishWith: trimmed)
    }

    private func fail(_ message: String) {
        cleanUp()
        delegate?.speechRecognizer(self, didFailWith: message)
    }

    private func cleanUp() {
        removeInputTap()
        audioEngine.stop()
        watchdog?.cancel()
        watchdog = nil
        finalTimeout?.cancel()
        finalTimeout = nil
        recognitionTask?.finish()
        recognitionTask = nil
        recognitionRequest = nil
        inputLevel.update(0)

        lock.lock()
        isListening = false
        isFinishing = false
        lock.unlock()

        AudioSessionController.activateForPlayback()
    }

    private func removeInputTap() {
        guard hasInputTap else { return }
        hasInputTap = false
        // 没装过 tap 时调 removeTap 会触发 Objective-C 异常，所以上面必须先判断
        audioEngine.inputNode.removeTap(onBus: 0)
    }
}
