import Foundation

/// 七宝现在处于什么状态。3D 表现跟着这个走。
enum AvatarState: Equatable {
    /// 待机，等你说话
    case idle
    /// 在听你说话
    case listening
    /// 在想（DeepSeek 已经在流式吐字，但还没开始出声）
    case thinking
    /// 在说（TTS 正在播）
    case speaking
}

/// 状态 + 电平都是从别的线程搬过来的，读的时候要安全。
final class AvatarStateSignal {
    private let lock = NSLock()
    private var storage: AvatarState = .idle

    var value: AvatarState {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ newValue: AvatarState) {
        lock.lock()
        storage = newValue
        lock.unlock()
    }
}

/// 一帧里七宝各个部件该怎么摆。
///
/// **纯计算，不碰 RealityKit** —— 这样它能被单测覆盖（`scripts/test_avatar_pose.swift`），
/// RealityKit 那层只负责把算出来的值赋给实体。
///
/// 没有 USDZ 模型时的替代方案：RealityKit 没有公开的 blendshape setter，
/// 所以头、眉、眼、下巴都用基础几何体摆位来表达情绪。
struct AvatarPose: Equatable {

    /// 头前后点（弧度，正值低头）
    var headPitch: Float = 0
    /// 头左右转
    var headYaw: Float = 0
    /// 头左右歪（歪头那种）
    var headRoll: Float = 0
    /// 躯干上下起伏
    var bodyBob: Float = 0
    /// 躯干前后倾
    var bodyLean: Float = 0
    /// 呼吸缩放
    var breathScale: Float = 1
    /// 下巴下沉量
    var jawDrop: Float = 0
    /// 下巴压扁程度
    var jawSquash: Float = 1
    /// 嘴巴张合（0 闭嘴 → 1 大张）
    var mouthOpen: Float = 0
    /// 眼睛睁开程度（0 闭 → 1 睁）
    var eyeOpen: Float = 1
    /// 眉毛抬起量
    var browRaise: Float = 0

    /// 一帧的完整解算。
    ///
    /// - Parameters:
    ///   - state: 当前状态
    ///   - time: 从启动起累计的秒数，用来算呼吸/晃动/眨眼
    ///   - jawOpen: 音量 0…1，说话时驱动嘴
    ///   - blink: 眨眼进度 0…1，0 = 没在眨，1 = 闭到最紧
    static func solve(
        state: AvatarState,
        time: Float,
        jawOpen: Float,
        blink: Float = 0
    ) -> AvatarPose {
        var pose = AvatarPose()

        let open = min(max(jawOpen, 0), 1)
        let breathing = sin(time * 1.9)
        let sway = sin(time * 0.62)

        // 眨眼系数：0 = 没眨，1 = 闭到最紧
        let blinkFactor: Float = 1 - 0.94 * sin(min(max(blink, 0), 1) * .pi)

        // 共用：呼吸。说话和听的时候呼吸快一点，显得投入。
        let breathRate: Float = (state == .speaking || state == .listening) ? 2.6 : 1.9
        pose.breathScale = 1 + sin(time * breathRate) * 0.012
        pose.bodyBob = sin(time * breathRate) * 0.010

        // 各状态下的基准睁眼程度，最后统一乘眨眼系数。
        // 注意不能反过来写 max(eyeOpen, ...)——那会在「认真听」时把眼睛强行撑开，
        // 导致她永远眨不了眼。
        var eyeOpenBase: Float = 1

        switch state {
        case .idle:
            pose.headYaw = sway * 0.05
            pose.headRoll = sin(time * 0.41) * 0.03
            pose.headPitch = 0.02 + breathing * 0.01
            pose.browRaise = 0
            // 待机时嘴偶尔微微张开一点点，像在呼吸
            pose.mouthOpen = open * 0.35
            eyeOpenBase = 1

        case .listening:
            // 认真听：头微微前倾，眼睛睁大一点，眉毛抬起来
            pose.headPitch = -0.13 + sway * 0.015
            pose.headYaw = sway * 0.03
            pose.headRoll = 0.02
            pose.bodyLean = -0.04
            eyeOpenBase = 1.12
            pose.browRaise = 0.85
            pose.mouthOpen = open * 0.3

        case .thinking:
            // 想事情：头歪向一边，眼睛左右飘
            pose.headRoll = 0.16 + sin(time * 0.9) * 0.02
            pose.headPitch = 0.06
            pose.headYaw = sin(time * 1.35) * 0.16
            pose.browRaise = 0.35
            pose.mouthOpen = open * 0.3
            eyeOpenBase = 0.88

        case .speaking:
            // 说话：跟着音量点头，嘴张开
            pose.headPitch = -0.05 + sway * 0.02 + open * 0.06
            pose.headYaw = sway * 0.04
            pose.headRoll = sin(time * 0.55) * 0.02
            pose.browRaise = 0.5 + open * 0.3
            pose.mouthOpen = open
            // 下巴跟着张嘴往下掉，同时稍微压扁
            pose.jawDrop = 0.026 * open
            pose.jawSquash = 1 - 0.16 * open
            eyeOpenBase = 0.82 + open * 0.1
        }

        pose.eyeOpen = min(max(eyeOpenBase * blinkFactor, 0), 1)
        return pose
    }
}
