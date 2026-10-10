import AVFoundation
import Foundation

/// 设备播放层：把 MiniMax 下发的 MP3 分句解码成 PCM，塞进 `AVAudioEngine` 连着播，
/// 同时从播放节点实时取音量驱动口型。
///
/// 说明（也是留给 Cursor 的下一步）：MiniMax 的 **WebSocket 流式目前只支持 mp3**，
/// 没法边收边解。所以这里按句解码——`task_continued` 收到的块先攒起来，
/// 收到该句结束（`is_final` / `sentence_end`）后一次性解码并排队播放。
/// 首句大约多 0.3~0.8 秒延迟，之后句子之间是连续的。
/// 想要真正逐 chunk 无缝，后面可以换成 AudioToolbox 的 `AudioFileStreamOpen` 边收边解。
final class TTSAudioPlayer {

    let level = LevelSignal()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let queue = DispatchQueue(label: "com.opc007.visionpro.tts-audio", qos: .userInitiated)

    private var activeFormat: AVAudioFormat?
    private var isConfigured = false
    private var isTapInstalled = false

    private let speakingLock = NSLock()
    private var speakingCount = 0
    private var silenceTask: DispatchWorkItem?

    /// 播放**真正结束**（不是刚排进队列）时回调。
    /// 句子之间有空档，不能拿「队列空了」当结束信号，否则状态栏会在每句之间乱跳。
    /// 要静音一段时间后才算真的说完了。
    private var onPlaybackFinished: (() -> Void)?

    /// 现在是不是正在出声（主线程读，不会卡 UI）
    var isSpeaking: Bool {
        speakingLock.lock()
        defer { speakingLock.unlock() }
        return speakingCount > 0
    }

    func setPlaybackFinishedHandler(_ handler: @escaping () -> Void) {
        onPlaybackFinished = handler
    }

    private func setSpeaking(_ speaking: Bool) {
        speakingLock.lock()
        speakingCount = max(0, speakingCount + (speaking ? 1 : -1))
        let nowSilent = speakingCount == 0
        speakingLock.unlock()

        // tap 只在有声音流过时才回调，播完必须手动把音量归零，
        // 否则嘴会一直张着。
        if nowSilent {
            level.update(0)
        }
    }

    /// 连续静音超过阈值才算这一轮真的说完了。
    private func armSilenceTimerLocked() {
        silenceTask?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isSpeaking == false else { return }
            self.onPlaybackFinished?()
        }
        silenceTask = work
        queue.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    // MARK: - 对外接口

    /// 提前把音频引擎拉起来，避免第一次说话时卡一下。
    func prepare() {
        queue.async { [weak self] in
            self?.configureIfNeeded()
        }
    }

