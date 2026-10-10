import RealityKit
import UIKit

/// 占位 3D 人：全部用 RealityKit 自带的基础几何体拼的，不依赖任何外部模型。
///
/// 换真人模型时：把 `ModelEntity(named:)` 加载出来的实体挂到 `root` 上，
/// 保留 `update(deltaTime:jawOpen:)` 里的口型驱动逻辑就行——
/// `jawOpen` 是 0…1 的音量值，含义和真模型的 `jawOpen` blendshape 一致。
final class PlaceholderAvatar {

    let root = Entity()

    private let bodyNode = Entity()
    private let headNode = Entity()
    private let jaw = ModelEntity(
        mesh: .generateBox(size: [0.17, 0.10, 0.15], cornerRadius: 0.04),
        materials: [Self.skinMaterial]
    )
    private let mouth = ModelEntity(
        mesh: .generateSphere(radius: 0.05),
        materials: [Self.mouthMaterial]
    )

    private let jawRestY: Float = -0.075
    private var elapsed: Float = 0

    init() {
        root.name = "placeholder-avatar"
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
                mesh: .generateCapsule(height: 0.26, radius: 0.045),
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

        // 眼睛
        for side: Float in [-1, 1] {
            let eye = ModelEntity(
                mesh: .generateSphere(radius: 0.017),
                materials: [Self.eyeMaterial]
            )
            eye.name = side < 0 ? "eye-left" : "eye-right"
            eye.position = [side * 0.045, 0.012, 0.098]
            headNode.addChild(eye)
        }

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
    func update(deltaTime: Float, jawOpen: Float) {
        elapsed += deltaTime

        // 呼吸 + 轻微左右晃，先让占位模型「活」着
        bodyNode.position.y = sin(elapsed * 1.4) * 0.012
        headNode.orientation = simd_quatf(angle: sin(elapsed * 0.65) * 0.06, axis: [0, 1, 0])
        headNode.position.y = sin(elapsed * 1.4 + 0.6) * 0.004

        let open = min(max(jawOpen, 0), 1)

        jaw.position.y = jawRestY - 0.024 * open
        jaw.scale = [1, 1 - 0.16 * open, 1]

        mouth.scale = [1 + 0.22 * open, 0.16 + 2.4 * open, 0.34 + 0.45 * open]
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
