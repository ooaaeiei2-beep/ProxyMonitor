#!/bin/sh
# 渲染 README 展示图。全部使用 Mock 数据，不含任何真实订阅信息。
#
# 用法：
#   ./scripts/capture-shots.sh              # 输出到 docs/shots/
#   ./scripts/capture-shots.sh /tmp/shots   # 指定输出目录
#
# 前置：必须先构建 debug 版。release 版没有 -DDEBUG，下面的调试开关是空操作，
# 跑起来会毫无输出地退出。
#   ./scripts/build-clt.sh --debug
#
# 必须在有图形会话的终端里运行（Terminal.app / iTerm）。通过 ssh 或后台任务
# 运行时应用不是激活状态，菜单不会真的展开，标定工具会记下 menuOpen=false。
set -eu

OUT=${1:-docs/shots}
APP=${APP:-build/clt/ProxyMonitor.app}
BIN="$APP/Contents/MacOS/ProxyMonitor"

say() { printf '%s\n' "$*" >&2; }

[ -x "$BIN" ] || {
  say "未找到 $BIN"
  say "先构建 debug 版：./scripts/build-clt.sh --debug"
  exit 1
}

if pgrep -x ProxyMonitor >/dev/null 2>&1; then
  say "ProxyMonitor 正在运行。请先从菜单栏退出它再跑这个脚本，"
  say "否则状态栏会出现两个实例，抓图可能不正确。"
  exit 1
fi

mkdir -p "$OUT"
OUT_ABS=$(cd "$OUT" && pwd)

# capture <输出文件名> [额外 PTM_* 变量...]
capture() {
  name=$1
  shift

  rm -f "$OUT_ABS/ptm_menu.png" "$OUT_ABS/ptm_frames.txt"

  env PTM_USE_MOCK=1 \
      PTM_CALIBRATE_MENU=1 \
      PTM_CALIBRATE_SNAPSHOT=1 \
      PTM_CALIBRATE_OUT="$OUT_ABS" \
      PTM_CALIBRATE_DELAY=1.5 \
      PTM_CALIBRATE_SETTLE=1.0 \
      "$@" \
      "$BIN" || true

  if [ -f "$OUT_ABS/ptm_menu.png" ]; then
    mv "$OUT_ABS/ptm_menu.png" "$OUT_ABS/$name"
    say "  ✓ $OUT/$name"
    return 0
  fi

  say "  ✗ $OUT/$name 未生成"
  if [ -f "$OUT_ABS/ptm_frames.txt" ]; then
    say "    标定输出："
    sed 's/^/      /' "$OUT_ABS/ptm_frames.txt" >&2
    say "    若为 menuOpen=false，说明应用没能激活菜单，请确认在有图形界面的终端里运行。"
  fi
  return 1
}

say "渲染菜单面板…"
capture menu.png

say "渲染悬停态…"
capture menu-hover.png PTM_CALIBRATE_HOVER=1

say ""
say "完成。还需手动截一张设置窗口（没有对应的快照开关）："
say "  1. 菜单栏图标 → 设置…（⌘,）"
say "  2. ⌘⇧4 后按空格，点设置窗口"
say "  3. 存为 $OUT/settings.png"
say ""
say "截图前请确认窗口里的订阅名是 HK BGP-A / JP SoftEther / SG Trojan，"
say "不要出现真实服务商名称。"
