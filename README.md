# Vision Pro 虚拟女友

头显只负责展示与交互；对话、TTS 全走云端。口型用本地音量驱动的占位 mesh，**不**生成对嘴型视频。

## 架构

1. Vision Pro（RealityKit）：显示 3D 角色、播音、动嘴
2. DeepSeek：流式聊天（SSE）
3. MiniMax：流式 TTS（WebSocket `t2a_v2_bidi`）
4. 模型：七宝形象 → 绑骨 USDZ（**待做**，当前是基础几何体拼的占位人）

数据流：

```
你打字 ┐
        ├─→ DeepSeekClient(SSE) ─┬─→ 聊天窗口气泡
你说话 ┘  SFSpeechRecognizer      └─→ SpeechTextSanitizer（去 Markdown/emoji，保留标点）
                                       └─→ MiniMaxTTSClient(WebSocket t2a_v2_bidi)
                                               └─→ TTSAudioPlayer(AVAudioEngine 播放)
                                                       └─→ 实时音量 → 音量驱动 jawOpen
```

### 说话时可以直接打字打断

七宝还在说的时候你开始打字，这一轮会自动中断（`task_cancel` + 停播放器）。
顶栏也会出现「说一句…直接打字就能打断她」的提示。

## 语音输入

输入框左边有个麦克风按钮：

- **点一下**开麦，**再点一下**收；说完停顿 1.6 秒也会自动收，不用再点
- 麦克风外面那圈会随音量变大变小，说明它真的在听
- 识别中的文字实时显示在输入框上方，确认没听错
- 识别结束**自动发送**，走的是和打字完全一样的 DeepSeek → TTS 流程
- 开麦会先把七宝正在说的话打断（边听边插话），否则她会把麦克风里自己的声音当成你说的话

用的是系统 `SFSpeechRecognizer`：

- 模拟器上走 Apple 的服务端识别，**模拟器需要联网**
- 真机上如果装了对应语言的离线模型，会自动切离线识别，更快也不用把音频传出设备
- 语言用 `ASR_LOCALE` 配，默认 `zh-CN`（普通话），英文设 `en-US`
- 最多连说 30 秒

首次点麦克风会弹权限申请（麦克风 + 语音识别）。拒了也能继续打字，聊天窗口顶部会说明原因。

## 环境要求

- **Xcode 16 或更高**（visionOS 1.0 SDK；`objectVersion = 77` 的新工程格式）
- macOS 14.5 以上，才能跑 visionOS Simulator
- DeepSeek 和 MiniMax 的 API Key 各一个

## 怎么跑起来

### 1. 打开工程

```bash
open VisionProGirlfriend.xcodeproj
```

首次打开时 Xcode 会自动生成 `VisionProGirlfriend` scheme（仓库里已经带了一份 shared scheme）。

### 2. 配置 Key（不要写进代码，也不要提交）

Xcode 菜单：**Product ▸ Scheme ▸ Edit Scheme… ▸ Run ▸ Arguments ▸ Environment Variables**，
点 `+` 添加，**勾上右边的 `Run`**（不勾的话 Debug 时不会注入）：

| 变量名 | 必填 | 默认值 | 说明 |
|---|---|---|---|
| `DEEPSEEK_API_KEY` | ✅ | — | platform.deepseek.com 的 API Key |
| `MINIMAX_API_KEY` | ✅ | — | MiniMax 开放平台的 API Key |
| `DEEPSEEK_BASE_URL` | | `https://api.deepseek.com` | |
| `DEEPSEEK_MODEL` | | `deepseek-chat` | |
| `MINIMAX_GROUP_ID` | | 空 | 老接口需要，会拼成 `?GroupId=` |
| `MINIMAX_WS_BASE_URL` | | `wss://api.minimaxi.com` | **国际版账号改成 `wss://api.minimax.io`** |
| `MINIMAX_TTS_MODEL` | | `speech-2.8-turbo` | |
| `MINIMAX_TTS_VOICE` | | `female-shaonv` | 少女音。其他：`female-tianmei` 甜美 / `female-yujie` 御姐 / `qiaopi_mengmei` 俏皮萌妹 |
| `ASR_LOCALE` | | `zh-CN` | 语音识别语言，英文设 `en-US` |
| `APP_PERSONA` | | 内置人设 | 覆盖七宝的人设提示词 |

代码里所有 Key 都从 `ProcessInfo.processInfo.environment` 读，仓库里没有任何密钥。
缺 Key 启动时聊天窗口顶部会直接提示缺了哪个。

> 想彻底免手工配置：把 Key 写进 `~/.zshenv` 或 launchd 环境变量也行，
> Simulator 会继承 Xcode 进程的环境。

### 3. 跑模拟器

1. 顶部 target 选择 **VisionProGirlfriend**
2. Scheme 选 **VisionProGirlfriend**
3. 设备选 **visionOS Simulator**（任意一台，例如 "Apple Vision Pro"）
4. `⌘R`

