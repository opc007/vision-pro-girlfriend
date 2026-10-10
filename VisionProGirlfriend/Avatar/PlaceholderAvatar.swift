import RealityKit
import UIKit

/// 占位 3D 人：全部用 RealityKit 自带的基础几何体拼的，不依赖任何外部模型。
///
/// 「这一帧该怎么摆」的算术全在 `AvatarPose`（纯函数，有单测）里，
/// 这里只负责把算出来的值赋给实体。
///
/// 换真人模型时：把 `ModelEntity(named:)` 加载出来的实体挂到 `root` 上，
/// 保留 `update(deltaTime:jawOpen:state:)` 里的驱动逻辑就行——
/// `jawOpen` 是 0…1 的音量值，含义和真模型的 `jawOpen` blendshape 一致。
final class PlaceholderAvatar {

    let root = Entity()

    private let bodyNode = Entity()
    private let headNode = Entity()

    private let jaw: ModelEntity
    private let mouth: ModelEntity
    private let eyes: [ModelEntity]
    private let brows: [ModelEntity]

    private let jawRestY: Float = -0.075
    private let eyeRestY: Float = 0.012
    private let browRestY: Float = 0.038
    private var elapsed: Float = 0

    // 眨眼状态机
    private var nextBlinkAt: Float = 2.5
    private var blinkStart: Float = -10
    private static let blinkDuration: Float = 0.14

    init() {
        root.name = "placeholder-avatar"
        jaw = ModelEntity(
            mesh: .generateBox(size: [0.17, 0.10, 0.15], cornerRadius: 0.04),
            materials: [Self.skinMaterial]
        )
        mouth = ModelEntity(
            mesh: .generateSphere(radius: 0.05),
            materials: [Self.mouthMaterial]
        )
        // `eyes` / `brows` 是 let 属性，不能直接 append，先用局部数组收集再一次性赋值
        var builtEyes: [ModelEntity] = []
        var builtBrows: [ModelEntity] = []
        for side: Float in [-1, 1] {
            // 眼睛
            let eye = ModelEntity(
                mesh: .generateSphere(radius: 0.017),
                materials: [Self.eyeMaterial]
            )
            eye.name = side < 0 ? "eye-left" : "eye-right"
            eye.position = [side * 0.045, eyeRestY, 0.098]
            headNode.addChild(eye)
            builtEyes.append(eye)

            // 眉毛（跟着状态抬起）
            let brow = ModelEntity(
                mesh: .generateBox(size: [0.034, 0.006, 0.012], cornerRadius: 0.002),
                materials: [Self.hairMaterial]
            )
            brow.name = side < 0 ? "brow-left" : "brow-right"
            brow.position = [side * 0.045, browRestY, 0.100]
            headNode.addChild(brow)
            builtBrows.append(brow)
        }
        eyes = builtEyes
        brows = builtBrows

        root.addChild(bodyNode)
        bodyNode.addChild(headNode)

        // 躯干
        let torso = ModelEntity(
            mesh: .generateBox(size: [0.34, 0.42, 0.20], cornerRadius: 0.09),
            materials: [Self.clothMaterial]
        )
        torso.name = "torso"
        torso.position = [0, -0.34, 0]
        bodyNode.addChild(torso)

        // 手臂
        for side: Float in [-1, 1] {
            let arm = ModelEntity(
                mesh: .generateCylinder(height: 0.26, radius: 0.045),
                materials: [Self.skinMaterial]
            )
            arm.name = side < 0 ? "arm-left" : "arm-right"
            arm.position = [side * 0.20, -0.36, 0.02]
            arm.orientation = simd_quatf(angle: .pi / 2.6 * side, axis: [0, 0, 1])
            bodyNode.addChild(arm)
        }

        // 脖子
        let neck = ModelEntity(
            mesh: .generateCylinder(height: 0.09, radius: 0.05),
            materials: [Self.skinMaterial]
        )
        neck.name = "neck"
        neck.position = [0, -0.13, 0]
        bodyNode.addChild(neck)

        // 头
        let head = ModelEntity(
            mesh: .generateSphere(radius: 0.115),
            materials: [Self.skinMaterial]
        )
        head.name = "head"
        headNode.addChild(head)

        // 头发（半球，压扁一点当刘海）
        let hair = ModelEntity(
            mesh: .generateSphere(radius: 0.121),
            materials: [Self.hairMaterial]
        )
        hair.name = "hair"
        hair.position = [0, 0.022, 0]
        hair.scale = [1, 0.82, 1]
        headNode.addChild(hair)

        // 腮红
        for side: Float in [-1, 1] {
            let blush = ModelEntity(
                mesh: .generateSphere(radius: 0.032),
                materials: [Self.blushMaterial]
            )
            blush.name = side < 0 ? "blush-left" : "blush-right"
            blush.position = [side * 0.072, -0.018, 0.088]
            blush.scale = [1, 0.62, 0.2]
            headNode.addChild(blush)
        }

        // 嘴（跟着音量开合）
        mouth.name = "mouth"
        mouth.position = [0, -0.048, 0.092]
        mouth.scale = [1, 0.16, 0.34]
        headNode.addChild(mouth)

        // 下巴（跟着音量下沉）
        jaw.name = "jaw"
        jaw.position = [0, jawRestY, 0.055]
        headNode.addChild(jaw)
    }

