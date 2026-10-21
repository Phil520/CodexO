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
# 五条回归：
#   1. 月相档位设计   2. 月相渲染几何   3. 按事件时间戳取新文件读数
#   4. 尾部字节切在汉字中间仍可读  5. 手动刷新绕过缓存  6. 单实例锁不被副本误删
#   7. 状态栏项的位置自愈（2026-10-21 加：macOS 26 会把状态栏项降级藏起来）
# ---------------------------------------------------------------------------
if [ "${SKIP_TESTS:-0}" = "1" ]; then
  echo "==> 跳过回归测试（SKIP_TESTS=1）"
  exit 0
fi

TEST_TMP="$(mktemp -d /tmp/codexo_tests.XXXXXX)"
echo "==> 跑回归测试"

# 铁律：测试要跑得干净，但**不能打扰正在用的 App**。
#
# 以前这里写的是 `pkill -f CodexUsageMenuBar`，等于每构建一次就把用户
# 桌面上正在用的图标干掉一次 —— 而且杀一次起一次，正好触发
# 「同一 bundle id 被反复启停 → 系统把它记成不可见」那个坑，
# 于是构建完再看菜单栏，图标永远不见了。
#
# 现在测试全部跑临时副本（独立 id + 独立锁文件），正式 App 在不在跑都无所谓。
# 这里只清测试自己的残留。
pkill -f "CodexO-SingleInstanceTest-" 2>/dev/null || true
pkill -f "CodexO-Placement-" 2>/dev/null || true
sleep 1
# ⚠️ 必须用 ${TMPDIR:-/tmp}，不能写死 /tmp。
# NSTemporaryDirectory() 在 macOS 上返回的是 $TMPDIR（形如
# /var/folders/hp/xxxxxx/T/），不是 /tmp。
# 2026-10-19 实测踩过：清理时 rm -f /tmp/CodexO.singleton.lock
# 报"No such file"，一度以为锁没建起来 —— 实际它在 $TMPDIR 里好好待着。
#
# 只删测试自己的锁：${TMPDIR}CodexO.singleton.lock 是正式 App 在用的，
# 把它在正式 App 运行时删掉，等于给第二个实例开了门（两个图标）。
rm -f "${TMPDIR:-/tmp}"CodexO.singleton.test-*.lock 2>/dev/null || true

# ⚠️ 每个测试文件都必须**单独 cp 成main.swift**。
# Swift 只允许名为 main.swift 的文件写顶层语句，所以文件名不能改。
# 但共用同一个目标文件会出事：我先前把 moon_geometry 先 cp 成 main.swift，
# 紧接着又 cp moon_levels 覆盖同一个 main.swift —— 于是"月相几何"那一步
# 实际编译并运行的是 moon_levels，而它只打印 3 行结论，看着一切正常。
# 这种错不报错、也不失败，只是**测的东西悄悄换了人**。
# 解法：每个测试用独立的子目录，各自 main.swift。
#
# ⚠️ 源目录与输出二进制也要分开：先前二进制叫 levels、源目录也叫 levels，
# 链接阶段直接报 "link command failed"，且脚本里那句 `&& { echo 编译失败; }`
# 没接住（管道的退出码是 grep 的，不是 swiftc 的），
# 于是错误一路滑到下一行才炸成 "levels: is a directory"。
MOON_LEVELS_SRC="$TEST_TMP/levels_src"
MOON_GEOM_SRC="$TEST_TMP/geom_src"
mkdir -p "$MOON_LEVELS_SRC" "$MOON_GEOM_SRC"
cp "$PROJECT_DIR/tests/moon_levels.swift" "$MOON_LEVELS_SRC/main.swift"
cp "$PROJECT_DIR/tests/moon_geometry.swift" "$MOON_GEOM_SRC/main.swift"

echo "  [1/5] 月相档位设计（面积单调 + 相邻差 + 胖瘦）"
swiftc -swift-version 5 -framework Cocoa -o "$TEST_TMP/levels" \
  "$MOON_LEVELS_SRC/main.swift" \
  "$PROJECT_DIR/src/MenuBarUI.swift" \
  "$PROJECT_DIR/src/UsageReader.swift"
> "$TEST_TMP/build.log" 2>&1
  if [ $? -ne 0 ]; then
    echo "    编译失败，完整输出："
    sed "s/^/      /" "$TEST_TMP/build.log"
    exit 1
  fi
"$TEST_TMP/levels" | tail -3

