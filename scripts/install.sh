#!/usr/bin/env bash
#
# ProxyMonitor 安装脚本
#
# 用途：在应用未做 Apple 公证（ad-hoc 签名）的前提下完成安装，使首次启动不被
#       Gatekeeper 拦截。原理是 curl 下载的文件不带 com.apple.quarantine 扩展属性，
#       而 Gatekeeper 只在文件带该属性时于首次启动介入。
#
# 这不做任何签名或身份伪造，也不修改系统安全设置；它只是让"我主动从项目方拉取的文件"
# 走与浏览器下载不同的落地路径。是否接受这一点，由执行者自行判断。
#
# 用法：见 --help
#
set -euo pipefail

APP_NAME="ProxyMonitor"
REPO="${PTM_REPO:-ooaaeiei2-beep/ProxyMonitor}"
INSTALL_DIR="${PTM_INSTALL_DIR:-/Applications}"
DEST="$INSTALL_DIR/$APP_NAME.app"
VERSION="${PTM_VERSION:-}"
BASE_URL="${PTM_BASE_URL:-}"
PROXY="${PTM_PROXY:-}"
DO_VERIFY=1
DO_QUIT=1
DO_OPEN=1

step() { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '    [注意] %s\n' "$*"; }
die()  { printf '\n[错误] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
ProxyMonitor 安装脚本

用法:
  bash install.sh [选项]

选项:
  -v, --version <x.y.z>   安装指定版本（默认取 GitHub 最新 Release）
      --proxy <url>       下载时走代理，如 http://127.0.0.1:7897
                          （直连 GitHub 超时的话需要；不填则失败时自动探测常见本地端口）
      --no-verify         跳过 DMG 的 SHA-256 校验（不推荐）
      --no-quit           不退出正在运行的 $APP_NAME
      --no-open           安装完成后不自动打开
  -h, --help              显示本帮助

环境变量:
  PTM_INSTALL_DIR   安装目录，默认 /Applications
  PTM_VERSION       同 -v
  PTM_PROXY         同 --proxy
  PTM_BASE_URL      下载基地址（用于镜像或自建分发），需同时指定版本
  PTM_REPO          GitHub 仓库，默认 $REPO

示例:
  bash install.sh                              # 安装最新版到 /Applications
  bash install.sh -v 1.1.0                     # 安装指定版本
  bash install.sh --proxy http://127.0.0.1:7897   # 走本地代理下载
  PTM_BASE_URL=https://mirror.example.com/ptm -v 1.1.0 bash install.sh
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -v|--version)  [ $# -ge 2 ] || die "$1 需要一个版本号"; VERSION="$2"; shift 2 ;;
    --proxy)       [ $# -ge 2 ] || die "$1 需要一个代理地址"; PROXY="$2"; shift 2 ;;
    --no-verify)   DO_VERIFY=0; shift ;;
    --no-quit)     DO_QUIT=0; shift ;;
    --no-open)     DO_OPEN=0; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             die "未知参数：$1（用 --help 查看用法）" ;;
  esac
done

step "检查运行环境"
[ "$(uname -s)" = "Darwin" ] || die "本脚本仅支持 macOS"
for c in curl hdiutil ditto shasum awk; do
  command -v "$c" >/dev/null 2>&1 || die "缺少必需命令：$c"
done
OS_VER="$(sw_vers -productVersion)"
OS_MAJOR="${OS_VER%%.*}"
[ "$OS_MAJOR" -ge 13 ] 2>/dev/null || die "需要 macOS 13 或更高版本，当前 $OS_VER"
info "macOS $OS_VER / $(uname -m)"

# ---------------------------------------------------------------- 下载（含代理）
#
# 为什么需要代理：GitHub 的 Release 资源实际由 objects.githubusercontent.com 提供，
# 与 api.github.com 是不同域名、不同线路。国内直连前者经常 TLS 握手超时
# （curl: (28) SSL connection timeout），此时脚本若不处理，使用者只会看到一句
# 「下载失败」而不知道该配代理。
#
# 策略：显式指定（--proxy / PTM_PROXY）优先；未指定且请求失败时，
# 探测常见本地代理端口，找到一个能连通 github.com 的就用它重试一次。