    /// 丢一整句 MP3 进来，异步解码播放。
    func enqueue(mp3 data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.configureIfNeeded()
            guard let target = self.activeFormat else { return }
            if let buffer = Self.decode(mp3: data, to: target) {
                self.schedule(buffer)
            }
        }
    }

    /// 打断播放（用户插话时用）。
    func stopAll() {
        queue.async { [weak self] in
            guard let self else { return }
            self.player.stop()
            self.silenceTask?.cancel()
            self.speakingLock.lock()
            self.speakingCount = 0
            self.speakingLock.unlock()
            self.level.update(0)
            self.configureIfNeeded()
            if !self.player.isPlaying { self.player.play() }
        }
    }

    // MARK: - 引擎配置

    private static var defaultOutputFormat: AVAudioFormat {
        #if os(visionOS)
        let hardwareSampleRate: Double = AVAudioSession.sharedInstance().sampleRate
        #else
        let hardwareSampleRate: Double = 48_000
        #endif
        let sampleRate: Double = hardwareSampleRate > 0 ? hardwareSampleRate : 48_000
        return AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)
            ?? AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    }

    private func configureIfNeeded() {
        guard !isConfigured else { return }
        isConfigured = true

        // 会话类别统一交给 AudioSessionController，播放和录音不要互相覆盖
        AudioSessionController.activateForPlayback()

        let format = Self.defaultOutputFormat
        activeFormat = format

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        installLevelTap(format: format)

        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                NSLog("[TTS] AVAudioEngine 启动失败：\(error.localizedDescription)")
            }
        }
    }

    private func installLevelTap(format: AVAudioFormat) {
        guard !isTapInstalled else { return }
        isTapInstalled = true
        player.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.handleTap(buffer)
        }
    }

    private func handleTap(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        var sumOfSquares: Float = 0
        for index in 0..<frames {
            let sample = samples[index]
            sumOfSquares += sample * sample
        }
        let rms = (sumOfSquares / Float(frames)).squareRoot()

        // -55dB 以下闭嘴，0dB 满嘴
        let decibels: Float = 20 * log10(max(rms, 1e-6))
        let target: Float = min(max((decibels + 55) / 55, 0), 1)

        // 起嘴快、闭嘴慢，看起来更自然
        let current = level.value
        let coefficient: Float = target > current ? 0.6 : 0.15
        level.update(current + (target - current) * coefficient)
    }

    // MARK: - 解码 + 排播

    private func schedule(_ buffer: AVAudioPCMBuffer) {
        if !engine.isRunning {
            try? engine.start()
        }
        if !player.isPlaying {
            player.play()
        }
        setSpeaking(true)
        silenceTask?.cancel()
        // 注意：Swift 里是 scheduleBuffer（单数），没有 scheduleBuffers 这个方法
        player.scheduleBuffer(
            buffer,
            at: nil,
            options: [],
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            guard let self else { return }
            self.setSpeaking(false)
            self.armSilenceTimerLocked()
        }
    }

    private static func decode(mp3 data: Data, to target: AVAudioFormat) -> AVAudioPCMBuffer? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tts-\(UUID().uuidString).mp3")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("[TTS] 临时文件写入失败：\(error.localizedDescription)")
            return nil
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            NSLog("[TTS] MP3 打不开：\(error.localizedDescription)")
            return nil
        }

        let sourceFormat = file.processingFormat
        let sourceLength = AVAudioFrameCount(file.length)

        guard sourceLength > 0,
              let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: sourceLength)
        else {
            NSLog("[TTS] 音频是空的")
            return nil
        }
        do {
            try file.read(into: sourceBuffer)
        } catch {
            NSLog("[TTS] MP3 解码失败：\(error.localizedDescription)")
            return nil
        }

        // 格式一致就不用转
        if sourceFormat.sampleRate == target.sampleRate, sourceFormat.channelCount == target.channelCount {
            return sourceBuffer
        }

        // MP3 常见是 32k 单声道，设备输出是 48k 立体声，这里显式转换一次。
        // 任何一步失败都返回 nil——绝不能把 32k 单声道的 buffer 丢给 48k 立体的播放节点，
        // 那样 AVAudioPlayerNode 会直接抛异常崩掉。
        guard let converter = AVAudioConverter(from: sourceFormat, to: target) else {
            NSLog("[TTS] 拿不到采样率转换器")
            return nil
        }

        let ratio = Double(target.sampleRate) / Double(sourceFormat.sampleRate)
        let capacity = AVAudioFrameCount(Double(sourceLength) * ratio) + 1024
        guard let targetBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            NSLog("[TTS] 分配转换缓冲失败")
            return nil
        }

        var conversionError: NSError?
        var didProvideInput = false

        let status = (try? converter.convert(to: targetBuffer, error: &conversionError) { _, inputStatus in
            if didProvideInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            inputStatus.pointee = .haveData
            return sourceBuffer
        }) ?? .error

        if conversionError != nil, status == .error {
            NSLog("[TTS] 音频格式转换失败：\(conversionError?.localizedDescription ?? "unknown")")
            return nil
        }
        guard targetBuffer.frameLength > 0 else { return nil }
        return targetBuffer
    }
}
