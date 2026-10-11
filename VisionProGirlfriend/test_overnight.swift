// 通宵任务（E1/E2/E3）新增纯逻辑的断言测试。
//
// 这些类型都不 import RealityKit / SwiftUI，所以能脱离 Xcode 跑：
//   swiftc VisionProGirlfriend/Avatar/AvatarModelPlan.swift \
//          VisionProGirlfriend/Avatar/BlinkTimer.swift \
//          VisionProGirlfriend/Support/FriendlyError.swift \
//          VisionProGirlfriend/Config/AppConfig.swift \
//          scripts/test_overnight.swift -o /tmp/overnight-test && /tmp/overnight-test
//
// FriendlyError 里对 DeepSeekError / MiniMaxTTSError 的判断需要那两个文件，
// 所以上面的命令行里如果没有它们，会退化成只跑前几组断言（见下方 mode 判断）。

import Foundation

// MARK: - 迷你测试框架（和 test_avatar_pose.swift 保持同一种写法）

@main
struct OvernightTest {

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

    static func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
        checks += 1
        if actual == expected {
            print("  ✅ \(label)")
        } else {
            failures += 1
            print("  ❌ \(label) — 实际 \(actual)，期望 \(expected)")
        }
    }

    static func expectContains(_ haystack: String, _ needle: String, _ label: String) {
        checks += 1
        if haystack.contains(needle) {
            print("  ✅ \(label)")
        } else {
            failures += 1
            print("  ❌ \(label) — 「\(haystack)」里没有「\(needle)」")
        }
    }

    static func expectNotContains(_ haystack: String, _ needle: String, _ label: String) {
        checks += 1
        if !haystack.contains(needle) {
            print("  ✅ \(label)")
        } else {
            failures += 1
            print("  ❌ \(label) — 「\(haystack)」里不该出现「\(needle)」")
        }
    }

    // MARK: - E1：USDZ 回退

    static func testAvatarModelPlan() {
        print("\nE1 · USDZ 加载与回退")

        // 最常见的路径：什么都没放 → 必须回退，而且要说清是「文件不在」
        let noFile = AvatarModelPlan.resolve(
            enabled: true, modelName: "qibao", scale: 1.0, fileExists: false, loaderSucceeded: false
        )
        expectEqual(noFile, .usePlaceholder(reason: AvatarModelPlan.Reason.missingFile.rawValue),
                    "Bundle 里没有 qibao.usdz → 回退占位")

        // 放了模型且加载成功 → 用真模型
        let withFile = AvatarModelPlan.resolve(
            enabled: true, modelName: "qibao", scale: 1.0, fileExists: true, loaderSucceeded: true
        )
        expectEqual(withFile, .useUsdz(name: "qibao", scale: 1.0), "有模型且加载成功 → 用真模型")

        // 文件在但读不出来（损坏 / 不是合法 usdz）→ 仍然回退，不能崩
        let brokenFile = AvatarModelPlan.resolve(
            enabled: true, modelName: "qibao", scale: 1.0, fileExists: true, loaderSucceeded: false
        )
        expectEqual(brokenFile, .usePlaceholder(reason: AvatarModelPlan.Reason.loadFailed.rawValue),
                    "文件存在但加载失败 → 回退占位")

        // 主动关掉
        let disabled = AvatarModelPlan.resolve(
            enabled: false, modelName: "qibao", scale: 1.0, fileExists: true, loaderSucceeded: true
        )
        expectEqual(disabled, .usePlaceholder(reason: AvatarModelPlan.Reason.disabled.rawValue),
                    "AVATAR_USE_CUSTOM_MODEL=0 → 强制占位")

        // 名字配成空白 → 不能拿空字符串去查文件
        let blank = AvatarModelPlan.resolve(
            enabled: true, modelName: "   ", scale: 1.0, fileExists: false, loaderSucceeded: false
        )
        expectEqual(blank, .usePlaceholder(reason: AvatarModelPlan.Reason.blankName.rawValue),
                    "模型名是空白 → 回退，不去查空文件名")

        // 名字前后有空格要能trim，否则「 qibao 」永远找不到文件
        let padded = AvatarModelPlan.resolve(
            enabled: true, modelName: "  qibao  ", scale: 1.0, fileExists: true, loaderSucceeded: true
        )
        expectEqual(padded, .useUsdz(name: "qibao", scale: 1.0), "模型名前后空格会被 trim")

        // 缩放配成 0 或负数会让模型消失/翻面，必须兜到 1.0
        for bad in [Float(0), -1, -0.5] {
            let plan = AvatarModelPlan.resolve(
                enabled: true, modelName: "qibao", scale: bad, fileExists: true, loaderSucceeded: true
            )
            expectEqual(plan, .useUsdz(name: "qibao", scale: 1.0), "非法缩放 \(bad) 被兜回 1.0")
        }
        // 正常的自定义缩放要原样保留
        let scaled = AvatarModelPlan.resolve(
            enabled: true, modelName: "qibao", scale: 0.35, fileExists: true, loaderSucceeded: true
        )
        expectEqual(scaled, .useUsdz(name: "qibao", scale: 0.35), "合法缩放 0.35 原样保留")
    }

    // MARK: - E1：环境变量解析

    static func testAppConfigAvatar() {
        print("\nE1 · AVATAR_* 环境变量解析")

        let defaultConfig = AppConfig(environment: ["ASR_LOCALE": "zh-CN"])
        expectEqual(defaultConfig.avatarModelName, "qibao", "默认模型名是 qibao")
        expectEqual(defaultConfig.avatarModelScale, 1.0, "默认缩放 1.0")
        expectTrue(defaultConfig.avatarUseCustomModel, "默认允许用真模型")

        let custom = AppConfig(environment: ["AVATAR_MODEL_NAME": "girl", "AVATAR_MODEL_SCALE": "0.5"])
        expectEqual(custom.avatarModelName, "girl", "AVATAR_MODEL_NAME 生效")
        expectEqual(custom.avatarModelScale, 0.5, "AVATAR_MODEL_SCALE 生效")

        for off in ["0", "false", "FALSE", "no", "off"] {
            let c = AppConfig(environment: ["AVATAR_USE_CUSTOM_MODEL": off])
            expectTrue(!c.avatarUseCustomModel, "AVATAR_USE_CUSTOM_MODEL=\(off) 关掉自定义模型")
        }

        // 写坏了的缩放不能让 App 起不来
        let brokenScale = AppConfig(environment: ["AVATAR_MODEL_SCALE": "很大"])
        expectEqual(brokenScale.avatarModelScale, 1.0, "缩放解析失败时兜回 1.0")
        expectEqual(brokenScale.avatarModelOffsetY, 0, "没配偏移时是 0（真模型原点当在脚底）")

        // 悬空/埋进地板时能上下挪
        let lifted = AppConfig(environment: ["AVATAR_MODEL_OFFSET_Y": "-0.3"])
        expectEqual(lifted.avatarModelOffsetY, -0.3, "AVATAR_MODEL_OFFSET_Y 能调垂直位置")
        let brokenOffset = AppConfig(environment: ["AVATAR_MODEL_OFFSET_Y": "很高"])
        expectEqual(brokenOffset.avatarModelOffsetY, 0, "偏移解析失败时兜回 0")

        // 空字符串等于没配，回默认值
        let emptyName = AppConfig(environment: ["AVATAR_MODEL_NAME": "  "])
        expectEqual(emptyName.avatarModelName, "qibao", "模型名配成空白回默认")

        // 缺 Key 的两套文案都在，且不泄露任何密钥内容
        let noKeys = AppConfig(environment: [:])
        expectContains(noKeys.missingKeysShort, "DEEPSEEK_API_KEY", "缺 Key 短文案列出 DEEPSEEK")
        expectContains(noKeys.missingKeysShort, "MINIMAX_API_KEY", "缺 Key 短文案列出 MINIMAX")
        expectContains(noKeys.missingKeysDescription, "Environment Variables", "缺 Key 长文案给出配置位置")
        expectTrue(AppConfig(environment: ["DEEPSEEK_API_KEY": "k1", "MINIMAX_API_KEY": "k2"]).missingKeysDescription.isEmpty,
                    "Key 齐了就不再提示缺 Key")
    }

    // MARK: - E1：眨眼节奏（占位人和真模型共用）

    static func testBlinkTimer() {
        print("\nE1 · 眨眼节奏")

        var timer = BlinkTimer()
        // 一开始还没眨，进度是 0（睁着眼）
        expectTrue(timer.advance(elapsed: 0, random01: 0.5) == 0, "刚启动时眼睛是睁开的")

        /// 眨眼是**逐帧**推进的，所以必须按帧率采样才能看到中间的进度。
        /// 按大步长跳是看不到的——这正是真实运行时每帧都调的原因。
        func peakWithin(start: Float, random01: Float, step: Float = 0.01, frames: Int = 40) -> Float {
            var t = BlinkTimer()
            var peak: Float = 0
            for i in 0...frames {
                peak = max(peak, t.advance(elapsed: start + Float(i) * step, random01: random01))
            }
            return peak
        }

        // 到 2.5s 该眨了，逐帧推进能真的闭到位
        let peak = peakWithin(start: BlinkTimer.gap.lowerBound, random01: 0.5)
        expectTrue(peak > 0.9, "到点后逐帧推进，眼睛能真的闭到位（峰值 \(peak)）")

        // 眨完必须恢复睁眼，不能一直保持闭着
        var after = BlinkTimer()
        _ = peakWithin(start: BlinkTimer.gap.lowerBound, random01: 0.5)
        after = BlinkTimer()
        _ = after.advance(elapsed: BlinkTimer.gap.lowerBound, random01: 0.5)
        expectTrue(after.advance(elapsed: BlinkTimer.gap.lowerBound + 0.5, random01: 0.5) == 0,
                    "眨眼结束后恢复睁眼")

        // 随机数的两个端点：间隔取下限和上限都要能眨
        expectTrue(peakWithin(start: BlinkTimer.gap.lowerBound, random01: 0) > 0.9,
                   "随机数 0 时也能眨（间隔取下限 2.5s）")
        expectTrue(peakWithin(start: BlinkTimer.gap.upperBound, random01: 1) > 0.9,
                   "随机数 1 时也能眨（间隔取上限 6s）")

        // 长时间按 60fps 采样：进度必须一直在 0…1，不能越界或变 NaN
        var probe = BlinkTimer()
        var samples: [Float] = []
        for i in 0...600 {
            samples.append(probe.advance(elapsed: Float(i) / 60, random01: Float(i % 17) / 17))
        }
        expectTrue(samples.allSatisfy { $0 >= 0 && $0 <= 1 }, "10 秒连续采样，进度始终在 0…1")
        expectTrue(samples.allSatisfy { !$0.isNaN }, "10 秒连续采样，不出 NaN")
        expectTrue(samples.contains { $0 > 0.9 }, "这段时间里至少眨过一次完整的眼")
        // 10 秒、间隔 2.5~6s，至少该眨 1 次以上
        let blinkCount = samples.reduce(into: 0) { total, value in
            if value > 0 { total += 1 }
        }
        expectTrue(blinkCount >= 3, "10 秒里眨了足够的帧数（\(blinkCount) 帧处于闭眼区间）")
    }

    // MARK: - E3：友好提示

    static func testFriendlyTTSHints() {
        print("\nE3 · TTS 状态提示")

        expectContains(FriendlyError.ttsHint(forStateMessage: "2201 空闲断开"), "重连", "2201 → 说明会自动重连")
        expectContains(FriendlyError.ttsHint(forStateMessage: "1001 鉴权失败"), "MINIMAX_API_KEY", "1001 → 指向 Key 问题")
        expectContains(FriendlyError.ttsHint(forStateMessage: "1008 policy violation"), "MINIMAX_API_KEY", "1008 → 指向 Key 问题")
        expectContains(FriendlyError.ttsHint(forStateMessage: "2202 限流"), "限流", "2202 → 说是限流")
        expectContains(FriendlyError.ttsHint(forStateMessage: "connection refused"), "语音连接断了", "连接类错误 → 说会重连")
        expectContains(FriendlyError.ttsHint(forStateMessage: "随便一个没见过的错"), "语音出问题了", "未知错误也不静默")

        // 提示语不该把原始技术码直接甩给用户看
        expectNotContains(FriendlyError.ttsHint(forStateMessage: "2201 空闲断开"), "2201", "提示里不出现裸状态码")
    }

    static func main() {
        print("通宵任务单测（E1 模型回退 / 环境变量 / 眨眼 · E3 友好提示）")
        testAvatarModelPlan()
        testAppConfigAvatar()
        testBlinkTimer()
        testFriendlyTTSHints()

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
