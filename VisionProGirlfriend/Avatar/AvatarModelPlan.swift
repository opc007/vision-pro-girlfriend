import Foundation

/// 这次到底用真实 USDZ，还是退回占位人偶。
///
/// 这一层刻意**不 import RealityKit**：「该不该用模型」这条规则是可以脱离
/// Xcode 单测的，而真正的 `Entity` 加载放在 `AvatarFactory` 里。
///
/// 规则（顺序很重要，短路优先）：
/// 1. 显式关掉（`AVATAR_USE_CUSTOM_MODEL=0`）→ 占位
/// 2. Bundle 里没有 `<名字>.usdz` → 占位
/// 3. 文件在但加载失败（文件损坏 / 不是合法的 usdz）→ 占位
/// 4. 其余 → 用真实模型
///
/// 三种回退都不会崩，这是这个文件存在的全部意义。
enum AvatarModelPlan: Equatable {

    /// 用 Bundle 里的真实模型
    case useUsdz(name: String, scale: Float)
    /// 回退占位人偶。`reason` 只给开发者看（日志），不展示给用户
    case usePlaceholder(reason: String)

    enum Reason: String {
        /// 用户主动关掉了自定义模型
        case disabled
        /// Bundle 里没有这个 .usdz
        case missingFile
        /// 文件在，但 RealityKit 读不出来
        case loadFailed
        /// 模型名配成了空字符串
        case blankName
    }

    /// - Parameters:
    ///   - enabled: `AVATAR_USE_CUSTOM_MODEL`，默认开
    ///   - modelName: `AVATAR_MODEL_NAME`，默认 `qibao`
    ///   - scale: `AVATAR_MODEL_SCALE`，默认 `1.0`
    ///   - fileExists: Bundle 里有没有 `<modelName>.usdz`
    ///   - loaderSucceeded: 真的去加载时成功了吗（没文件时传 false 即可）
    static func resolve(
        enabled: Bool,
        modelName: String,
        scale: Float,
        fileExists: Bool,
        loaderSucceeded: Bool
    ) -> AvatarModelPlan {
        guard enabled else {
            return .usePlaceholder(reason: Reason.disabled.rawValue)
        }
        let name = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return .usePlaceholder(reason: Reason.blankName.rawValue)
        }
        guard fileExists else {
            return .usePlaceholder(reason: Reason.missingFile.rawValue)
        }
        guard loaderSucceeded else {
            return .usePlaceholder(reason: Reason.loadFailed.rawValue)
        }
        // 缩放给个下限：0 或负数会让模型消失或翻面，那还不如用占位
        return .useUsdz(name: name, scale: scale > 0 ? scale : 1)
    }
}
