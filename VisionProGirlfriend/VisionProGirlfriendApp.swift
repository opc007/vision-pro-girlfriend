import SwiftUI

@main
struct VisionProGirlfriendApp: App {

    @StateObject private var model = ChatViewModel()

    var body: some Scene {
        // 文字聊天窗口
        WindowGroup(id: AppIDs.chatWindow) {
            ChatView()
                .environmentObject(model)
        }
        .defaultSize(width: 520, height: 660)

        // 3D 人物所在的沉浸空间
        ImmersiveSpace(id: AppIDs.immersiveSpace) {
            AvatarSceneView(levelSignal: model.audioPlayer.level)
                .environmentObject(model)
        }
        .immersiveStyle(.fullScreen)
    }
}
