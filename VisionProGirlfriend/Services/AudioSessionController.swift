import AVFoundation
import Foundation

/// 音频会话只有一个主人。
///
/// 播放和录音都想改 `AVAudioSession` 的 category，如果两边各写各的，
/// 后设的那个会把前一个的配置冲掉，表现为「正在说话突然没声了」或者「麦克风录不进」。
/// 所以全部收敛到这里。
///
/// 模拟器上也能跑：visionOS Simulator 会把会话转发到 Mac 的音频设备。
enum AudioSessionController {

    /// 播放：TTS 出声。关掉 duck 之外的一切，不碰麦克风。
    static func activateForPlayback() {
        #if os(visionOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.duckOthers, .allowBluetoothA2DP])
        try? session.setActive(true)
        #endif
    }

    /// 录音：ASR 采音。`.defaultToSpeaker` 保证七宝的声音仍然从扬声器出，
    /// 这样边听边放也不会把声音掐掉。
    ///
    /// mode 用 `.voiceChat` 而不是 `.measurement`：
    /// `.measurement` 是给测量类 App 用的，它会**关掉自动增益和降噪**，
    /// 麦克风采到的声音会非常小甚至全是底噪，语音识别基本听不出人在说什么。
    /// `.voiceChat` 才是「有人在说话」场景该用的模式（带 AGC + 回声消除）。
    static func activateForRecording() {
        #if os(visionOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetooth]
        )
        try? session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// 回到纯播放状态，顺手放开别的 App 的音频。
    static func deactivate() {
        #if os(visionOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// 要麦克风权限。返回是否拿到了。
    static func requestMicrophonePermission() async -> Bool {
        #if os(visionOS)
        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        #else
        return false
        #endif
    }
}
