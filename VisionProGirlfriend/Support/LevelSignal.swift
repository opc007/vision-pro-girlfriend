import Foundation

/// 线程安全的电平信号。音频线程写、渲染线程读。
/// 播放侧用它驱动口型，录音侧用它画麦克风电平条。
final class LevelSignal {
    private let lock = NSLock()
    private var storage: Float = 0

    /// 0…1，1 表示最响
    var value: Float {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func update(_ newValue: Float) {
        lock.lock()
        storage = newValue
        lock.unlock()
    }
}
