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

    /// 由 App 传进来，AvatarFactory 靠它决定用真实模型还是占位
    let config: AppConfig

    /// 真实模型只能异步加载，而 `RealityView` 的构建闭包**不是** async 的，
    /// 所以形象先在 `.task` 里解析好，再交给 `RealityView` 摆。
    ///
    /// 加载失败时 `AvatarFactory` 直接给占位人偶，`sourceDescription` 和之前一样，
    /// `.id()` 不变 → 场景不会重建，也就不会闪一下。
    @State private var avatar: DrivableAvatar?

    var body: some View {
        Group {
            if let avatar {
                scene(avatar)
            }
        }
        .task {
            let loaded = await AvatarFactory.make(config: config)
            NSLog("[Avatar] 当前形象：\(loaded.sourceDescription)")
            avatar = loaded
        }
    }

    @ViewBuilder
    private func scene(_ avatar: DrivableAvatar) -> some View {
        RealityView { content in
            avatar.root.position = avatar.worldPosition

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
        // 形象换了才重建场景。占位 → 占位（加载失败回退）不会触发，所以不闪
        .id(avatar.sourceDescription)
    }
}
