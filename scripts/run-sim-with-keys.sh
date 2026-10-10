#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENVF="$ROOT/.vp-keys.env"
UDID="${1:-11739D88-55A8-4FAE-8009-53022A8DA215}"
set -a
source "$ENVF"
set +a
APP="$HOME/Library/Developer/Xcode/DerivedData/VisionProGirlfriend-cfhjyxkdgpsnizbckhwzoepaohgb/Build/Products/Debug-xrsimulator/VisionProGirlfriend.app"
xcodebuild -project "$ROOT/VisionProGirlfriend.xcodeproj" -scheme VisionProGirlfriend \
  -destination "platform=visionOS Simulator,id=$UDID" -configuration Debug build >/tmp/vp-run-build.log
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl install "$UDID" "$APP"
xcrun simctl terminate "$UDID" com.opc007.visionprogirlfriend 2>/dev/null || true
SIMCTL_CHILD_DEEPSEEK_API_KEY="$DEEPSEEK_API_KEY" SIMCTL_CHILD_MINIMAX_API_KEY="$MINIMAX_API_KEY" \
  xcrun simctl launch --terminate-running-process "$UDID" com.opc007.visionprogirlfriend
echo launched
