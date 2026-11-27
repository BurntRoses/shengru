#!/bin/bash
# Build only in a staging directory; swap the app after verification. The bundled model works offline. Optional model installs are initiated in Settings.
set -euo pipefail
mode=release
case "${1:-}" in --preview) mode=preview; shift;; --local) mode=local; shift;; --release) shift;; esac
signer="${DEVELOPER_ID:-}"; [ "$mode" != preview ] || signer=""
if [ "$mode" = release ] && [ -z "$signer" ]; then
  echo '没有指定 Developer ID Application，未构建。开发自测请显式使用 --local。' >&2; exit 1
fi
if [ "$mode" = local ] && [ -z "$signer" ]; then
  signer="${DEVELOPMENT_ID:-}"
  if [ -z "$signer" ]; then
    # Never guess between teams or create/trust a certificate on the developer’s behalf.
    ids="$(security find-identity -v -p codesigning | awk '/"Apple Development:/{print $2}')"
    case "$ids" in *$'\n'*) echo '有多个开发签名，请用 DEVELOPMENT_ID 指定一个。' >&2; exit 1;; esac
    signer="$ids"
  fi
  [ -n "$signer" ] || echo '本机固定版：未配置开发签名。请保留这一份成品；不同构建不能沿用它的系统授权。' >&2
