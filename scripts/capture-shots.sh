#!/bin/sh
# 渲染 README 展示图。全部使用 Mock 数据，不含任何真实订阅信息。
#
# 用法：
#   ./scripts/capture-shots.sh              # 输出到 docs/shots/
#   ./scripts/capture-shots.sh /tmp/shots   # 指定输出目录
#
# 前置：先构建 debug 版（release 版没有调试开关）
#   ./scripts/build-clt.sh --debug
#
# 注意：运行前请退出正在运行的 ProxyMonitor。两个实例会同时占用状态栏，
# 抓图可能抓到空菜单或重复图标。
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
  say "否则状态栏会有两个实例，抓图可能不正确。"
  exit 1
fi

mkdir -p "$OUT"

# capture <输出文件名> [额外环境变量...]
capture() {
  name=$1
  shift
  rm -f "$OUT/ptm_menu.png"

  env PTM_USE_MOCK=1 \
      PTM_CALIBRATE_MENU=1 \
      PTM_CALIBRATE_SNAPSHOT=1 \
      PTM_CALIBRATE_OUT="$OUT" \
      PTM_CALIBRATE_DELAY=1.5 \
      PTM_CALIBRATE_SETTLE=1.0 \
      "$@" \
      "$BIN"

  if [ -f "$OUT/ptm_menu.png" ]; then
    mv "$OUT/ptm_menu.png" "$OUT/$name"
    say "  ✓ $OUT/$name"
  else
    say "  ✗ $OUT/$name 未生成（菜单窗口未捕获到）"
    return 1
  fi
}

say "渲染菜单面板…"
capture menu.png

say "渲染悬停态…"
capture menu-hover.png PTM_CALIBRATE_HOVER=1

say ""
say "完成。还需手动截一张设置窗口："
say "  1. 菜单栏图标 → 设置…（⌘,）"
say "  2. ⌘⇧4 后按空格，点设置窗口"
say "  3. 存为 $OUT/settings.png"
say ""
say "截图前请确认窗口里的订阅名是 HK BGP-A / JP SoftEther / SG Trojan，"
say "不要出现真实服务商名称。"
