import Foundation

/// 全局配置：**所有 Key 都从环境变量读，代码里不写死**。
///
/// 配置位置：Xcode ▸ Product ▸ Scheme ▸ Edit Scheme… ▸ Run ▸ Arguments ▸ Environment Variables
/// 勾上 "Run" 才会注入到 App 进程里。
///
/// 必填
/// - `DEEPSEEK_API_KEY`
/// - `MINIMAX_API_KEY`
///
/// 选填（都有默认值，国内平台一般不用改）
/// - `DEEPSEEK_BASE_URL`  默认 `https://api.deepseek.com`
/// - `DEEPSEEK_MODEL`     默认 `deepseek-chat`
/// - `MINIMAX_GROUP_ID`   老接口需要，作为 `?GroupId=` 拼在 WebSocket URL 上
/// - `MINIMAX_WS_BASE_URL` 默认 `wss://api.minimaxi.com`（国内）。国际版改成 `wss://api.minimax.io`
/// - `MINIMAX_TTS_MODEL`  默认 `speech-2.8-turbo`
/// - `MINIMAX_TTS_VOICE`  默认 `female-shaonv`（少女音）。其他常用：
///   `female-tianmei` 甜美 / `female-yujie` 御姐 / `qiaopi_mengmei` 俏皮萌妹
/// - `ASR_LOCALE`         默认 `zh-CN`（普通话）。英文改成 `en-US`
/// - `AVATAR_MODEL_NAME`  默认 `qibao`。Bundle 里有同名 `.usdz` 就用真实模型，没有就回退占位人偶
/// - `AVATAR_MODEL_SCALE` 默认 `1.0`。真实模型大小不对时调它
/// - `AVATAR_MODEL_OFFSET_Y` 默认 `0`。真模型悬空/埋进地板时调它
/// - `AVATAR_USE_CUSTOM_MODEL` 默认 `1`。设 `0` 强制用回占位人偶
/// - `APP_PERSONA`        覆盖七宝的人设提示词
struct AppConfig {

    // MARK: - DeepSeek

    let deepSeekAPIKey: String
    let deepSeekBaseURL: String
    let deepSeekModel: String

    // MARK: - MiniMax

    let minimaxAPIKey: String
    let minimaxGroupID: String
    let minimaxWSBaseURL: String
    let minimaxModel: String
    let minimaxVoiceID: String

    /// 语音识别语言。默认普通话，改成 `en-US` 就是英文。
    let asrLocale: String

    /// 3D 形象。Bundle 里放了同名 `.usdz` 就用真实模型，没有就自动回退占位人偶。
    ///
    /// 怎么放：把 `qibao.usdz` 丢进 `VisionProGirlfriend/`，并在 Xcode 里
    /// 勾上「Copy Bundle Resources」。名字对不上就用 `AVATAR_MODEL_NAME` 改。
    let avatarModelName: String
    /// 真实模型的缩放。不同建模软件导出的尺寸差很多，大了/小了改这个。
    let avatarModelScale: Float
    /// 真实模型的垂直偏移（米）。原点通常在脚底，站着就对了；
    /// 悬空了给负数，埋进地板了给正数
    let avatarModelOffsetY: Float
    /// 置 0 可以强制用回占位人偶（做对比、或者模型有问题时先退出来）
    let avatarUseCustomModel: Bool

    /// 七宝的人设提示词。要求：短句、口语化、不要 Markdown，
    /// 因为这段文字会直接丢给 TTS 念出来。
    let personaPrompt: String

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        func value(_ key: String, _ fallback: String = "") -> String {
            guard let raw = environment[key] else { return fallback }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? fallback : trimmed
        }

        deepSeekAPIKey = value("DEEPSEEK_API_KEY")
        deepSeekBaseURL = value("DEEPSEEK_BASE_URL", "https://api.deepseek.com")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        deepSeekModel = value("DEEPSEEK_MODEL", "deepseek-chat")

        minimaxAPIKey = value("MINIMAX_API_KEY")
        minimaxGroupID = value("MINIMAX_GROUP_ID")
        minimaxWSBaseURL = value("MINIMAX_WS_BASE_URL", "wss://api.minimaxi.com")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        minimaxModel = value("MINIMAX_TTS_MODEL", "speech-2.8-turbo")
        minimaxVoiceID = value("MINIMAX_TTS_VOICE", "female-shaonv")
        asrLocale = value("ASR_LOCALE", "zh-CN")

        avatarModelName = value("AVATAR_MODEL_NAME", "qibao")
        avatarModelScale = Float(value("AVATAR_MODEL_SCALE", "1.0")) ?? 1.0
        avatarModelOffsetY = Float(value("AVATAR_MODEL_OFFSET_Y", "0")) ?? 0
        avatarUseCustomModel = !["0", "false", "no", "off"].contains(
            value("AVATAR_USE_CUSTOM_MODEL", "1").lowercased()
        )

        personaPrompt = value(
            "APP_PERSONA",
            """
            你叫七宝，是一个住在 Vision Pro 里的虚拟女友。
            说话规则：
            1. 中文，口语化，像真人聊天，每次回复 1~3 句话，不要长篇大论。
            2. 绝对不要用 Markdown（不要 ** 粗体、不要 # 标题、不要列表、不要代码块）。
            3. 不要输出 emoji。
            4. 句末保留中文标点，语音合成靠标点断句，去掉标点会导致朗读不自然。
            5. 保持温柔、有点俏皮，但保持分寸，不做擦边内容。
            """
        )
    }

    // MARK: - 状态

    var hasDeepSeekKey: Bool { !deepSeekAPIKey.isEmpty }
    var hasMiniMaxKey: Bool { !minimaxAPIKey.isEmpty }

    /// 缺 Key 时给 UI 看的提示，不写死任何密钥内容。
    var missingKeysDescription: String {
        guard !missingKeys.isEmpty else { return "" }
        return "缺少环境变量：\(missingKeys.joined(separator: "、"))。请在 Scheme ▸ Run ▸ Arguments ▸ Environment Variables 里补上。"
    }

    /// 只列名字，给状态栏这种放不下长句的地方用
    var missingKeysShort: String {
        missingKeys.joined(separator: "、")
    }

    private var missingKeys: [String] {
        var missing: [String] = []
        if !hasDeepSeekKey { missing.append("DEEPSEEK_API_KEY") }
        if !hasMiniMaxKey { missing.append("MINIMAX_API_KEY") }
        return missing
    }

    // MARK: - 端点

    /// `https://api.deepseek.com` → `https://api.deepseek.com/chat/completions`
    var deepSeekChatCompletionsURL: URL? {
        URL(string: "\(deepSeekBaseURL)/chat/completions")
    }

    /// `wss://api.minimaxi.com` → `wss://api.minimaxi.com/ws/v1/t2a_v2_bidi`
    var minimaxBidiTTSURL: URL? {
        guard var components = URLComponents(string: "\(minimaxWSBaseURL)/ws/v1/t2a_v2_bidi") else {
            return nil
        }
        if !minimaxGroupID.isEmpty {
            components.queryItems = [URLQueryItem(name: "GroupId", value: minimaxGroupID)]
        }
        return components.url
    }
}
