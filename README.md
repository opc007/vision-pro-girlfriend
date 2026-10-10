# Vision Pro 虚拟女友

头显只负责展示与交互；对话、TTS 全走云端。口型用本地音量驱动的占位 mesh，**不**生成对嘴型视频。

## 架构

1. Vision Pro（RealityKit）：显示 3D 角色、播音、动嘴
2. DeepSeek：流式聊天（SSE）
3. MiniMax：流式 TTS（WebSocket `t2a_v2_bidi`）
4. 模型：七宝形象 → Bundle 里有 `qibao.usdz` 就用真模型，没有就回退占位人偶（见「换成自己的七宝」）

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
顶栏也会出现「说一句…直接打字就能打断她」的提示。语音输入也一样：开麦会先打断她正在说的话，
否则她自己的声音会被识别成你说的话。

## 七宝有反应了

3D 不再只是嘴在动。她的状态跟着聊天流程走：

| 状态 | 什么时候 | 表现 |
|---|---|---|
| **待机** | 没事发生 | 慢呼吸，头缓慢左右晃，每 2.5~6 秒眨一次眼 |
| **在听** | 麦克风开着 | 头微微前倾，眼睛睁大，眉毛抬起，呼吸变快 |
| **在想** | DeepSeek 在流式吐字 | 头歪向一边，眼睛左右扫，像在琢磨 |
| **在说** | TTS 在播 | 跟着音量点头，眉毛随音量抬，嘴由音量驱动（`jawOpen`） |

「这一帧该怎么摆」的算术全在 `Avatar/AvatarState.swift` 的 `AvatarPose` 里，**是纯函数、
不碰 RealityKit**，所以能被单测覆盖（41 项）；RealityKit 那层只负责把算出来的值赋给实体。

想调手感就改 `AvatarPose.solve`：每个状态的头部俯仰/偏航/侧歪、眉毛抬起量、呼吸幅度
都是里面的常数，改完跑一下 `scripts/test_avatar_pose.swift` 就能确认没飞出合理范围。

## 换成自己的七宝（USDZ）

App 支持直接加载真实模型。**没有模型也完全能跑**——自动回退到占位人偶，不会崩。

### 怎么放

1. 把模型文件命名成 `qibao.usdz`，放进 `VisionProGirlfriend/` 目录（和 `AppConfig.swift` 同级）
2. 在 Xcode 里选中 `qibao.usdz`，勾上 **Copy Bundle Resources**（Target Membership 保持 App）
3. 直接 `⌘R`

换个名字就用环境变量 `AVATAR_MODEL_NAME`（别带 `.usdz` 后缀）。

### 模型大小/位置不对

不同建模软件导出的尺寸、原点差很多（有的原点在脚底，有的在中心）。悬空、埋进地板或者小得看不见时用环境变量调：

```bash
AVATAR_MODEL_SCALE=0.35      # 缩放
AVATAR_MODEL_OFFSET_Y=-0.3   # 上下挪（米）
```

模型有问题想先退出来看看默认效果：`AVATAR_USE_CUSTOM_MODEL=0`，强制用占位人偶。

### 什么情况下会回退占位

| 情况 | 结果 |
|---|---|
| Bundle 里没有 `qibao.usdz` | 占位人偶（默认状态，不用做任何事） |
| 文件在，但加载失败（损坏 / 不是合法 usdz） | 占位人偶 + 控制台一行 `[Avatar]` 日志 |
| 模型名配成空 | 占位人偶 |

三种情况**都不崩**，判断逻辑在 `AvatarModelPlan` 里，有单测覆盖。

### 真模型的表情是怎么驱动的

RealityKit 没有公开的 blendshape setter，所以口型还是用变换做的：

- 在 USDZ 里把头命名成 `head`、下巴命名成 `jaw`，七宝就会跟着状态转头、低头、开口
- 没命名的话只会做呼吸起伏和前后倾（不会是个木头桩子，但表情会少很多）
- 眨眼、眉毛、呼吸这些状态量来自 `AvatarPose`，和占位人偶是同一份算解

想换成真模型的 blendshape，把 `UsdzAvatar.update(deltaTime:jawOpen:state:)` 里的
`jawOpen`（0…1 音量）接到真模型的 `jawOpen` 上就行。

## 语音输入

输入框左边有个麦克风按钮，**按住说话为主，轻点保持为辅**：

- **按住**（超过 0.25 秒）就开麦，**松手立刻发送**
- **轻点一下**则开麦并保持，再点一下才收——手腕不方便一直按着时用这个
- 说完停顿 1.6 秒也会自动收，不用管按没按着
- 识别过程中横幅右上角有个 ✕，可以丢掉这次识别不发送
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

### 插话：她说话时你按住麦克风

按下的那一刻会**先停掉她的 TTS，再开麦**。顺序很关键——如果先开麦，她自己的声音会被
麦克风听进去当成你说的话发出去，她就会开始复述自己。

打字插话也一样：她在说的时候你开始打字，这一轮会自动中断（`task_cancel` + 停播放器）。

