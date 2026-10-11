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
            if model.isListening {
                listeningBanner
            }

            HStack(spacing: 10) {
                micButton

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

            // 语音链路走到哪一步了。「点了没反应」的时候看这一行就知道卡在哪
            Text(model.voiceStage.isEmpty ? "语音输入待命" : model.voiceStage)
                .font(.caption2)
                .foregroundStyle(
                    model.voiceStage.hasPrefix("✗")
                        ? Color.red
                        : (model.isListening ? Color.green : Color.secondary.opacity(0.6))
                )

            Text("说话时直接打字就能打断她")
                .font(.caption2)
                .foregroundStyle(Color.secondary.opacity(0.6))
        }
    }

    /// 按住说话为主，轻点保持为辅：
    /// - 按住 → 松手立刻结束并发送
    /// - 轻点一下 → 开麦并保持（再轻点一下才收），手腕不方便长按时用
    ///
    /// 按下/松开的判定全在 `ChatViewModel.micPressDown/micPressUp` 里
    /// （手势状态放 ViewModel，不放 View 的 @State），
    /// 这里只负责把 touch 接过去。
    private var micButton: some View {
        micIcon
            // 命中区域放大到 64pt 方块，不是 52pt 圆：
            // 模拟器上用鼠标点，小圆很难点中，点不中在用户看来就是「没反应」
            .frame(width: 64, height: 64)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in model.micPressDown() }
                    .onEnded { _ in model.micPressUp() }
            )
            // ⚠️ 这里**不能**用 .disabled(!model.speechAvailable)：
            // 模拟器上 SFSpeechRecognizer(zh-CN).isAvailable 经常是 false
            // （没装离线模型），一禁用按钮就变成死按钮，用户点了完全没反应。
            // 不可用时改成给出可见提示，按下去会告诉他到底为什么。
            .opacity(model.isListening ? 1 : 0.9)
            .help(model.isListening ? "松开发送 · 轻点可以保持开麦" : "按住说话，松开发送")
    }

    /// 麦克风按钮的样子（按住/保持开麦时靠音量呼吸圈表示在听）
    private var micIcon: some View {
        ZStack {
            Circle()
                .fill(model.isListening ? Color.red : Color.secondary.opacity(0.16))
                .frame(width: 44, height: 44)

            // 麦克风电平，让用户知道它真的在听
            if model.isListening {
                Circle()
                    .stroke(Color.red.opacity(0.35), lineWidth: 3)
                    .frame(
                        width: 44 + CGFloat(model.micLevel) * 22,
                        height: 44 + CGFloat(model.micLevel) * 22
                    )
            }

            Image(systemName: model.isListening ? "waveform" : "mic.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(model.isListening ? Color.white : Color.primary)

            // 识别不可用时给个看得见的角标（但仍然可以按，按了会说明原因）
            if !model.speechAvailable && !model.isListening {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .offset(x: 16, y: -16)
            }
        }
        .frame(width: 52, height: 52)
    }

    @ViewBuilder
    private var listeningBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "mic.fill")
                .font(.caption)
                .foregroundStyle(Color.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.partialSpeechText.isEmpty ? "在听…" : model.partialSpeechText)
                    .font(.callout)
                    .foregroundStyle(model.partialSpeechText.isEmpty ? Color.secondary : Color.primary)
                    .lineLimit(3)
                Text("说完停顿一下就会自动发出去")
                    .font(.caption2)
                    .foregroundStyle(Color.secondary.opacity(0.7))
            }
            Spacer(minLength: 0)

            // 识别错了、或者说了一半不想说了，可以丢掉这次
            Button {
                model.cancelListening()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Color.secondary)
            }
            .buttonStyle(.plain)
            .help("丢掉这次识别")
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.red.opacity(0.08))
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
