# Vision Pro 虚拟女友

头显只负责展示与交互；对话、TTS 全走云端。口型用本地音量驱动的占位 mesh，**不**生成对嘴型视频。

## 架构

1. Vision Pro（RealityKit）：显示 3D 角色、播音、动嘴
2. DeepSeek：流式聊天（SSE）
3. MiniMax：流式 TTS（WebSocket `t2a_v2_bidi`）
4. 模型：七宝形象 → 绑骨 USDZ（**待做**，当前是基础几何体拼的占位人）

数据流：

```
你打字 → DeepSeekClient(SSE) ─┬─→ 聊天窗口气泡
                                └─→ MiniMaxTTSClient(WebSocket t2a_v2_bidi)
                                        └─→ TTSAudioPlayer(AVAudioEngine 播放)
                                                └─→ 实时音量 → 音量驱动 jawOpen
```

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
│  ├─ ChatView.swift                   聊天窗口 UI
│  ├─ ChatViewModel.swift              串起 DeepSeek → TTS → 播放
│  └─ ChatMessage.swift                一条消息
├─ Services/
│  ├─ DeepSeekClient.swift             SSE 流式聊天
│  ├─ MiniMaxTTSClient.swift           WebSocket t2a_v2_bidi 状态机
│  └─ TTSAudioPlayer.swift             AVAudioEngine 播放 + 音量输出
├─ Avatar/
│  ├─ AvatarSceneView.swift            RealityView 场景 + 逐帧订阅
│  └─ PlaceholderAvatar.swift          占位 3D 人 + jawOpen 驱动
└─ Support/                            小工具（hex 解码、ID 常量）
```

`scripts/check_pbxproj.py` 是个不用 Xcode 的工程文件体检脚本，改完 pbxproj 可以跑一下：

```bash
python3 scripts/check_pbxproj.py
```

## 已知限制

1. **首句有 0.3~0.8 秒延迟。** MiniMax 的 WebSocket 流式目前只输出 mp3，没法边收边解，
   所以是「攒够一句 → 写临时文件 → AVAudioFile 解码 → 转换采样率 → 排队播放」。
   句子之间是连续的。想去掉这段延迟，下一步是换 AudioToolbox 的 `AudioFileStreamOpen` 边收边解。
2. **口型只是占位。** RealityKit 没有公开的 blendshape setter，所以用 jaw/mouth 两个 mesh 的
   缩放模拟。换成绑好骨的 USDZ 时，`PlaceholderAvatar.update(deltaTime:jawOpen:)` 里的
   `jawOpen`（0…1 音量）可以直接映射到真模型的 `jawOpen`。
3. **没有语音输入。** 麦克风权限的 Info 描述已经写好，但 ASR 还没接，先用文字聊。
4. **没有对话记忆裁剪。** 历史全量发给模型，轮次多了要加窗口/摘要。
5. 单连接同时只能有一个合成会话；空闲约 120 秒服务端会断开（2201），代码里每 30 秒发一次 ping 保活。

## 开发节奏

1. MiniMax Code：工程骨架 + 云端对接（已完成）
2. Cursor：visionOS 调优 / 真机 / 七宝 USDZ 接入 / 语音输入

## 不做

- 每句生成口型视频
- 擦边色情内容（要上架）