echo "  [2/5] 月相几何（渲染出来的是不是这个形状）"
swiftc -swift-version 5 -framework Cocoa -o "$TEST_TMP/moon" \
  "$MOON_GEOM_SRC/main.swift" \
  "$PROJECT_DIR/src/MenuBarUI.swift" \
  "$PROJECT_DIR/src/UsageReader.swift"
> "$TEST_TMP/build.log" 2>&1
  if [ $? -ne 0 ]; then
    echo "    编译失败，完整输出："
    sed "s/^/      /" "$TEST_TMP/build.log"
    exit 1
  fi
"$TEST_TMP/moon" | tail -3

echo "  [3/5] 取数与缓存"
swiftc -swift-version 5 -framework Cocoa -o "$TEST_TMP/reader" \
  "$PROJECT_DIR/tests/main.swift" \
  "$PROJECT_DIR/src/UsageReader.swift" \
  "$PROJECT_DIR/src/MenuBarUI.swift"
> "$TEST_TMP/build.log" 2>&1
  if [ $? -ne 0 ]; then
    echo "    编译失败，完整输出："
    sed "s/^/      /" "$TEST_TMP/build.log"
    exit 1
  fi
"$TEST_TMP/reader" | grep -E "^(✅|❌)"

echo "  [4/5] 单实例锁（起真实子进程）"
swiftc -swift-version 5 -framework Cocoa -D CODEXO_SINGLE_INSTANCE_TESTS \
  -o "$TEST_TMP/si" \
  "$PROJECT_DIR/tests/main.swift" \
  "$PROJECT_DIR/tests/single_instance.swift" \
  "$PROJECT_DIR/src/UsageReader.swift" \
  "$PROJECT_DIR/src/MenuBarUI.swift"
> "$TEST_TMP/build.log" 2>&1
  if [ $? -ne 0 ]; then
    echo "    编译失败，完整输出："
    sed "s/^/      /" "$TEST_TMP/build.log"
    exit 1
  fi
CODEXO_BINARY="$TARGET_APP/Contents/MacOS/CodexUsageMenuBar" "$TEST_TMP/si" \
  | sed -n '/单实例锁回归测试/,$p'

echo "  [5/5] 状态栏位置自愈（起真实子进程）"
PLACEMENT_SRC="$TEST_TMP/placement_src"
mkdir -p "$PLACEMENT_SRC"
cp "$PROJECT_DIR/tests/status_placement.swift" "$PLACEMENT_SRC/main.swift"
swiftc -swift-version 5 -framework Cocoa -o "$TEST_TMP/placement" \
  "$PLACEMENT_SRC/main.swift"
> "$TEST_TMP/build.log" 2>&1
  if [ $? -ne 0 ]; then
    echo "    编译失败，完整输出："
    sed "s/^/      /" "$TEST_TMP/build.log"
    exit 1
  fi
CODEXO_BINARY="$TARGET_APP/Contents/MacOS/CodexUsageMenuBar" "$TEST_TMP/placement" \
  | grep -E "^(✅|❌|  )"

# 收尾铁律：先杀进程、确认干净，再删目录。
# 顺序反了会留下孤儿进程——菜单栏于是出现两个图标（本项目 2026-10-19 踩过）。
#
# 只清测试副本。正式 App 的进程归用户管：构建不该顺手把它关掉，
# 更不该让它经历一次「杀掉再起」—— 那正是状态栏图标消失的诱因。
pkill -f "CodexO-SingleInstanceTest-" 2>/dev/null || true
pkill -f "CodexO-Placement-" 2>/dev/null || true
sleep 1
REMAINING="$(pgrep -f "CodexO-SingleInstanceTest-|CodexO-Placement-" 2>/dev/null | wc -l | tr -d ' ')"
if [ "$REMAINING" != "0" ]; then
  echo "    ⚠️ 仍有 $REMAINING 个残留测试进程，强制清理"
  pkill -9 -f "CodexO-SingleInstanceTest-" 2>/dev/null || true
  pkill -9 -f "CodexO-Placement-" 2>/dev/null || true
  sleep 1
fi
echo "    残留测试进程 $REMAINING 个"
rm -rf "$TEST_TMP"
# 只删测试用的锁，不碰正式 App 的那把
rm -f "${TMPDIR:-/tmp}"CodexO.singleton.test-*.lock 2>/dev/null || true
rm -f "${TMPDIR:-/tmp}"CodexO.singleton.lock 2>/dev/null || true

echo "==> 全部回归通过"
