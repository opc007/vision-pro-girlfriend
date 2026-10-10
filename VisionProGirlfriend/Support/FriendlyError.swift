import Foundation

/// 把底层的报错翻译成人话。
///
/// 原则：**先说能做什么，再说出了什么事**。别把 `URLError -1009` 甩给用户看。
/// 纯字符串判断都放在静态函数里，可以单测。
enum FriendlyError {

    enum Context {
        /// 聊天（DeepSeek）
        case chat
        /// 语音合成（MiniMax）
        case tts
        /// 语音识别
        case speech

        var noun: String {
            switch self {
            case .chat: return "聊天"
            case .tts: return "七宝的声音"
            case .speech: return "语音输入"
            }
        }
    }

    static func message(for error: Error, context: Context) -> String {
        switch error {
        // MARK: 缺 Key
        case DeepSeekError.missingAPIKey:
            return "还没配 DEEPSEEK_API_KEY，\(context.noun)用不了。到 Scheme ▸ Environment Variables 里加上再跑。"
        case MiniMaxTTSError.missingAPIKey:
            return "还没配 MINIMAX_API_KEY，\(context.noun)用不了。到 Scheme ▸ Environment Variables 里加上再跑。"
        case MiniMaxTTSError.badURL, DeepSeekError.badURL:
            return "接口地址拼错了，检查一下 BASE_URL 环境变量。"

        // MARK: 鉴权 / 限流
        case let DeepSeekError.http(status, _):
            return httpHint(status: status, service: "DeepSeek", context: context)
        case let MiniMaxTTSError.server(code, _):
            return serverHint(code: code, context: context)

        // MARK: 网络
        case let error as URLError:
            return networkHint(error, context: context)

        // MARK: 流断了
        case DeepSeekError.streamEndedUnexpectedly:
            return "回复断在半路了，多半是网络抖了，再说一次试试。"
        case let MiniMaxTTSError.timedOut(what):
            return "等 \(what) 超时了，\(context.noun)暂时没响应，过几秒会自己重连。"

        default:
            return defaultHint(for: error, context: context)
        }
    }

    /// TTS 状态机只回传了一个字符串过来，只能按内容认。
    /// MiniMax 的状态码在官方文档里有固定含义，这里挑用户看得懂的翻译。
    static func ttsHint(forStateMessage message: String) -> String {
        if message.contains("2201") {
            return "语音连接空闲太久被服务端断开了，下一句会自动重连。"
        }
        if message.contains("1001") || message.contains("1002")
            || message.contains("1004") || message.contains("1008") {
            return "语音连接被服务端拒绝，多半是 MINIMAX_API_KEY 不对或已过期。"
        }
        if message.contains("2202") || message.contains("2203") || message.contains("1009") {
            return "语音服务在限流，等一会儿再说。"
        }
        if message.contains("连接") || message.contains("connect") || message.contains("Connection") {
            return "语音连接断了，说句话就会自动接上。"
        }
        return "语音出问题了：\(message)"
    }

    // MARK: - 私有

    private static func httpHint(status: Int, service: String, context: Context) -> String {
        switch status {
        case 401, 403:
            return "\(service) 拒绝了请求，多半是 API Key 不对、没余额，或没开这个模型。"
        case 429:
            return "请求太频繁，等十几秒再试。"
        case 500...599:
            return "\(service) 服务端开小差了，稍后再试；打字聊也一样会这样。"
        default:
            return "\(service) 返回了 \(status)，\(context.noun)暂时用不了。"
        }
    }

    private static func serverHint(code: Int, context: Context) -> String {
        switch code {
        case 1001, 1002, 1004, 1008:
            return "语音连接被服务端拒绝，多半是 MINIMAX_API_KEY 不对或已过期。"
        case 2201:
            return "语音连接空闲太久被断开了，下一句会自动重连。"
        case 2202, 2203:
            return "语音服务在限流，等一会儿再说。"
        default:
            return "\(context.noun)出错了（\(code)），再说一次试试。"
        }
    }

    private static func networkHint(_ error: URLError, context: Context) -> String {
        switch error.code {
        case .notConnectedToInternet:
            return "设备没连上网络。\(context.noun)需要联网，先把 Wi-Fi 接上。"
        case .networkConnectionLost:
            return "网络中途断了，\(context.noun)会自动重连，再说一次就行。"
        case .timedOut:
            return "网络太慢，超时了。稍等一下再试。"
        case .cannotFindHost, .cannotConnectToHost:
            return "连不上服务器。检查一下网络，或者 BASE_URL 有没有配错。"
        case .dnsLookupFailed:
            return "域名解析失败，检查一下网络或 BASE_URL。"
        default:
            return "\(context.noun)连不上网络（\(error.localizedDescription)）。"
        }
    }

    private static func defaultHint(for error: Error, context: Context) -> String {
        let raw = error.localizedDescription
        // 有些系统错误自带的中文提示已经写得不错了，别再包一层
        guard !raw.isEmpty else { return "\(context.noun)出错了，再试一次。" }
        return raw
    }
}
