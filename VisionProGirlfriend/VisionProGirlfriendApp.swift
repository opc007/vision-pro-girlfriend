import SwiftUI

@main
struct VisionProGirlfriendApp: App {

    @StateObject private var model = ChatViewModel()

    // 3D 用真模型还是占位人偶，由环境变量决定（Bundle 里有 qibao.usdz 就用真的）
    private let config = AppConfig()

    // 全屏沉浸（关掉穿透，用户只看到内容）。想让人还能看见自己房间，
    // 改成 `.mixed` 就行，其他代码不用动。
    @State private var immersionStyle: ImmersionStyle = .full

    var body: some Scene {
        // 文字聊天窗口
        WindowGroup(id: AppIDs.chatWindow) {
            ChatView()
                .environmentObject(model)
        }
        .defaultSize(width: 520, height: 660)

        // 3D 人物所在的沉浸空间
        ImmersiveSpace(id: AppIDs.immersiveSpace) {
            AvatarSceneView(
                levelSignal: model.audioPlayer.level,
                stateSignal: model.avatarState,
                config: config
            )
            .environmentObject(model)
        }
        .immersionStyle(selection: $immersionStyle, in: .full)
    }
}
