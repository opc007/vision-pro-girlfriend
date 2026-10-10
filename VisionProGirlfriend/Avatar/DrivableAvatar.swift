import Foundation
import RealityKit

/// 3D 人：不管背后是占位人偶还是真实 USDZ，对外的驱动方式完全一样。
///
/// 这样换模型是**只改配置、不改逻辑**的事：`AvatarPose` 算出来的值该怎么用、
/// `jawOpen` 怎么映射，调用方一律不关心。
protocol DrivableAvatar: AnyObject {
    /// 挂到 `AnchorEntity` 上的根节点
    var root: Entity { get }
    /// 挂到世界里时的位置。占位人偶的原点在头部、真模型通常在脚底，
    /// 两者需要的抬升高度不一样，所以由各自决定
    var worldPosition: SIMD3<Float> { get }
    /// 人话描述当前用的是哪种形象，给日志和状态栏看
    var sourceDescription: String { get }
    /// 每帧调一次
    func update(deltaTime: Float, jawOpen: Float, state: AvatarState)
}

/// 按配置决定用真实模型还是占位人偶。
///
/// **这个工厂不会抛、不会崩**：`AvatarModelPlan` 先用纯逻辑判断，
/// 真去加载之前还会再确认文件在不在。任何一步不行就静默退回占位人偶。
enum AvatarFactory {

    static func make(config: AppConfig, bundle: Bundle = .main) -> DrivableAvatar {
        let name = config.avatarModelName
        let scale = config.avatarModelScale

        // 先问文件在不在：绝大多数人没有放模型，没必要去碰 RealityKit 的加载 API
        let fileExists = bundle.url(forResource: name, withExtension: "usdz") != nil
        var loaded: Entity?
        if fileExists {
            loaded = try? Entity(named: name, in: bundle)
        }

        let plan = AvatarModelPlan.resolve(
            enabled: config.avatarUseCustomModel,
            modelName: name,
            scale: scale,
            fileExists: fileExists,
            loaderSucceeded: loaded != nil
        )

        switch plan {
        case let .useUsdz(modelName, modelScale):
            if let model = loaded {
                return UsdzAvatar(
                    model: model,
                    name: modelName,
                    scale: modelScale,
                    offsetY: config.avatarModelOffsetY
                )
            }
        case let .usePlaceholder(reason):
            NSLog("[Avatar] 用占位人偶：\(reason)")
        }

        if case .useUsdz = plan {
            NSLog("[Avatar] \(name).usdz 加载失败，回退占位人偶")
        }
        return PlaceholderAvatar()
    }
}
