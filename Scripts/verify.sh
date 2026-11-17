#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
Scripts/build-apple-ffmpeg.sh
Scripts/build-apple-libass.sh

# The three app builds run side by side, and beside the tests: each has its own DerivedData, and they and the
# tests only read what they share under build/ (FFmpeg, LibASS, the runtimes). One after another they took about
# three times as long.
builds=()
stop_builds() {
  for build in "${builds[@]+"${builds[@]}"}"; do kill "${build%%|*}" 2>/dev/null || true; done
}
trap stop_builds EXIT
for entry in 'macOS|platform=macOS|mac' 'iOS|generic/platform=iOS|ios' 'tvOS|generic/platform=tvOS|tv'; do
  IFS='|' read -r platform destination folder <<< "$entry"
  xcodebuild -project TVBox.xcodeproj -scheme "TVBox-$platform" \
    -destination "$destination" -derivedDataPath "build/Verify-$folder" \
    CODE_SIGNING_ALLOWED=NO build > "build/verify-$folder.log" 2>&1 &
  builds+=("$!|$platform|$folder")
done

# ⛔ 必须 `--no-parallel`。
#
# 这套测试里有一批**进程级单例**：`EgressRouter` 的按 host 结论表、`CustomProxyStore`、
# `MediaCache`、`SRCPortPool`、`LocalProxyServer` 的监听端口、搜索缓存。
# 它们在产品里本来就只有一个实例，测试并行跑时互相看得见 —— 实测症状是
# 「同一份代码这次绿、下次红」，红的还总是搜索/采集那几条（它们共用
# `https://example.com/...` 与同一句搜索词），而单独跑这几条永远绿。
#
# 串行 1636 例约 47 秒，并行 ~10 秒。多花这半分钟，换来的是一个**可复现**的闸门：
# 红了就一定是代码问题，不是排班问题。
swift test --no-parallel
Scripts/test-apple-runtime-bridge.sh
# The apps embed build/JavaHost: it must be the sources' version, and its own tests must pass.
Scripts/check-java-host.sh build/JavaHost/host.jar
Scripts/test-java-host.sh > build/verify-java.log 2>&1 || { tail -40 build/verify-java.log; exit 1; }
echo "Java host tests passed (build/verify-java.log)"

failed=0
for build in "${builds[@]}"; do
  IFS='|' read -r pid platform folder <<< "$build"
  if wait "$pid"; then
    echo "$platform build passed (build/verify-$folder.log)"
  else
    echo "$platform build failed (build/verify-$folder.log):"
    grep -E ': error:|\*\* BUILD FAILED' "build/verify-$folder.log" | head -20 || tail -40 "build/verify-$folder.log"
    failed=1
  fi
done
builds=()
exit "$failed"