CURL_OPTS=( -fL --retry 3 --retry-delay 2 --connect-timeout 15 )
[ -n "$PROXY" ] && CURL_OPTS+=( -x "$PROXY" )

# 下载到文件：$1=url $2=输出文件
fetch() { curl "${CURL_OPTS[@]}" -o "$2" "$1"; }

# 探测本地代理：打印可用地址则返回 0
detect_proxy() {
  for p in 7897 7890 6152 1087 8080 8888; do
    # 只做一次 CONNECT + TLS 握手，不发请求体；能拿到 HTTP 状态码即视为可用
    code="$(curl -s -o /dev/null -x "http://127.0.0.1:$p" \
              --max-time 4 --connect-timeout 3 \
              -w '%{http_code}' https://github.com 2>/dev/null || true)"
    case "$code" in
      200|301|302|303|307|308) printf 'http://127.0.0.1:%s' "$p"; return 0 ;;
    esac
  done
  return 1
}

# 未显式指定代理时，尝试探测并启用；成功则返回 0
try_auto_proxy() {
  [ -n "$PROXY" ] && return 1
  local found
  found="$(detect_proxy)" || return 1
  PROXY="$found"
  CURL_OPTS+=( -x "$PROXY" )
  return 0
}

step "确定版本"
if [ -z "$VERSION" ]; then
  [ -z "$BASE_URL" ] || die "使用 PTM_BASE_URL 时必须同时指定版本（-v 或 PTM_VERSION）"
  LATEST_URL="https://api.github.com/repos/$REPO/releases/latest"
  VERSION="$(curl "${CURL_OPTS[@]}" -sSL --max-time 20 "$LATEST_URL" 2>/dev/null \
    | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' | head -1)"
  if [ -z "$VERSION" ] && try_auto_proxy; then
    warn "查询最新版本失败，改用检测到的本地代理 $PROXY 重试"
    VERSION="$(curl "${CURL_OPTS[@]}" -sSL --max-time 20 "$LATEST_URL" 2>/dev/null \
      | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' | head -1)"
  fi
  [ -n "$VERSION" ] || die "无法获取最新版本号（网络受限？）
      可任选：用 -v 指定版本 / 用 --proxy 指定本地代理 / 用 PTM_BASE_URL 指向镜像"
