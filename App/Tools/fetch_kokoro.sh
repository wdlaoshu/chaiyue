#!/usr/bin/env bash
# 下载本地神经语音所需的 sherpa-onnx iOS 框架（编译用），并生成放到服务器上的 Kokoro 语音包
# 语音包输出到 dist/kokoro-v1.1/（含 manifest.json），整个目录上传到 LocalVoiceStore.baseURL 对应位置
# 用法：App/Tools/fetch_kokoro.sh [--frameworks-only] [缓存目录]
#   --frameworks-only  只下载编译用的两个 iOS 框架，不下载 Kokoro 模型、不生成语音包（CI 编译用）
set -euo pipefail

frameworks_only=0
cache=""
for arg in "$@"; do
  case "$arg" in
    --frameworks-only) frameworks_only=1 ;;
    -h|--help) sed -n '2,5p' "$0"; exit 0 ;;
    -*) echo "未知参数：$arg" >&2; exit 2 ;;
    *)
      if [ -n "$cache" ]; then echo "多余的参数：$arg" >&2; exit 2; fi
      cache="$arg"
      ;;
  esac
done
cache="${cache:-${TMPDIR:-/tmp}/chaiyue-kokoro}"

root="$(cd "$(dirname "$0")/../.." && pwd)"
frameworks="$root/Packages/SherpaTTS/Frameworks"
model="$root/dist/kokoro-v1.1"
mkdir -p "$cache" "$frameworks"

sherpa_url="https://github.com/k2-fsa/sherpa-onnx/releases/download/xcframework/sherpa-onnx-v2.0.1-ios-static.xcframework.zip"
sherpa_sum="88aa569f71b7903e0bbdfbe6e2e114b3b95862b1ef0759eea3024f82926d7374"
ort_url="https://github.com/csukuangfj/onnxruntime-libs/releases/download/v1.28.2/onnxruntime-ios-static-xcframework-1.28.2.xcframework.zip"
ort_sum="2c2299acbb461d26d4bac4bc85985d40e7c7177ed6072703ae0846d88b0b4599"
# 用 fp32 版：int8 动态量化在手机 CPU 上反而更慢（iPhone 17 Pro 实测比实时还慢，fp32 约 2.4 倍实时）
model_url="https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-multi-lang-v1_1.tar.bz2"

fetch() {
  local url=$1 file=$2
  [ -f "$cache/$file" ] || curl -L --fail --retry 3 --retry-delay 2 -o "$cache/$file" "$url"
}

check() {
  local file=$1 sum=$2
  local actual
  actual=$(shasum -a 256 "$cache/$file" | cut -d ' ' -f 1)
  [ "$actual" = "$sum" ] || { echo "校验失败：$file"; exit 1; }
}

sherpa_zip=$(basename "$sherpa_url")
ort_zip=$(basename "$ort_url")
model_tar=$(basename "$model_url")
fetch "$sherpa_url" "$sherpa_zip" && check "$sherpa_zip" "$sherpa_sum"
fetch "$ort_url" "$ort_zip" && check "$ort_zip" "$ort_sum"
if [ "$frameworks_only" -eq 0 ]; then
  fetch "$model_url" "$model_tar"
fi

rm -rf "$frameworks/sherpa-onnx.xcframework" "$frameworks/onnxruntime.xcframework"
unzip -q "$cache/$sherpa_zip" -d "$frameworks"
unzip -q "$cache/$ort_zip" -d "$frameworks"

if [ "$frameworks_only" -eq 1 ]; then
  echo "完成（仅框架）：${frameworks}"
  exit 0
fi

tmp="$cache/kokoro"
rm -rf "$tmp" && mkdir -p "$tmp"
tar xjf "$cache/$model_tar" -C "$tmp"
src="$tmp/kokoro-multi-lang-v1_1"
rm -rf "$model" && mkdir -p "$model"
# v2.0 起 Kokoro 只用词典，不再需要 espeak-ng-data 与 dict；小文件在前，失败能尽早暴露
files="tokens.txt LICENSE date-zh.fst number-zh.fst phone-zh.fst lexicon-us-en.txt lexicon-zh.txt voices.bin model.onnx"
for f in $files; do
  cp "$src/$f" "$model/$f"
done
rm -rf "$tmp"

{
  printf '{\n  "version": "kokoro-multi-lang-v1.1",\n  "files": [\n'
  sep=""
  for f in $files; do
    size=$(stat -f %z "$model/$f")
    sum=$(shasum -a 256 "$model/$f" | cut -d ' ' -f 1)
    printf '%s    {"name": "%s", "size": %s, "sha256": "%s"}' "$sep" "$f" "$size" "$sum"
    sep=$',\n'
  done
  printf '\n  ]\n}\n'
} > "$model/manifest.json"

echo "完成：${frameworks}"
echo "语音包：${model}（$(du -sh "$model" | cut -f 1)），整个目录上传到服务器"