fi
here="$(cd "$(dirname "$0")" && pwd)"; out="${1:-$here/..}"; mkdir -p "$out"; out="$(cd "$out" && pwd)"; dest="$out/如流.app"
case "$out/" in /Applications/*|"$HOME"/Applications/*) echo '请构建到工程目录，再从同一安装镜像安装。构建不会覆盖正在使用的应用。' >&2; exit 1;; esac
stage="$(mktemp -d "$out/.voice-build.XXXXXX")"; trap 'rm -rf "$stage"' EXIT
app="$stage/如流.app"; c="$app/Contents"; mkdir -p "$c/MacOS" "$c/Frameworks" "$c/Resources/Speech"; dep="$stage/deps"; mkdir -p "$dep/Frameworks" "$dep/Speech"
engine='sherpa-onnx-v2.0.3-osx-universal2-shared-no-tts-lib'; model='sherpa-onnx-x-asr-960ms-streaming-zipformer-transducer-zh-en-punct-int8-2026-06-05'
fetch(){ curl --fail --location --silent --show-error --retry 2 "$1" -o "$2"; printf '%s  %s\n' "$3" "$2" | shasum -a 256 -c -; }
# Reuse only identical upstream data. A stale installation or a re-signed framework is not a cache hit.
match(){ local dir="$1" group="$2"; [ -d "$dir" ] && (cd "$dir" && awk -v p="${group}/" 'index($2,p)==1 {sub(p,"",$2);print $1 "  " $2}' "$here/Resources/Dependencies.sha256" | shasum -a256 -c - --status) 2>/dev/null; }
speech=''; libs=''
if [ -n "${VOICE_RESOURCES:-}" ]; then
  speech="$VOICE_RESOURCES/Speech"; libs="$VOICE_RESOURCES/Frameworks"
else
  for base in "$here/../如流.app/Contents" '/Applications/如流.app/Contents' '/Applications/语音输入.app/Contents'; do
    if [ -z "$speech" ] && match "$base/Resources/Speech" Speech; then speech="$base/Resources/Speech"; fi
    if [ -z "$libs" ] && match "$base/Frameworks" Frameworks; then libs="$base/Frameworks"; fi
  done
fi
if [ -z "$speech" ]; then
  fetch "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/$model.tar.bz2" "$stage/model.tar.bz2" '0a92b798bd6801c333c7ce8aebf5ba769bfe7f3f3511699a67837b2288428603'
  speech="$stage/extracted-speech"; mkdir "$speech"; tar -xjf "$stage/model.tar.bz2" --strip-components 1 -C "$speech"; mv "$speech/encoder.int8.onnx" "$speech/encoder.onnx"; mv "$speech/joiner.int8.onnx" "$speech/joiner.onnx"
fi
if [ -z "$libs" ]; then
  fetch "https://github.com/k2-fsa/sherpa-onnx/releases/download/v2.0.3/$engine.tar.bz2" "$stage/engine.tar.bz2" '749acfadb36f044c5bb4fb11903a7fde2f8468cb3c183a05bb881326982d3af7'
  mkdir "$stage/engine";tar -xjf "$stage/engine.tar.bz2" --strip-components 1 -C "$stage/engine"; libs="$stage/engine/lib"
fi
cp "$speech"/{encoder.onnx,decoder.onnx,joiner.onnx,tokens.txt,bpe.model} "$dep/Speech/"; cp "$libs"/{libonnxruntime.dylib,libsherpa-onnx-c-api.dylib} "$dep/Frameworks/"; cp -R "$here/Resources/Profiles" "$dep/Profiles"
(cd "$dep"; shasum -a 256 -c "$here/Resources/Dependencies.sha256" >/dev/null)
for table in places.tsv words.tsv readings.tsv collections.tsv catalog.tsv catalog-readings.tsv topics.tsv senses.tsv review.tsv classics.tsv classical-sounds.tsv 来源.txt; do [ -s "$here/Resources/Vocabulary/$table" ] || { echo "缺少内置词库：$table" >&2; exit 1; }; done
mv "$dep/Profiles" "$c/Resources/"; mv "$dep/Speech/"* "$c/Resources/Speech/"; mv "$dep/Frameworks/"* "$c/Frameworks/";cp -R "$here/Resources/Licenses" "$here/Resources/Vocabulary" "$c/Resources/";cp "$here/Resources/Info.plist" "$c/Info.plist"; cp -R "$here/Resources/zh-Hans.lproj" "$here/Resources/en.lproj" "$c/Resources/"
xcrun swiftc "$here/Sources/Brand.swift" "$here/Resources/Icon.swift" -o "$stage/DrawIcon"
"$stage/DrawIcon" "$stage/PhraseFlow.iconset"; iconutil -c icns "$stage/PhraseFlow.iconset" -o "$c/Resources/PhraseFlow.icns"
# Pinned upstream binary, including its nested signatures and symlinks. An optional archive is still hashed.
sparkle_sha=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
archive="${SPARKLE_ARCHIVE:-$stage/Sparkle.tar.xz}"
if [ -n "${SPARKLE_ARCHIVE:-}" ]; then printf '%s  %s\n' "$sparkle_sha" "$archive" | shasum -a256 -c -
else fetch 'https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-2.10.1.tar.xz' "$archive" "$sparkle_sha"; fi
mkdir "$stage/sparkle"; tar -xf "$archive" -C "$stage/sparkle" ./Sparkle.framework; ditto "$stage/sparkle/Sparkle.framework" "$c/Frameworks/Sparkle.framework"
codesign --verify --all-architectures --strict --deep "$c/Frameworks/Sparkle.framework"
for arch in arm64 x86_64; do
  xcrun clang -target "$arch-apple-macos14.0" -O2 -c "$here/Bridge/VoiceBridge.c" -o "$stage/$arch.o"
  xcrun swiftc -swift-version 5 -target "$arch-apple-macos14.0" -O -import-objc-header "$here/Bridge/VoiceBridge.h" "$here"/Sources/*.swift "$stage/$arch.o" -F "$c/Frameworks" -framework Sparkle -L "$c/Frameworks" -lsherpa-onnx-c-api -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' -o "$stage/VoiceInput-$arch"
done
xcrun lipo -create "$stage/VoiceInput-arm64" "$stage/VoiceInput-x86_64" -output "$c/MacOS/VoiceInput"
for bin in "$c/MacOS/VoiceInput" "$c/Frameworks/"*.dylib; do for arch in arm64 x86_64; do xcrun lipo "$bin" -verify_arch "$arch"; done;done
# Dependencies ship with their own verified ad-hoc signature. Leave their sealed bytes intact for offline rebuilds.
for f in "$c/Frameworks/"*.dylib; do codesign --verify --strict "$f"; done
# Preserve a real signing identity on updates. Never grant trust based on bundle ID alone.
if [ -n "$signer" ]; then
  [ "$signer" != '-' ] || { echo '指定的身份不能是临时签名。' >&2; exit 1; }
  stamp=--timestamp; [ "$mode" != local ] || stamp=--timestamp=none
  for f in "$c/Frameworks/"*.dylib; do codesign --force --options runtime "$stamp" --sign "$signer" "$f"; done
  sp="$c/Frameworks/Sparkle.framework/Versions/B"
  # Preserve the upstream entitlements on each component; do not use --deep to sign.
  for component in "$sp"/XPCServices/*.xpc "$sp/Autoupdate" "$sp/Updater.app" "$c/Frameworks/Sparkle.framework"; do
    codesign --force --options runtime "$stamp" --preserve-metadata=identifier,entitlements --sign "$signer" "$component"
  done
  codesign --force --options runtime "$stamp" --entitlements "$here/Resources/Voice.entitlements" --sign "$signer" "$app"
  requirement='anchor apple generic'; [ "$mode" != release ] || requirement+=' and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
  codesign --verify --all-architectures -R="$requirement" "$app"
else
  codesign --force --sign - --timestamp=none --entitlements "$here/Resources/Voice.entitlements" "$app"
fi
codesign --verify --all-architectures --deep --strict "$app"
if [ -e "$dest" ]; then
  [ ! -L "$dest" ] && [ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$dest/Contents/Info.plist" 2>/dev/null)" = 'cn.shengru.dictation' ] || { echo '目标处存在其他应用，未覆盖。' >&2; exit 1; }
  previous="$(codesign -d -r- "$dest" 2>&1 | sed -nE 's/^([#] )?designated => //p')"
  [ -n "$previous" ] && codesign --verify --all-architectures -R="$previous" "$app" 2>/dev/null || { echo '新构建不能继承旧版的系统授权，已保留原应用。请使用原签名；首次迁移请另选空目录。' >&2; exit 1; }
  mv "$dest" "$stage/previous.app"
fi
if ! mv "$app" "$dest"; then if [ -d "$stage/previous.app" ]; then mv "$stage/previous.app" "$dest"; fi;exit 1;fi
printf '已生成：%s\n' "$dest"
