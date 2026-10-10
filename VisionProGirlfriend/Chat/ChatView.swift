import SwiftUI

/// 聊天窗口。3D 人物在 ImmersiveSpace 里，这个窗口只负责文字。
struct ChatView: View {

    @EnvironmentObject private var model: ChatViewModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.scenePhase) private var scenePhase

    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            transcript
            composer
        }
        .padding(16)
        .frame(minWidth: 460, minHeight: 560)
        .task {
            model.bootstrap()
            await enterImmersiveSpace()
        }
        .onChange(of: scenePhase) { _, phase in
            // 退到后台就断开，省电；下次说话会自动重连
            if phase == .background {
                model.shutdown()
            }
        }
        .onChange(of: model.input) { _, newValue in
            // 插话：七宝还在说，用户就开始打字 —— 直接打断
            if model.isReplying, !newValue.isEmpty {
                model.interruptSpeaking()
            }
        }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Circle()
                .fill(Color.pink.gradient)
                .frame(width: 36, height: 36)
                .overlay {
                    Text("七")
                        .font(.caption.bold())
                        .foregroundStyle(Color.white)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text("七宝")
                    .font(.title3.bold())
                Text(model.statusText)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            if model.isReplying {
                Button(role: .destructive) {
                    model.interruptSpeaking()
                } label: {
                    Label("打断", systemImage: "stop.fill")
                }
            } else {
                // 说话中：提示可以边说边打字打断
                if model.isSpeaking {
                    Text("说一句…直接打字就能打断她")
                        .font(.caption2)
                        .foregroundStyle(Color.secondary.opacity(0.7))
                }
            }

            Button {
                Task { await enterImmersiveSpace(force: true) }
            } label: {
                Label("3D", systemImage: "arkit")
            }

            Button {
                model.clearChat()
            } label: {
                Image(systemName: "trash")
            }
            .help("清空对话")
        }
    }

    // MARK: - 对话列表

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: model.messages.last?.text) { _, _ in
                guard let last = model.messages.last else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.secondary.opacity(0.1))
        }
    }

    // MARK: - 输入区

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                TextField("跟七宝说点什么…", text: $model.input, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($isInputFocused)
                    .padding(10)
                    .background {
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.secondary.opacity(0.16))
                    }
                    .onSubmit { model.send() }

                Button {
                    model.send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .opacity(canSend ? 1 : 0.4)
            }

            Text("语音输入、眨眼、注视跟随留给下一阶段；现在先用文字聊。")
                .font(.caption2)
                .foregroundStyle(Color.secondary.opacity(0.6))
        }
    }

    private var canSend: Bool {
        !model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.isReplying
    }

    // MARK: - 沉浸空间

    // 标 @MainActor：这个方法会去改 ViewModel 的 @Published 状态，
    // 而它本身不是 View.body，不带 MainActor 隔离。
    @MainActor
    private func enterImmersiveSpace(force: Bool = false) async {
        let result = await openImmersiveSpace(id: AppIDs.immersiveSpace)
        if case .opened = result {
            if force { model.setNote("已回到 3D 空间") }
        } else {
            model.setNote("3D 空间没打开，点右上角「3D」再试一次")
        }
    }
}

// MARK: - 气泡

private struct MessageBubble: View {
    let message: ChatMessage

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 4) {
                Text(message.text.isEmpty ? "…" : message.text)
                    .font(.body)
                    .foregroundStyle(isUser ? Color.white : Color.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background {
                RoundedRectangle(cornerRadius: 16)
                    .fill(isUser ? AnyShapeStyle(Color.pink.gradient) : AnyShapeStyle(Color.secondary.opacity(0.2)))
            }
            if !isUser { Spacer(minLength: 40) }
        }
    }
}
