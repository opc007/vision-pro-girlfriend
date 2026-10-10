import RealityKit
import SwiftUI

/// 沉浸空间里的 3D 场景。
///
/// 逐帧逻辑挂在 `SceneEvents.Update` 上，不走 SwiftUI 的刷新循环。
/// 状态和音量都是从别处（ViewModel）搬过来的线程安全信号。
struct AvatarSceneView: View {

    /// 播放节点实时输出的音量（0…1）
    let levelSignal: LevelSignal

    /// 当前该摆什么状态：待机 / 在听 / 在想 / 在说
    let stateSignal: AvatarStateSignal

    var body: some View {
        RealityView { content in
            let avatar = PlaceholderAvatar()
            avatar.root.position = [0, 1.35, -1.05]

            let anchor = AnchorEntity(world: .zero)
            anchor.name = "avatar-anchor"
            anchor.addChild(avatar.root)
            content.add(anchor)

            _ = content.subscribe(to: SceneEvents.Update.self) { event in
                avatar.update(
                    deltaTime: Float(event.deltaTime),
                    jawOpen: levelSignal.value,
                    state: stateSignal.value
                )
            }
        }
    }
}
