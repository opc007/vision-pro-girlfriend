import RealityKit
import SwiftUI

/// 沉浸空间里的 3D 场景：一个占位七宝，音量驱动嘴部开合。
///
/// 逐帧逻辑挂在 `SceneEvents.Update` 上，不走 SwiftUI 的刷新循环。
struct AvatarSceneView: View {

    /// 播放节点实时输出的音量（0…1）
    let levelSignal: LevelSignal

    var body: some View {
        RealityView { content in
            let avatar = PlaceholderAvatar()
            avatar.root.position = [0, 1.35, -1.05]

            let anchor = AnchorEntity(world: .zero)
            anchor.name = "avatar-anchor"
            anchor.addChild(avatar.root)
            content.add(anchor)

            _ = content.subscribe(to: SceneEvents.Update.self) { event in
                avatar.update(deltaTime: Float(event.deltaTime), jawOpen: levelSignal.value)
            }
        }
    }
}