### 出错时看到什么

所有报错都翻译成人话了，顶栏和气泡里直接写「怎么办」，不甩错误码：

| 情况 | 你会看到 |
|---|---|
| 没配 Key | 「还差 Key：DEEPSEEK_API_KEY、MINIMAX_API_KEY。配好再跑，详见 README。」 |
| 没网 / 网断了 | 「设备没连上网络……」/「网络中途断了，会自动重连，再说一次就行。」 |
| Key 不对 / 没余额 | 「DeepSeek 拒绝了请求，多半是 API Key 不对、没余额，或没开这个模型。」 |
| 限流 | 「请求太频繁，等十几秒再试。」 |
| 服务端开小差 | 「DeepSeek 服务端开小差了，稍后再试……」 |
| 语音连接空闲被断 | 「语音连接空闲太久被服务端断开了，下一句会自动重连。」 |
| 麦克风/识别权限被拒 | 「没有麦克风权限，去『设置 ▸ 隐私与安全性 ▸ 麦克风』里打开。」 |
| 没听清 | 「没听清，再说一次？」 |

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
| `AVATAR_MODEL_NAME` | | `qibao` | Bundle 里有同名 `.usdz` 就用真模型 |
| `AVATAR_MODEL_SCALE` | | `1.0` | 真模型大小不对时调它 |
| `AVATAR_MODEL_OFFSET_Y` | | `0` | 真模型悬空/埋进地板时调它 |
| `AVATAR_USE_CUSTOM_MODEL` | | `1` | 设 `0` 强制用回占位人偶 |
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
│  ├─ AvatarState.swift                四种状态 + 姿态解算（纯函数，有单测）
│  ├─ AvatarModelPlan.swift            用真模型还是占位人偶（纯逻辑，有单测）
│  ├─ BlinkTimer.swift                 眨眼节奏（纯逻辑，占位和真模型共用）
│  ├─ DrivableAvatar.swift             形象协议 + AvatarFactory（决定加载哪个）
│  ├─ UsdzAvatar.swift                 真实 USDZ 的加载与驱动
│  └─ PlaceholderAvatar.swift          占位 3D 人，把 AvatarPose 摆到实体上
└─ Support/                            小工具（hex 解码、电平信号、ID 常量、友好报错文案）

scripts/
├─ check_pbxproj.py                    不用 Xcode 的工程文件体检脚本
├─ test_speech_sanitizer.swift         文本清洗的断言测试（15 项）
├─ test_avatar_pose.swift              姿态解算的断言测试（41 项）
└─ test_overnight.swift                模型回退/眨眼/友好提示的断言测试（42 项）
```

三个测试都是纯 Swift、不依赖 Xcode 的框架，`swiftc` 直接编就能跑，全绿返回 0，可以进 CI。

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

swiftc VisionProGirlfriend/Avatar/AvatarState.swift \
       scripts/test_avatar_pose.swift -o /tmp/pose-test && /tmp/pose-test

# 通宵任务新增的（模型回退 / 环境变量 / 眨眼 / 友好提示，42 项）
swiftc VisionProGirlfriend/Avatar/AvatarModelPlan.swift \
       VisionProGirlfriend/Avatar/BlinkTimer.swift \
       VisionProGirlfriend/Support/FriendlyError.swift \
       VisionProGirlfriend/Config/AppConfig.swift \
       VisionProGirlfriend/Services/DeepSeekClient.swift \
       VisionProGirlfriend/Services/MiniMaxTTSClient.swift \
       VisionProGirlfriend/Services/TTSAudioPlayer.swift \
       VisionProGirlfriend/Services/AudioSessionController.swift \
       VisionProGirlfriend/Support/HexData.swift \
       VisionProGirlfriend/Support/LevelSignal.swift \
       VisionProGirlfriend/Support/AppIDs.swift \
       scripts/test_overnight.swift -o /tmp/overnight-test && /tmp/overnight-test
```

## 已知限制

1. **首句有 0.3~0.8 秒延迟。** MiniMax 的 WebSocket 流式目前只输出 mp3，没法边收边解，
   所以是「攒够一句 → 写临时文件 → AVAudioFile 解码 → 转换采样率 → 排队播放」。
   句子之间是连续的。想去掉这段延迟，下一步是换 AudioToolbox 的 `AudioFileStreamOpen` 边收边解。
2. **表情不是真 blendshape。** RealityKit 没有公开的 blendshape setter，所以表情是用 jaw/mouth/eye/brow
   几个 mesh 的位移和缩放摆出来的，不是真的 blendshape——真模型（USDZ）也一样，是靠变换做的。
   要接真 blendshape，把 `UsdzAvatar.update(deltaTime:jawOpen:state:)` 里的 `jawOpen`
   （0…1 音量）直接映射到模型的 `jawOpen` 上，`AvatarPose` 的其余常数换成真模型的动画参数即可。
   现在也不会看人 —— 眼神是脚本，不是眼动追踪。
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
