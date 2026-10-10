// 语音文本清洗的断言测试。
//
// 不需要 XCTest target，有 swiftc 就能跑：
//   swiftc VisionProGirlfriend/Services/SpeechTextSanitizer.swift \
//          scripts/test_speech_sanitizer.swift -o /tmp/tts-test && /tmp/tts-test
//
// 全绿返回 0，有挂返回 1，可以直接进 CI。

import Foundation

@main
struct SpeechSanitizerTest {

    static var failures = 0
    static var checks = 0

    static func expectEqual(_ actual: String, _ expected: String, _ label: String) {
        checks += 1
        if actual == expected {
            print("  ✅ \(label)")
        } else {
            failures += 1
            print("  ❌ \(label)")
            print("     期望: \(expected.debugDescription)")
            print("     实际: \(actual.debugDescription)")
        }
    }

    static func expectTrue(_ condition: Bool, _ label: String) {
        checks += 1
        if condition {
            print("  ✅ \(label)")
        } else {
            failures += 1
            print("  ❌ \(label)")
        }
    }

    static func main() {
        print("SpeechTextSanitizer 测试")
        print("")

        // 1. 普通中文必须原样保留 —— 标点一动都不能动
        expectEqual(
            SpeechTextSanitizer.sanitize("你好呀，今天想聊点什么？"),
            "你好呀，今天想聊点什么？",
            "纯中文标点原样保留"
        )

        // 2. Markdown 强调标记去掉，文字留下
        expectEqual(
            SpeechTextSanitizer.sanitize("**你好**，我是七宝～"),
            "你好，我是七宝～",
            "去掉 ** 粗体标记"
        )

        // 3. 行内代码：连内容一起删，念出来比停顿还尴尬
        expectEqual(
            SpeechTextSanitizer.sanitize("这个 `let x = 1` 很好用。"),
            "这个 很好用。",
            "行内代码连内容一起删"
        )

        // 4. 代码块整段删掉
        expectEqual(
            SpeechTextSanitizer.sanitize("看这段：\n```swift\nprint(1)\n```\n看懂了吗？"),
            "看这段：\n看懂了吗？",
            "代码块整段删除"
        )

        // 5. 链接只留文字
        expectEqual(
            SpeechTextSanitizer.sanitize("参考 [这个文档](https://example.com) 就好。"),
            "参考 这个文档 就好。",
            "链接只保留文字"
        )

        // 6. emoji 去掉，中文标点留着
        expectEqual(
            SpeechTextSanitizer.sanitize("早上好呀！😊☀️ 今天也开心～"),
            "早上好呀！ 今天也开心～",
            "emoji 删除、中文标点保留"
        )

        // 7. 列表符号去掉
        expectEqual(
            SpeechTextSanitizer.sanitize("- 第一件\n- 第二件"),
            "第一件\n第二件",
            "列表符号删除"
        )

        // 8. 标题井号
        expectEqual(
            SpeechTextSanitizer.sanitize("## 今日安排\n- 吃饭"),
            "今日安排\n吃饭",
            "标题井号删除"
        )

        // 9. 省略号和破折号是 MiniMax 的停顿语义，必须留着
        let withPause = SpeechTextSanitizer.sanitize("好的…让我想想——晚点告诉你。")
        expectTrue(withPause.contains("…"), "保留 … （停顿语义）")
        expectTrue(withPause.contains("—"), "保留 — （停顿语义）")

        // 10. 连续空行压掉
        expectTrue(
            !SpeechTextSanitizer.sanitize("你好\n\n\n\n\n再见").contains("\n\n\n"),
            "连续空行被压掉"
        )

        // 11. 英文标点也不能丢
        expectTrue(
            SpeechTextSanitizer.sanitize("Hello, are you ok? I'm fine!").contains("?"),
            "保留英文问号"
        )

        // 12. 空输入
        expectEqual(SpeechTextSanitizer.sanitize(""), "", "空串安全")

        // 13. 流式片段会反复调用，必须幂等
        let raw = "**七宝**说：今天 😊 心情不错～"
        expectEqual(
            SpeechTextSanitizer.sanitize(SpeechTextSanitizer.sanitize(raw)),
            SpeechTextSanitizer.sanitize(raw),
            "清洗是幂等的"
        )

        // 14. 表格线删掉，单元格文字留下
        expectTrue(
            !SpeechTextSanitizer.sanitize("| 名字 | 年龄 |\n| --- | --- |\n| 七宝 | 22 |").contains("---"),
            "表格分隔线删除"
        )

        print("")
        if failures == 0 {
            print("全部通过：\(checks) 项 ✅")
            exit(0)
        } else {
            print("\(checks) 项里挂了 \(failures) 项 ❌")
            exit(1)
        }
    }
}
