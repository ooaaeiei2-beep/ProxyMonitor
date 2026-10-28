#!/bin/bash
#
# 只用 Command Line Tools 构建 ProxyMonitor（不依赖 Xcode.app）
#
# 用法：
#   ./scripts/build-clt.sh              # release，universal（arm64 + x86_64）
#   ./scripts/build-clt.sh --debug      # debug，仅本机架构（带 -DDEBUG，含 Mock 开关）
#   ./scripts/build-clt.sh --output ~/Desktop   # 指定产物目录
#   ./scripts/build-clt.sh --bundle-id com.x.buildtest   # 覆盖 bundle id（并行测试用）
#
# 产物：<output>/ProxyMonitor.app（adhoc 签名，可直接双击运行）
#
# 为什么需要这个脚本：Xcode 约 15 GB，而本项目全部代码是 AppKit，
# 编译只需要 swiftc + SDK；其余由本脚本手工完成：
#   - Info.plist 里全是 $(VAR) 占位符，必须自己替换
#   - 图标资源用 iconutil 生成（actool 强制要求 Xcode，无法使用）
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/ProxyTrafficMonitor"
PBX="$ROOT/ProxyMonitor.xcodeproj/project.pbxproj"

CONFIG="release"
OUTPUT="$ROOT/build/clt"
BUNDLE_ID_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --debug)  CONFIG="debug"; shift ;;
        --output) OUTPUT="$2"; shift 2 ;;
        --bundle-id) BUNDLE_ID_OVERRIDE="$2"; shift 2 ;;
        -h|--help)
            awk 'NR>=3 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
            exit 0 ;;
        *) echo "未知参数：$1" >&2; exit 2 ;;
    esac
done

# ---------------------------------------------------------------- 环境检查

if ! xcrun --find swiftc >/dev/null 2>&1; then
    echo "错误：找不到 swiftc，请先安装 Command Line Tools（xcode-select --install）" >&2
    exit 1
fi

SDK="$(xcrun --show-sdk-path --sdk macosx)"
SWIFT_FILES=()
while IFS= read -r file; do SWIFT_FILES+=("$file"); done < <(find "$SRC" -name "*.swift" | sort)

if [[ ${#SWIFT_FILES[@]} -eq 0 ]]; then
    echo "错误：$SRC 下没有找到 .swift 源文件" >&2
    exit 1
fi

# 版本号与 bundle id 从工程文件里读，避免两处维护
read_pbx() { grep -m1 -oE "$1 = [^;]+" "$PBX" | sed -E 's/.*= *//; s/^"//; s/"$//'; }
VERSION="$(read_pbx MARKETING_VERSION)"
BUILD_NUMBER="$(read_pbx CURRENT_PROJECT_VERSION)"
BUNDLE_ID="$(read_pbx PRODUCT_BUNDLE_IDENTIFIER)"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
BUNDLE_ID="${BUNDLE_ID_OVERRIDE:-${BUNDLE_ID:-com.xushuda.proxymonitor}}"

MIN_MACOS="13.0"

# ---------------------------------------------------------------- 编译

APP="$OUTPUT/ProxyMonitor.app"
WORK="$OUTPUT/.build"
rm -rf "$WORK" "$APP"
mkdir -p "$WORK" "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [[ "$CONFIG" == "debug" ]]; then
    OPT_FLAGS=(-Onone -g -DDEBUG)
    ARCHS=("$(uname -m)")
else
    OPT_FLAGS=(-O -wmo)
    ARCHS=(arm64 x86_64)
fi

echo "==> 编译（${CONFIG}，架构：${ARCHS[*]}）"
SLICES=()
for arch in "${ARCHS[@]}"; do
    out="$WORK/ProxyMonitor-$arch"
    echo "    - $arch"
    xcrun swiftc "${OPT_FLAGS[@]}" -swift-version 5 -sdk "$SDK" \
        -target "${arch}-apple-macos${MIN_MACOS}" \
        -o "$out" "${SWIFT_FILES[@]}"
    SLICES+=("$out")
done

if [[ ${#SLICES[@]} -gt 1 ]]; then
    lipo -create "${SLICES[@]}" -output "$APP/Contents/MacOS/ProxyMonitor"
else
    cp "${SLICES[0]}" "$APP/Contents/MacOS/ProxyMonitor"
fi
chmod 755 "$APP/Contents/MacOS/ProxyMonitor"

# ---------------------------------------------------------------- 资源

echo "==> 生成图标"
ICONSET="$WORK/AppIcon.iconset"
cp -R "$SRC/Assets.xcassets/AppIcon.appiconset" "$ICONSET"
rm -f "$ICONSET/Contents.json"
if ! iconutil --convert icns --output "$APP/Contents/Resources/AppIcon.icns" "$ICONSET" 2>/dev/null; then
    echo "    警告：iconutil 失败，跳过图标（不影响运行）" >&2
    rm -f "$APP/Contents/Resources/AppIcon.icns"
fi

echo "==> 生成 Info.plist"
python3 - "$SRC/App/Info.plist" "$APP/Contents/Info.plist" \
    "$BUNDLE_ID" "$VERSION" "$BUILD_NUMBER" "$MIN_MACOS" <<'PY'
import plistlib, sys

src, dst, bundle_id, version, build_number, min_macos = sys.argv[1:7]
with open(src, "rb") as handle:
    info = plistlib.load(handle)

# 工程里的 Info.plist 用 $(VAR) 占位符，xcodebuild 会替换；这里等价替换
substitutions = {
    "$(DEVELOPMENT_LANGUAGE)": "en",
    "$(EXECUTABLE_NAME)": "ProxyMonitor",
    "$(PRODUCT_BUNDLE_IDENTIFIER)": bundle_id,
    "$(PRODUCT_NAME)": "ProxyMonitor",
    "$(MARKETING_VERSION)": version,
    "$(CURRENT_PROJECT_VERSION)": build_number,
}
for key, value in list(info.items()):
    if isinstance(value, str):
        info[key] = substitutions.get(value, value)

info.setdefault("CFBundleIconFile", "AppIcon")
info["LSMinimumSystemVersion"] = min_macos

with open(dst, "wb") as handle:
    plistlib.dump(info, handle)
print(f"    bundle id = {bundle_id} | 版本 = {version} ({build_number})")
PY

# ---------------------------------------------------------------- 签名

echo "==> adhoc 签名"
codesign --force --sign - --options runtime "$APP" 2>&1 | sed 's/^/    /'

# ---------------------------------------------------------------- 结果

SIZE="$(du -sh "$APP" | awk '{print $1}')"
SHA="$(shasum -a 256 "$APP/Contents/MacOS/ProxyMonitor" | awk '{print $1}')"
echo
echo "==> 完成"
echo "    产物：$APP"
echo "    大小：${SIZE}（可执行文件 sha256 ${SHA:0:16}…）"
echo "    运行：open \"$APP\""
if [[ "$CONFIG" == "release" && "$BUNDLE_ID" == "com.xushuda.proxymonitor" ]]; then
    echo "    提示：与已安装的正式版同 bundle id，同时运行会争抢同一个状态栏位置与配置域"
fi
