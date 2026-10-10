import Foundation
import RealityKit

/// 真实 USDZ 模型 + 占位人偶同一套驱动。
///
/// RealityKit 目前没有公开的 blendshape setter，所以真模型的口型是靠**变换**做的：
/// - 找到叫 `head` 的子实体 → 头部朝向按 `AvatarPose` 算的值摆
/// - 找到叫 `jaw` 的子实体 → 音量驱动的下沉 + 压扁
/// - 都没找到 → 只对根节点做呼吸起伏和前后倾（至少不会是个木头桩子）
///
/// 想让真模型的口型更自然，在 USDZ 里把下巴那块命名成 `jaw` 即可，
/// 见 README「换成自己的七宝」。
final class UsdzAvatar: DrivableAvatar {

    let root = Entity()
    let sourceDescription: String
    /// 真模型的原点通常在脚底，直接放地上站着就对；
    /// 抬起来/沉下去用 `AVATAR_MODEL_OFFSET_Y` 调
    let worldPosition: SIMD3<Float>

    private let model: Entity
    private let head: Entity?
    private let jaw: Entity?
    /// 下巴静止时的 Y。每帧是**赋值**不是累加，否则会越掉越远
    private let jawRestY: Float
    private var blink = BlinkTimer()
    private var elapsed: Float = 0

    init(model: Entity, name: String, scale: Float, offsetY: Float = 0) {
        self.model = model
        self.head = Self.findEntity(named: "head", in: model)
        self.jaw = Self.findEntity(named: "jaw", in: model)
        self.jawRestY = Self.findEntity(named: "jaw", in: model)?.position.y ?? 0
        self.sourceDescription = "真实模型 \(name).usdz"
        self.worldPosition = [0, offsetY, -1.05]

        model.scale = SIMD3<Float>(repeating: scale)
        root.name = "avatar-usdz"
        root.addChild(model)
    }

    func update(deltaTime: Float, jawOpen: Float, state: AvatarState) {
        elapsed += deltaTime
        let blinkProgress = blink.advance(elapsed: elapsed)
        let pose = AvatarPose.solve(state: state, time: elapsed, jawOpen: jawOpen, blink: blinkProgress)

        // 身体：呼吸起伏 + 前倾。这两个值幅度都很小，直接作用在根节点上最稳
        root.position.y = pose.bodyBob
        root.orientation = simd_quatf(angle: pose.bodyLean, axis: [1, 0, 0])
        root.scale = SIMD3<Float>(repeating: pose.breathScale)

        // 头：偏航(Y) → 侧滚(Z) → 俯仰(X)，顺序和占位人偶一致
        // 每帧整体赋值，不会累积误差
        if let head {
            head.orientation = simd_quatf(angle: pose.headYaw, axis: [0, 1, 0])
                * simd_quatf(angle: pose.headRoll, axis: [0, 0, 1])
                * simd_quatf(angle: pose.headPitch, axis: [1, 0, 0])
        }

        // 下巴：跟着音量下沉 + 压扁。没有 jaw 子节点就让整个模型轻微起伏，
        // 观感上至少不是完全不动
        if let jaw {
            jaw.position.y = jawRestY - pose.jawDrop
            jaw.scale = [1, pose.jawSquash, 1]
        } else {
            root.position.y = pose.bodyBob + pose.jawDrop * 0.15
        }
    }

    /// 大小写不敏感地递归找子实体。美术导出的模型大小写很不统一。
    private static func findEntity(named name: String, in root: Entity) -> Entity? {
        let target = name.lowercased()
        if root.name.lowercased() == target { return root }
        for child in root.children {
            if let hit = findEntity(named: name, in: child) { return hit }
        }
        return nil
    }
}
