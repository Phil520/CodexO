#!/bin/bash
# 编译并打包 CodexO（Codex 用量菜单栏 App）
# 用法：bash build.sh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="CodexO"
# 可执行文件名保持不变：CFBundleExecutable 指的是它，
# 改它要同步改 Info.plist，而它并不影响用户看到的名字。
BIN_NAME="CodexUsageMenuBar"
TARGET_APP="$PROJECT_DIR/output/$APP_NAME.app"

echo "==> 清理旧产物"
rm -rf "$TARGET_APP"
mkdir -p "$TARGET_APP/Contents/MacOS" "$TARGET_APP/Contents/Resources"

echo "==> 编译 Swift 源码"
swiftc -swift-version 5 -O -framework Cocoa \
  -o "$TARGET_APP/Contents/MacOS/$BIN_NAME" \
  "$PROJECT_DIR/src/main.swift" \
  "$PROJECT_DIR/src/UsageReader.swift" \
  "$PROJECT_DIR/src/MenuBarUI.swift" \
  "$PROJECT_DIR/src/Diagnostics.swift" \
  "$PROJECT_DIR/src/Soak.swift"

echo "==> 写入 Info.plist"
cp "$PROJECT_DIR/src/Info.plist" "$TARGET_APP/Contents/Info.plist"

echo "==> 生成 App 图标"
# 图标用现成的生成器现画，不提交二进制 .icns：
# 二进制没法 diff、改不动、review 时也看不出改了什么。
ICON_TMP="$(mktemp -d)"
if swiftc -swift-version 5 -O -framework Cocoa \
     -o "$ICON_TMP/make_icon" \
     "$PROJECT_DIR/tools/make_icon.swift" \
     "$PROJECT_DIR/src/MenuBarUI.swift" \
     "$PROJECT_DIR/src/UsageReader.swift" \
     "$PROJECT_DIR/src/Diagnostics.swift" \
     "$PROJECT_DIR/src/Soak.swift" \
  && "$ICON_TMP/make_icon" "$ICON_TMP/CodexO.iconset" >/dev/null \
  && iconutil -c icns "$ICON_TMP/CodexO.iconset" \
       -o "$TARGET_APP/Contents/Resources/$APP_NAME.icns"; then
  echo "    已生成 $APP_NAME.icns"
else
  # 图标失败不该让整个打包失败 —— App 照样能跑，只是 Finder 里是默认图标。
  # 但必须把原因打出来：上一次这里写了 2>/dev/null，失败时只剩一行
  # "图标生成失败"，完全看不出是编译没通过还是 iconutil 报错，白查一轮。
  echo "    ⚠️ 图标生成失败，App 仍可运行（Finder 里显示默认图标）"
  echo "       上面的 swiftc / iconutil 报错即为原因"
fi
rm -rf "$ICON_TMP"

echo "==> ad-hoc 签名"
codesign --force --sign - "$TARGET_APP" >/dev/null 2>&1 || echo "    签名跳过（不影响本地运行）"

echo "==> 校验签名与 Info"
codesign -dv "$TARGET_APP" 2>&1 | head -3
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$TARGET_APP/Contents/Info.plist" | sed 's/^/    版本 /'

echo "==> 完成：$TARGET_APP"
du -sh "$TARGET_APP"

# ---------------------------------------------------------------------------
# 回归测试（默认跑，可用 SKIP_TESTS=1 跳过）
#
# 为什么把测试挂进 build.sh 而不是留成手动步骤：
# 上一轮「手动刷新被缓存吞掉」和本轮「副本误删锁」两个 bug，
# 共同点是**肉眼与单进程启动都看不出来**，只有专门判据能测出来。
# 测试不挂在构建路径上，就等于没有下一次修复的保障。
#
# 四条回归：
#   1. 按事件时间戳取新文件读数  2. 尾部字节切在汉字中间仍可读
#   3. 手动刷新绕过缓存          4. 单实例锁不被副本误删（起真实子进程）
# ---------------------------------------------------------------------------
if [ "${SKIP_TESTS:-0}" = "1" ]; then
  echo "==> 跳过回归测试（SKIP_TESTS=1）"
  exit 0
fi

TEST_TMP="$(mktemp -d /tmp/codexo_tests.XXXXXX)"
echo "==> 跑回归测试"

# 铁律：测试里凡是起 App 进程的，跑之前先把残留清干净。
# 不清的话，测试会以"已有实例在跑"为由直接作废，
# 而作废是静默的——你会以为测试通过了。
pkill -f CodexUsageMenuBar 2>/dev/null && echo "    已清理残留进程" || true
sleep 1
rm -f "$TMPDIR/CodexO.singleton.lock" 2>/dev/null || true

# 单实例测试文件名必须是 main.swift：Swift 只允许名为 main.swift 的文件写顶层语句。
cp "$PROJECT_DIR/tests/moon_geometry.swift" "$TEST_TMP/main.swift"

echo "  [1/3] 月相几何（七档面积）"
swiftc -swift-version 5 -framework Cocoa -o "$TEST_TMP/moon" \
  "$TEST_TMP/main.swift" \
  "$PROJECT_DIR/src/MenuBarUI.swift" \
  "$PROJECT_DIR/src/UsageReader.swift" 2>&1 | grep -E "error" && { echo "    编译失败"; exit 1; }
"$TEST_TMP/moon" | tail -3

echo "  [2/3] 取数与缓存"
swiftc -swift-version 5 -framework Cocoa -o "$TEST_TMP/reader" \
  "$PROJECT_DIR/tests/main.swift" \
  "$PROJECT_DIR/src/UsageReader.swift" \
  "$PROJECT_DIR/src/MenuBarUI.swift" 2>&1 | grep -E "error" && { echo "    编译失败"; exit 1; }
"$TEST_TMP/reader" | grep -E "^(✅|❌)"

echo "  [3/3] 单实例锁（起真实子进程）"
swiftc -swift-version 5 -framework Cocoa -D CODEXO_SINGLE_INSTANCE_TESTS \
  -o "$TEST_TMP/si" \
  "$PROJECT_DIR/tests/main.swift" \
  "$PROJECT_DIR/tests/single_instance.swift" \
  "$PROJECT_DIR/src/UsageReader.swift" \
  "$PROJECT_DIR/src/MenuBarUI.swift" 2>&1 | grep -E "error" && { echo "    编译失败"; exit 1; }
CODEXO_BINARY="$TARGET_APP/Contents/MacOS/CodexUsageMenuBar" "$TEST_TMP/si" \
  | sed -n '/单实例锁回归测试/,$p'

# 收尾铁律：先杀进程、确认干净，再删目录。
# 顺序反了会留下孤儿进程——菜单栏于是出现两个图标（本项目 2026-10-19 踩过）。
pkill -f CodexUsageMenuBar 2>/dev/null || true
sleep 1
REMAINING="$(pgrep -f CodexUsageMenuBar | wc -l | tr -d ' ')"
if [ "$REMAINING" != "0" ]; then
  echo "    ⚠️ 仍有 $REMAINING 个残留进程，强制清理"
  pkill -9 -f CodexUsageMenuBar 2>/dev/null || true
  sleep 1
fi
echo "    残留进程 $REMAINING 个"
rm -rf "$TEST_TMP"
rm -f "$TMPDIR/CodexO.singleton.lock" 2>/dev/null || true

echo "==> 全部回归通过"