启动后会：

- 打开一个聊天窗口（文字）
- 自动进入全屏沉浸空间，里面站着占位七宝
- 打字发送 → 七宝边流式吐字、边出声、嘴跟着音量动

窗口和沉浸空间之间用 pinch 手势切换；沉浸空间里点右上角可以回窗口。

### 4. 跑真机（可选，还没调通）

需要 Apple Developer 账号：

- Target ▸ Signing & Capabilities 选自己的 Team
- Bundle ID 改成自己独占的（默认 `com.opc007.visionprogirlfriend`）
- 免费账号需要 entitlement 支持才能装真机

## 代码在哪

```
VisionProGirlfriend/
├─ VisionProGirlfriendApp.swift        App 入口：WindowGroup（聊天）+ ImmersiveSpace（3D）
├─ Config/AppConfig.swift              全部配置与 Key（只读环境变量）
├─ Chat/
│  ├─ ChatView.swift                   聊天窗口 UI（含麦克风按钮）
│  ├─ ChatViewModel.swift              串起 ASR → DeepSeek → TTS → 播放
│  └─ ChatMessage.swift                一条消息
├─ Services/
│  ├─ SpeechRecognizerService.swift    麦克风 → SFSpeechRecognizer → 文字
│  ├─ AudioSessionController.swift     播放/录音的 AVAudioSession 唯一主人
│  ├─ DeepSeekClient.swift             SSE 流式聊天
│  ├─ MiniMaxTTSClient.swift           WebSocket t2a_v2_bidi 状态机
│  ├─ SpeechTextSanitizer.swift        喂给 TTS 前的文本清洗（保标点）
│  └─ TTSAudioPlayer.swift             AVAudioEngine 播放 + 音量输出
├─ Avatar/
│  ├─ AvatarSceneView.swift            RealityView 场景 + 逐帧订阅
│  └─ PlaceholderAvatar.swift          占位 3D 人 + jawOpen 驱动
└─ Support/                            小工具（hex 解码、电平信号、ID 常量）

scripts/
├─ check_pbxproj.py                    不用 Xcode 的工程文件体检脚本
└─ test_speech_sanitizer.swift         文本清洗的断言测试
```

### 想改沉浸空间的观感

`VisionProGirlfriendApp.swift` 里：

```swift
@State private var immersionStyle: ImmersionStyle = .full
...
.immersionStyle(selection: $immersionStyle, in: .full)
```

`.full` 关掉穿透（纯黑背景，适合现在的占位模型）；想让人看见自己房间就改成 `.mixed`。
也可以 `in: .full, .mixed` 两个都给，运行时切。

## 自检脚本

改完 pbxproj 跑一下结构体检：

```bash
python3 scripts/check_pbxproj.py
```

文本清洗的断言测试，只要有 `swiftc` 就能跑（Mac 上 `xcrun swiftc` 也行）：

```bash
swiftc VisionProGirlfriend/Services/SpeechTextSanitizer.swift \
       scripts/test_speech_sanitizer.swift -o /tmp/tts-test && /tmp/tts-test
```

## 已知限制

1. **首句有 0.3~0.8 秒延迟。** MiniMax 的 WebSocket 流式目前只输出 mp3，没法边收边解，
   所以是「攒够一句 → 写临时文件 → AVAudioFile 解码 → 转换采样率 → 排队播放」。
   句子之间是连续的。想去掉这段延迟，下一步是换 AudioToolbox 的 `AudioFileStreamOpen` 边收边解。
2. **口型只是占位。** RealityKit 没有公开的 blendshape setter，所以用 jaw/mouth 两个 mesh 的
   缩放模拟。换成绑好骨的 USDZ 时，`PlaceholderAvatar.update(deltaTime:jawOpen:)` 里的
   `jawOpen`（0…1 音量）可以直接映射到真模型的 `jawOpen`。
3. **语音识别依赖系统能力。** 模拟器走 Apple 服务端识别（要联网、结果可能偏慢）；
   真机装了对应语言的离线模型才走离线。识别质量由系统决定，没法调。
4. **历史是滑动窗口，不是真记忆。** 每次发 4000 字符以内的最近几轮，更早的丢掉。
   想要「她记得三个月前说过的话」得加向量库或摘要。
5. **清洗是保守的。** `SpeechTextSanitizer` 只删 Markdown 记号、代码块、链接、emoji、零宽字符，
   不会去改写模型的话。念到英文长词或者颜文字还是会怪，想更好就得让模型少输出这类内容。
6. 单连接同时只能有一个合成会话；空闲约 120 秒服务端会断开（2201），代码里每 30 秒发一次 ping 保活。

## 开发节奏

1. MiniMax Code：工程骨架 + 云端对接（已完成）
2. Cursor：visionOS 调优 / 真机 / 七宝 USDZ 接入 / 语音输入

## 不做

- 每句生成口型视频
- 擦边色情内容（要上架）
