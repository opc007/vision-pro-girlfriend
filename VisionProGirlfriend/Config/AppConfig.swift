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
        var missing: [String] = []
        if !hasDeepSeekKey { missing.append("DEEPSEEK_API_KEY") }
        if !hasMiniMaxKey { missing.append("MINIMAX_API_KEY") }
        guard !missing.isEmpty else { return "" }
        return "缺少环境变量：\(missing.joined(separator: "、"))。请在 Scheme ▸ Run ▸ Arguments ▸ Environment Variables 里补上。"
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
