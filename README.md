# Vision Pro 虚拟女友

头显只负责展示与交互；对话、TTS 全走云端。口型用本地 BlendShape，**不**生成对嘴型视频。

## 架构

1. Vision Pro（RealityKit）：显示 3D 角色、收麦、播音、动嘴  
2. DeepSeek：流式聊天  
3. MiniMax：流式 TTS（WebSocket t2a_v2_bidi）  
4. 模型：七宝形象 → 绑骨 USDZ  

## 开发节奏

1. MiniMax Code 先出工程骨架与云端对接  
2. Cursor 再改 visionOS / 真机 / 上架相关  

## 不做

- 每句生成口型视频  
- 擦边色情内容（要上架）
