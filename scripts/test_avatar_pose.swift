// AvatarPose 的断言测试。
//
// 这部分是纯数学、不依赖 RealityKit，所以能脱离 Xcode 跑：
//   swiftc VisionProGirlfriend/Avatar/AvatarState.swift \
//          scripts/test_avatar_pose.swift -o /tmp/pose-test && /tmp/pose-test

import Foundation

@main
struct AvatarPoseTest {

    static var failures = 0
    static var checks = 0

    static func expectTrue(_ condition: Bool, _ label: String) {
        checks += 1
        if condition {
            print("  ✅ \(label)")
        } else {
            failures += 1
            print("  ❌ \(label)")
        }
    }

    static func expectNear(_ actual: Float, _ expected: Float, _ tolerance: Float, _ label: String) {
        checks += 1
        if abs(actual - expected) <= tolerance {
            print("  ✅ \(label)")
        } else {
            failures += 1
            print("  ❌ \(label) —— 期望 \(expected)±\(tolerance)，实际 \(actual)")
        }
    }

    /// 采样一段时间，确认某个量在该区间内
    static func expectInRange(
        _ values: [Float],
        _ range: ClosedRange<Float>,
        _ label: String
    ) {
        let minValue = values.min() ?? 0
        let maxValue = values.max() ?? 0
        let ok = minValue >= range.lowerBound - 0.0001 && maxValue <= range.upperBound + 0.0001
        expectTrue(ok, "\(label)（实测 \(String(format: "%.3f…%.3f", minValue, maxValue))，允许 \(range)）")
    }

    static func sample(
        state: AvatarState,
        seconds: Float,
        step: Float = 0.05,
        jawOpen: Float = 0
    ) -> [AvatarPose] {
        var result: [AvatarPose] = []
        var time: Float = 0
        while time <= seconds {
            result.append(AvatarPose.solve(state: state, time: time, jawOpen: jawOpen))
            time += step
        }
        return result
    }

    static func main() {
        print("AvatarPose 测试")
        print("")

        // 1. 各状态的静态特征
        let idle = AvatarPose.solve(state: .idle, time: 0.3, jawOpen: 0)
        let listening = AvatarPose.solve(state: .listening, time: 0.3, jawOpen: 0)
        let thinking = AvatarPose.solve(state: .thinking, time: 0.3, jawOpen: 0)
        let speaking = AvatarPose.solve(state: .speaking, time: 0.3, jawOpen: 0)

        expectTrue(listening.headPitch < idle.headPitch, "在听时头比待机更低（前倾）")
        expectTrue(listening.browRaise > idle.browRaise, "在听时眉毛抬得更高")
        expectTrue(abs(thinking.headRoll) > abs(idle.headRoll), "想事情时头歪得更明显")
        expectTrue(abs(thinking.headYaw) > 0.05, "想事情时眼睛在左右扫")
        expectNear(speaking.mouthOpen, 0, 0.001, "没音量时嘴是闭着的")

        // 2. 音量真正驱动嘴
        let quiet = AvatarPose.solve(state: .speaking, time: 1, jawOpen: 0)
        let mid = AvatarPose.solve(state: .speaking, time: 1, jawOpen: 0.5)
        let loud = AvatarPose.solve(state: .speaking, time: 1, jawOpen: 1)
        expectTrue(loud.mouthOpen > mid.mouthOpen && mid.mouthOpen > quiet.mouthOpen,
                   "音量越大嘴张得越开")
        expectNear(loud.jawDrop, 0.026, 0.0001, "张嘴到底巴下沉量")
        expectTrue(loud.jawSquash < 1, "张嘴时下巴会被压扁")

        // 3. 音量要夹在 0…1，超界不能产生诡异姿势
        let overdriven = AvatarPose.solve(state: .speaking, time: 1, jawOpen: 5)
        expectNear(overdriven.mouthOpen, 1, 0.0001, "音量超过 1 会被夹到 1")
        expectTrue(overdriven.jawDrop <= 0.0261, "超界音量不会让下巴飞出去")

        let negative = AvatarPose.solve(state: .speaking, time: 1, jawOpen: -3)
        expectNear(negative.mouthOpen, 0, 0.0001, "负音量会被夹到 0")

        // 4. 眨眼：中间闭到最紧，两头是睁开的
        expectNear(AvatarPose.solve(state: .idle, time: 1, jawOpen: 0, blink: 0).eyeOpen, 1, 0.001,
                   "不眨眼时眼睛全睁")
        expectTrue(AvatarPose.solve(state: .idle, time: 1, jawOpen: 0, blink: 0.5).eyeOpen < 0.1,
                   "眨眼到一半时基本闭上")
        expectTrue(AvatarPose.solve(state: .listening, time: 1, jawOpen: 0, blink: 0.5).eyeOpen < 0.95,
                   "眨眼优先于「认真听时睁大眼」")

        // 5. 长时间采样不允许飞出合理范围（防 NaN / 发散）
        let states: [AvatarState] = [.idle, .listening, .thinking, .speaking]
        for state in states {
            let poses = sample(state: state, seconds: 12)
            let finite = poses.allSatisfy { pose in
                [pose.headPitch, pose.headYaw, pose.headRoll, pose.bodyBob, pose.breathScale,
                 pose.jawDrop, pose.mouthOpen, pose.eyeOpen, pose.browRaise]
                    .allSatisfy { $0.isFinite }
            }
            expectTrue(finite, "\(state) 12 秒采样没有 NaN/Inf")

            expectInRange(poses.map(\.breathScale), 0.98...1.02, "\(state) 呼吸幅度克制")
            expectInRange(poses.map(\.eyeOpen), 0...1, "\(state) 眼睛开合在 0…1")
            expectInRange(poses.map(\.headPitch), -0.2...0.12, "\(state) 俯仰角不夸张")
            expectInRange(poses.map(\.headYaw), -0.3...0.3, "\(state) 偏航角不夸张")
            expectInRange(poses.map(\.bodyBob), -0.02...0.02, "\(state) 身体起伏克制")
        }

        // 6. 待机要真的在动（不能是死的）
        let idlePoses = sample(state: .idle, seconds: 8)
        let yawRange = (idlePoses.map(\.headYaw).max() ?? 0) - (idlePoses.map(\.headYaw).min() ?? 0)
        expectTrue(yawRange > 0.05, "待机时头会缓慢左右晃，不是死的")

        // 7. 思考时视线要真的在扫
        let thinkingYaw = sample(state: .thinking, seconds: 6).map(\.headYaw)
        let thinkingRange = (thinkingYaw.max() ?? 0) - (thinkingYaw.min() ?? 0)
        expectTrue(thinkingRange > 0.2, "思考时视线扫动幅度够明显")

        // 8. 音量驱动下的下巴也扫一遍范围
        let speakingPoses = (0...10).map { i -> AvatarPose in
            AvatarPose.solve(state: .speaking, time: Float(i) * 0.1, jawOpen: Float(i % 3) / 2)
        }
        expectInRange(speakingPoses.map(\.jawDrop), 0...0.0261, "下巴下沉不越界")

        print("")
        if failures == 0 {
            print("全部通过：\(checks) 项 ✅")
            exit(0)
        } else {
            print("\(checks) 项里挂了 \(failures) 项 ❌")
            exit(1)
        }
    }
}
