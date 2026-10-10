import Foundation

/// 眨眼节奏。纯逻辑，不碰 RealityKit，可以单测。
///
/// 为什么要抽出来：占位人偶和真实 USDZ 都需要眨眼，但两者一个是系统几何体、
/// 一个是美术给的模型，驱动代码完全不同。节奏本身是同一套，抽出来只有一份。
struct BlinkTimer {

    /// 一次眨眼从开始到闭紧要多久（秒）
    static let duration: Float = 0.14
    /// 两次眨眼之间的间隔区间（秒）
    static let gap: ClosedRange<Float> = 2.5...6.0

    private(set) var nextBlinkAt: Float = 2.5
    private(set) var blinkStart: Float = -10

    /// - Parameters:
    ///   - elapsed: 从启动起累计的秒数
    ///   - random01: 0…1 的随机数，外部注入是为了让单测可复现
    /// - Returns: 眨眼进度 0…1（0 = 没在眨，1 = 闭到最紧）
    mutating func advance(elapsed: Float, random01: Float) -> Float {
        if elapsed >= nextBlinkAt {
            blinkStart = elapsed
            nextBlinkAt = elapsed + Self.gap.lowerBound + (Self.gap.upperBound - Self.gap.lowerBound) * random01
        }
        let progress = (elapsed - blinkStart) / Self.duration
        guard progress >= 0, progress <= 1 else { return 0 }
        return progress
    }

    /// 运行时用的便捷版本
    mutating func advance(elapsed: Float) -> Float {
        advance(elapsed: elapsed, random01: Float.random(in: 0...1))
    }
}
