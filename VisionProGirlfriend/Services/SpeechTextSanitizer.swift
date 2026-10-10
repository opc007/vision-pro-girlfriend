import Foundation

/// 把 LLM 的原始输出清洗成「适合念出来」的文本。
///
/// 唯一不能碰的东西：**标点**。
/// MiniMax 的 `t2a_v2_bidi` 是服务端按标点攒句的，官方文档也明确提醒过：
/// 转发前如果要清洗模型输出，别把原始标点删掉，否则服务端会退化成按长度机械切分，
/// 停顿落在语义不对的地方，听感会碎成一地。
///
/// 所以这里只清：Markdown 记号、代码块、链接、表格线、emoji 和零宽字符。
enum SpeechTextSanitizer {

    private struct Rule {
        let pattern: String
        let template: String
        let options: NSRegularExpression.Options
    }

    private static let rules: [Rule] = [
        // 代码块（含语言标注），整段删掉
        Rule(pattern: "```[\\s\\S]*?```", template: "", options: []),
        // 行内代码，**连内容一起删**——「let x = 1」这种念出来比停顿还尴尬
        Rule(pattern: "`[^`]*`", template: " ", options: []),
        // 残留的单个/多个反引号
        Rule(pattern: "`+", template: "", options: []),
        // 图片
        Rule(pattern: "!\\[[^\\]]*\\]\\([^)]*\\)", template: "", options: []),
        // 链接 → 只留文字
        Rule(pattern: "\\[([^\\]]*)\\]\\([^)]*\\)", template: "$1", options: []),
        // 标题井号
        Rule(pattern: "(?m)^[ \\t]*#{1,6}[ \\t]*", template: "", options: []),
        // 引用
        Rule(pattern: "(?m)^[ \\t]*>[ \\t]?", template: "", options: []),
        // 分割线
        Rule(pattern: "(?m)^[ \\t]*(?:\\-{3,}|\\*{3,}|_{3,})[ \\t]*$", template: "", options: []),
        // 表格分隔行
        Rule(pattern: "(?m)^[ \\t]*\\|?[ \\t]*:?-{3,}:?[ \\t]*(?:\\|[ \\t]*:?-{3,}:?[ \\t]*)+\\|?[ \\t]*$", template: "", options: []),
        // 列表符号：- * + / 1. 2)
        Rule(pattern: "(?m)^[ \\t]*(?:[-*+]|[0-9]+[.)])[ \\t]+", template: "", options: []),
        // 强调
        Rule(pattern: "\\*\\*", template: "", options: []),
        Rule(pattern: "__", template: "", options: []),
        Rule(pattern: "~~", template: "", options: []),
    ]

    private static let compiled: [NSRegularExpression] = rules.compactMap { rule in
        try? NSRegularExpression(pattern: rule.pattern, options: rule.options)
    }

    /// - Parameter raw: LLM 原始输出（可能是流式拼接的片段，单次调用会重复作用，已幂等）
    static func sanitize(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }

        var text = raw
        for (rule, regex) in zip(rules, compiled) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: rule.template)
        }

        text = stripEmojiAndInvisible(text)
        text = collapseWhitespace(text)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 只清要念的时候会被读出来的噪声。
    /// 注意避开 CJK 标点区（U+3000–U+303F）和全角区（U+FF00–U+FFEF），
    /// 那里面是「，。！？～」这些必须保留的东西。
    private static func stripEmojiAndInvisible(_ input: String) -> String {
        var output = String.UnicodeScalarView()
        output.reserveCapacity(input.unicodeScalars.count)

        for scalar in input.unicodeScalars {
            if isNoise(scalar) { continue }
            output.append(scalar)
        }
        return String(output)
    }

    private static func isNoise(_ scalar: UnicodeScalar) -> Bool {
        let value = scalar.value

        // 零宽、方向控制、不换行空格
        if value == 0x200B || value == 0x200C || value == 0x200D || value == 0x200E || value == 0x200F {
            return true
        }
        if value == 0x00A0 { return true }                 // NBSP → 后面统一压成普通空格
        if (0xFE00...0xFE0F).contains(value) { return true }  // emoji 变体选择符
        if (0x1F3FB...0x1F3FF).contains(value) { return true }  // 肤色修饰

        // emoji 与装饰符号
        if (0x2190...0x21FF).contains(value) { return true }  // 箭头
        if (0x2300...0x23FF).contains(value) { return true }  // 杂项技术符号（⌚⏰）
        if (0x2460...0x24FF).contains(value) { return true }  // 带圈数字 ①
        if (0x25A0...0x27BF).contains(value) { return true }  // 几何图形 + 装饰
        if (0x2B00...0x2BFF).contains(value) { return true }  // 杂项符号与箭头
        if (0x1F000...0x1FAFF).contains(value) { return true } // emoji 主区
        if (0x1F900...0x1F9FF).contains(value) { return true } // 补充 emoji
        if (0x3030...0x3030).contains(value) { return true }   // 〰 波浪号
        if (0x303D...0x303D).contains(value) { return true }   // 〽

        return false
    }

    private static func collapseWhitespace(_ input: String) -> String {
        // 先把「只有空格的行」整行去掉（删代码块之后常会留下这种空行）
        let withoutBlankLines = input
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: "\n")

        var output = String.UnicodeScalarView()
        output.reserveCapacity(withoutBlankLines.unicodeScalars.count)

        var newlines = 0
        var lastWasSpace = false

        for scalar in withoutBlankLines.unicodeScalars {
            if scalar == "\n" {
                newlines += 1
                lastWasSpace = false
                if newlines <= 2 { output.append(scalar) }
                continue
            }
            newlines = 0

            if scalar == " " || scalar == "\t" {
                if lastWasSpace { continue }
                lastWasSpace = true
                output.append(" ")
                continue
            }
            lastWasSpace = false
            output.append(scalar)
        }
        return String(output)
    }
}
