#!/bin/bash
# 在有 Xcode 的 Mac 上跑一次，把「Linux 编不了的那部分」验掉。
#
#   cd <仓库目录> && bash scripts/verify-on-mac.sh
#
# 做三件事：
#   1. 用真的 visionOS SDK 对全部源文件做类型检查（会编到 #if os(visionOS) 分支，
#      Linux 那边永远编不到这些分支）
#   2. 真的 xcodebuild 一遍（类型检查抓不到确定初始化、逃逸捕获那类 SIL 错误，
#      只有真编译能抓）
#   3. 跑仓库里三个纯 Swift 单测，确认在 Mac 的工具链上也全绿
#
# 全部输出最后会汇总成一段，直接整段贴回 Issue #1 就行。

set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

FAILED=0
hr() { printf '\n========================================\n%s\n========================================\n' "$1"; }

# ---------------------------------------------------------------- 0. 环境
hr "0 · 环境"
if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "❌ 没找到 xcodebuild。装 Xcode 并在 Settings ▸ Platforms 里勾上 visionOS SDK。"
    exit 1
fi
xcodebuild -version | head -2

SDK="$(xcrun --sdk xros --show-sdk-path 2>/dev/null)"
if [ -z "$SDK" ]; then
    echo "❌ 找不到 visionOS(xros) SDK。Xcode ▸ Settings ▸ Platforms 装一下。"
    exit 1
fi
echo "SDK: $SDK"

# ------------------------------------------------- 1. 真 SDK 全量类型检查
hr "1 · 真 SDK 类型检查（所有源文件，含 visionOS 分支）"

# macOS 自带的是 bash 3.2，没有 mapfile，所以老老实实用 while 读
SOURCES=()
while IFS= read -r line; do
    SOURCES+=("$line")
done < <(find VisionProGirlfriend -name '*.swift' | sort)
echo "共 ${#SOURCES[@]} 个源文件"

TYPECHECK_LOG=/tmp/vpg-typecheck.log
swiftc -typecheck -sdk "$SDK" -target arm64-apple-xros1.0 "${SOURCES[@]}" \
    > "$TYPECHECK_LOG" 2>&1
TC=$?
if [ $TC -eq 0 ] && ! grep -q "error:" "$TYPECHECK_LOG"; then
    echo "✅ 类型检查 0 error"
    grep "warning:" "$TYPECHECK_LOG" | sort | uniq -c | sort -rn | head -10
else
    FAILED=1
    echo "❌ 类型检查有问题："
    grep -E "error:" "$TYPECHECK_LOG" | head -30
fi

# ------------------------------------------------------------ 2. 真编译
hr "2 · xcodebuild（只有真编译能抓确定初始化 / 逃逸捕获这类错误）"

DEST="generic/platform=visionOS Simulator"
xcodebuild -project VisionProGirlfriend.xcodeproj \
           -scheme VisionProGirlfriend \
           -configuration Debug \
           -destination "$DEST" \
           CODE_SIGNING_ALLOWED=NO \
           build > /tmp/vpg-build.log 2>&1
BUILD=$?

if [ $BUILD -eq 0 ]; then
    echo "✅ xcodebuild 成功（$DEST）"
    echo
    echo "👉 现在可以接着跑模拟器：Xcode ▸ Product ▸ Run（⌘R）"
else
    # 平台名在不同 Xcode 版本里可能不一样，退回枚举 destination 再试一次
    if grep -q "Unable to find a destination" /tmp/vpg-build.log; then
        echo "destination '$DEST' 不被这个 Xcode 接受，列出可用 destination："
        xcodebuild -project VisionProGirlfriend.xcodeproj -scheme VisionProGirlfriend \
                   -showdestinations 2>/dev/null | sed -n 's/^ *\(.*visionOS.*\)$/  \1/p' | head -10
        echo "把上面某一行填进 DEST= 后重跑："
        echo "   DEST='generic/platform=...' bash scripts/verify-on-mac.sh"
    fi
    FAILED=1
    echo "❌ 编译失败，错误如下："
    grep -E "error:" /tmp/vpg-build.log | sort -u | head -30
fi

# ------------------------------------------------------------ 3. 单测
hr "3 · 纯 Swift 单测（Mac 工具链）"
run_test() {
    local name="$1"; shift
    local out="/tmp/vpg-test-$name"
    if swiftc -module-name "$name" "$@" -o "$out" 2>/tmp/vpg-test-$name.log; then
        if "$out" > /tmp/vpg-test-$name.out 2>&1; then
            echo "✅ $name：$(tail -1 /tmp/vpg-test-$name.out)"
        else
            FAILED=1
            echo "❌ $name 有断言失败："
            grep "❌" /tmp/vpg-test-$name.out | head -20
        fi
    else
        FAILED=1
        echo "❌ $name 编不过："
        grep "error:" /tmp/vpg-test-$name.log | head -10
    fi
}

run_test sanitize VisionProGirlfriend/Services/SpeechTextSanitizer.swift scripts/test_speech_sanitizer.swift
run_test pose     VisionProGirlfriend/Avatar/AvatarState.swift            scripts/test_avatar_pose.swift
run_test overnight \
    VisionProGirlfriend/Avatar/AvatarModelPlan.swift \
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
    scripts/test_overnight.swift

# ------------------------------------------------------------ 汇总
hr "汇总"
if [ $FAILED -eq 0 ]; then
    echo "全部通过 ✅ —— Linux 这边能验的都验了，剩下只有肉眼观感（表情好不好看、按住说话顺不顺手）。"
else
    echo "有问题 ❌ —— 把上面带 ❌ 的部分连同这段汇总一起贴回 Issue #1。"
fi
echo
echo "完整日志：/tmp/vpg-typecheck.log  /tmp/vpg-build.log"
exit $FAILED