fi
[ -n "$BASE_URL" ] || BASE_URL="https://github.com/$REPO/releases/download/v$VERSION"
info "版本 $VERSION"
info "来源 $BASE_URL"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/proxymonitor-install.XXXXXX")"
MOUNT_POINT="$TMP_DIR/mnt"
mkdir -p "$MOUNT_POINT"
MOUNTED=0
cleanup() {
  if [ "$MOUNTED" -eq 1 ]; then
    hdiutil detach "$MOUNT_POINT" -quiet -force >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

DMG="$TMP_DIR/$APP_NAME-$VERSION.dmg"
SUMS="$TMP_DIR/SHA256SUMS.txt"
DMG_URL="$BASE_URL/$APP_NAME-$VERSION.dmg"
SUMS_URL="$BASE_URL/SHA256SUMS.txt"

# ---------------------------------------------------------------- 下载

step "下载安装包"
if [ -n "$PROXY" ]; then
  info "使用代理 $PROXY"
fi
if ! fetch "$DMG_URL" "$DMG"; then
  if try_auto_proxy; then
    warn "直连下载失败，改用检测到的本地代理 $PROXY 重试"
    fetch "$DMG_URL" "$DMG" || die "通过代理 $PROXY 下载仍失败：$DMG_URL"
  else
    die "下载失败：$DMG_URL

      GitHub 的 Release 资源由 objects.githubusercontent.com 提供，
      国内直连常出现 TLS 握手超时（curl 报 28）。可任选一种方式：

        1. 指定本地代理（Clash 常见端口 7897，Surge 6152，V2RayU 1087）
             bash install.sh --proxy http://127.0.0.1:7897
        2. 用镜像（PTM_BASE_URL 指向能访问的镜像目录）
             PTM_BASE_URL=https://your-mirror/ptm -v $VERSION bash install.sh
        3. 用浏览器手动下载后自行安装
             $DMG_URL"
  fi
fi
info "$(du -h "$DMG" | awk '{print $1}')"

step "校验完整性"
ACTUAL="$(shasum -a 256 "$DMG" | awk '{print $1}')"
if [ "$DO_VERIFY" -eq 1 ]; then
  if fetch "$SUMS_URL" "$SUMS"; then
    EXPECTED="$(awk -v f="$APP_NAME-$VERSION.dmg" '$2==f || $2=="*"f {print $1; exit}' "$SUMS")"
    [ -n "$EXPECTED" ] || die "SHA256SUMS.txt 中找不到 $APP_NAME-$VERSION.dmg 的记录"
    if [ "$ACTUAL" != "$EXPECTED" ]; then
      die "校验失败，安装包可能被篡改或损坏
      期望 $EXPECTED
      实际 $ACTUAL"
    fi
    info "SHA-256 与发布记录一致"
  else
    die "无法获取 SHA256SUMS.txt，拒绝在未校验的情况下安装
      如确认来源可信，可加 --no-verify 跳过（不建议）"
  fi
else
  warn "已跳过校验，安装包 SHA-256 为 $ACTUAL"
fi

if [ "$DO_QUIT" -eq 1 ] && pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  step "退出正在运行的 $APP_NAME"
  osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x "$APP_NAME" >/dev/null 2>&1 || break
    sleep 0.5
  done
  if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    warn "未响应退出请求，强制结束"
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    sleep 1
  fi
  info "已退出"
fi

step "挂载并安装"
hdiutil attach -nobrowse -readonly -noverify -mountpoint "$MOUNT_POINT" "$DMG" >/dev/null \
  || die "挂载 DMG 失败"
MOUNTED=1

SRC="$MOUNT_POINT/$APP_NAME.app"
if [ ! -d "$SRC" ]; then
  SRC="$(find "$MOUNT_POINT" -maxdepth 2 -type d -name "$APP_NAME.app" | head -1)"
fi
[ -n "$SRC" ] && [ -d "$SRC" ] || die "DMG 内未找到 $APP_NAME.app"

mkdir -p "$INSTALL_DIR"
[ -w "$INSTALL_DIR" ] || die "$INSTALL_DIR 不可写，请改用 PTM_INSTALL_DIR=~/Applications"

if [ -e "$DEST" ]; then
  BACKUP_ROOT="$HOME/Library/Application Support/$APP_NAME/backups"
  BACKUP="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)-$VERSION"
  mkdir -p "$BACKUP_ROOT"
  mv "$DEST" "$BACKUP"
  info "旧版本已备份到 $BACKUP"
fi

ditto "$SRC" "$DEST" || die "复制到 $DEST 失败"
xattr -dr com.apple.quarantine "$DEST" >/dev/null 2>&1 || true
info "已安装到 $DEST"

step "验证安装"
if codesign --verify --deep --strict "$DEST" >/dev/null 2>&1; then
  info "代码签名自检通过（ad-hoc，无开发者身份）"
else
  warn "代码签名自检未通过，应用可能无法启动"
fi
INSTALLED_VER="$(defaults read "$DEST/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo '未知')"
info "已安装版本 $INSTALLED_VER"
if xattr -p com.apple.quarantine "$DEST" >/dev/null 2>&1; then
  warn "目标仍带 quarantine 标记，请手动执行：xattr -cr \"$DEST\""
fi

step "完成"
info "更新：重新运行本脚本即可（会自动退出、备份、替换）"
info "卸载：rm -rf \"$DEST\""

if [ "$DO_OPEN" -eq 1 ]; then
  open "$DEST" 2>/dev/null || warn "自动打开失败，请手动启动"
fi