    /// 每帧调一次。
    /// - Parameters:
    ///   - deltaTime: 上一帧到这一帧的秒数
    ///   - jawOpen: 音量，0…1
    ///   - state: 当前状态，决定头/眉/眼的身体语言
    func update(deltaTime: Float, jawOpen: Float, state: AvatarState) {
        elapsed += deltaTime

        let blink = advanceBlink()
        let pose = AvatarPose.solve(state: state, time: elapsed, jawOpen: jawOpen, blink: blink)

        // 身体：呼吸起伏 + 前倾
        bodyNode.position.y = pose.bodyBob
        bodyNode.orientation = simd_quatf(angle: pose.bodyLean, axis: [1, 0, 0])
        bodyNode.scale = [pose.breathScale, pose.breathScale, pose.breathScale]

        // 头：偏航(Y) → 侧滚(Z) → 俯仰(X)，按这个顺序叠
        headNode.orientation = simd_quatf(angle: pose.headYaw, axis: [0, 1, 0])
            * simd_quatf(angle: pose.headRoll, axis: [0, 0, 1])
            * simd_quatf(angle: pose.headPitch, axis: [1, 0, 0])

        // 嘴 + 下巴
        let open = pose.mouthOpen
        jaw.position.y = jawRestY - pose.jawDrop
        jaw.scale = [1, pose.jawSquash, 1]
        mouth.scale = [1 + 0.22 * open, 0.16 + 2.4 * open, 0.34 + 0.45 * open]

        // 眼睛：纵向压扁就是眨眼
        for eye in eyes {
            eye.scale = [1, max(pose.eyeOpen, 0.06), 1]
        }

        // 眉毛：说话/听的时候抬起来
        for brow in brows {
            brow.position.y = browRestY + 0.011 * pose.browRaise
        }
    }

    /// - Returns: 眨眼进度 0…1（0 = 没在眨，1 = 闭到最紧）
    private func advanceBlink() -> Float {
        if elapsed >= nextBlinkAt {
            blinkStart = elapsed
            // 每 2.5~6 秒眨一次，人看着才自然
            nextBlinkAt = elapsed + 2.5 + Float.random(in: 0...3.5)
        }
        let progress = (elapsed - blinkStart) / Self.blinkDuration
        guard progress >= 0, progress <= 1 else { return 0 }
        return progress
    }

    // MARK: - 材质

    private static let skinMaterial = SimpleMaterial(
        color: UIColor(red: 1.0, green: 0.88, blue: 0.82, alpha: 1),
        roughness: 0.55,
        isMetallic: false
    )
    private static let hairMaterial = SimpleMaterial(
        color: UIColor(red: 0.24, green: 0.17, blue: 0.16, alpha: 1),
        roughness: 0.35,
        isMetallic: false
    )
    private static let clothMaterial = SimpleMaterial(
        color: UIColor(red: 0.98, green: 0.55, blue: 0.72, alpha: 1),
        roughness: 0.7,
        isMetallic: false
    )
    private static let mouthMaterial = SimpleMaterial(
        color: UIColor(red: 0.62, green: 0.16, blue: 0.24, alpha: 1),
        roughness: 0.5,
        isMetallic: false
    )
    private static let eyeMaterial = SimpleMaterial(
        color: UIColor(red: 0.11, green: 0.10, blue: 0.15, alpha: 1),
        roughness: 0.2,
        isMetallic: false
    )
    private static let blushMaterial = SimpleMaterial(
        color: UIColor(red: 0.98, green: 0.55, blue: 0.58, alpha: 0.45),
        roughness: 0.9,
        isMetallic: false
    )
}
