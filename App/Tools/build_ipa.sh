#!/usr/bin/env bash
# 编译未签名 IPA（用于 GitHub Release / 侧载重签），只能在装了 Xcode 的 macOS 上运行。
# 用法：App/Tools/build_ipa.sh [版本号] [build 号]
#   版本号默认取 App/project.yml 的 MARKETING_VERSION，build 号默认取当前时间。
# 依赖：先运行 App/Tools/fetch_kokoro.sh --frameworks-only 下载语音框架；
#       装了 xcodegen 时会自动重新生成 App/Chaiyue.xcodeproj。
# 产物：dist/Chaiyue-<版本号>-unsigned.ipa、dist/Chaiyue-<版本号>-dSYMs.zip、dist/SHA256SUMS.txt
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "找不到 xcodebuild：这个脚本需要 macOS 和 Xcode。" >&2
  exit 1
fi

version="${1:-$(awk -F'"' '/MARKETING_VERSION:/ {print $2; exit}' App/project.yml)}"
build_number="${2:-$(date +%Y%m%d%H%M)}"
configuration="${CONFIGURATION:-Release}"
out="$root/dist"

if [ -z "$version" ]; then
  echo "无法从 App/project.yml 读到 MARKETING_VERSION，请手动传入版本号。" >&2
  exit 2
fi
case "$build_number" in
  *[!0-9]*)
    echo "build 号只能是数字：$build_number" >&2
    exit 2
    ;;
esac

for framework in sherpa-onnx onnxruntime; do
  if [ ! -d "Packages/SherpaTTS/Frameworks/$framework.xcframework" ]; then
    echo "缺少 Packages/SherpaTTS/Frameworks/$framework.xcframework" >&2
    echo "先运行：bash App/Tools/fetch_kokoro.sh --frameworks-only" >&2
    exit 1
  fi
done

if command -v xcodegen >/dev/null 2>&1; then
  (cd App && xcodegen generate --quiet)
elif [ ! -d App/Chaiyue.xcodeproj ]; then
  echo "没有 App/Chaiyue.xcodeproj，先安装 xcodegen：brew install xcodegen" >&2
  exit 1
fi

archive="$root/build/Chaiyue.xcarchive"
work="$root/build/ipa"
rm -rf "$archive" "$work"
mkdir -p "$out" "$work/Payload"

echo "==> 编译 Chaiyue ${version} (${build_number})，未签名"
xcodebuild archive \
  -project App/Chaiyue.xcodeproj \
  -scheme Chaiyue \
  -configuration "$configuration" \
  -destination 'generic/platform=iOS' \
  -archivePath "$archive" \
  -quiet \
  MARKETING_VERSION="$version" \
  CURRENT_PROJECT_VERSION="$build_number" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY=""

app="$archive/Products/Applications/Chaiyue.app"
if [ ! -d "$app" ]; then
  echo "归档完成但没找到 $app" >&2
  exit 1
fi

# ditto 保留 .app 内的符号链接；zip -y 同样按链接存储，避免框架签名结构被破坏
ditto "$app" "$work/Payload/Chaiyue.app"
ipa="$out/Chaiyue-${version}-unsigned.ipa"
rm -f "$ipa"
(cd "$work" && zip -qry "$ipa" Payload)

dSYM="$out/Chaiyue-${version}-dSYMs.zip"
rm -f "$dSYM"
if [ -d "$archive/dSYMs" ]; then
  ditto -c -k --sequesterRsrc --keepParent "$archive/dSYMs" "$dSYM"
fi

(
  cd "$out"
  : > SHA256SUMS.txt
  shasum -a 256 ./Chaiyue-"${version}"-unsigned.ipa >> SHA256SUMS.txt
  if [ -f "$dSYM" ]; then
    shasum -a 256 ./Chaiyue-"${version}"-dSYMs.zip >> SHA256SUMS.txt
  fi
)

echo "==> 完成"
ls -lh "$out"
