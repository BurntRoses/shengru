#!/bin/bash
# Public mode fails closed. Local mode is an explicit choice, never a fallback after a signing failure.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; mode=release
case "${1:-}" in --preview) mode=preview;shift;; --local) mode=local;shift;; --release) shift;; esac
app="${1:-$here/../如流.app}"; name='PhraseFlow.dmg'; [ "$mode" != local ] || name='如流（本机版）.dmg'; out="${2:-$here/../$name}"
if [ "$mode" = release ]; then
  [ -n "${DEVELOPER_ID:-}" ] && [ -n "${NOTARY_PROFILE:-}" ] || { echo '公开分发需要 Developer ID Application 和钥匙串公证配置。本机自用请显式传入 --local。' >&2; exit 1; }
fi
[ -d "$app/Contents" ] && [ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist")" = cn.shengru.dictation ] || { echo '请选择已构建的如流应用。' >&2; exit 1; }
codesign --verify --all-architectures --strict --deep "$app"
for f in "$app/Contents/MacOS/VoiceInput" "$app/Contents/Frameworks/"*.dylib; do for arch in arm64 x86_64; do xcrun lipo "$f" -verify_arch "$arch"; done; done
if [ "$mode" = release ]; then
  codesign --verify -R='anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' "$app" || { echo '请先用 Developer ID Application 构建并签名。' >&2; exit 1; }
fi
work="$(mktemp -d)"; stage="$(mktemp -d "$(dirname "$out")/.voice-image.XXXXXX")"; trap 'rm -rf "$work" "$stage"' EXIT
bundle="$work/如流.app"; ditto "$app" "$bundle"; ln -s /Applications "$work/Applications"
notarize(){ xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$stage/receipt.json"; if [ "$(plutil -extract status raw -o - "$stage/receipt.json")" != Accepted ]; then cat "$stage/receipt.json" >&2; echo '未获公证，不会生成分发镜像。' >&2;exit 1;fi; }
if [ "$mode" = release ]; then
  ditto -c -k --keepParent "$bundle" "$stage/application.zip"; notarize "$stage/application.zip"; xcrun stapler staple "$bundle"; xcrun stapler validate "$bundle"
  syspolicy_check distribution "$bundle"; spctl --assess --type execute "$bundle"
fi
hdiutil create -quiet -volname '如流' -srcfolder "$work" -fs HFS+ -format UDZO -imagekey zlib-level=6 "$stage/product.dmg"
if [ "$mode" = release ]; then
  codesign --sign "$DEVELOPER_ID" --timestamp "$stage/product.dmg"
  team(){ codesign -dv --verbose=4 "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p'; }; [ "$(team "$stage/product.dmg")" = "$(team "$bundle")" ] || { echo '应用与镜像的开发者不一致。' >&2;exit 1; }
  notarize "$stage/product.dmg"; xcrun stapler staple "$stage/product.dmg"; xcrun stapler validate "$stage/product.dmg"; spctl --assess --type open --context context:primary-signature "$stage/product.dmg"
fi
hdiutil verify -quiet "$stage/product.dmg"; mv -f "$stage/product.dmg" "$out"; printf '已生成：%s\n' "$out"
