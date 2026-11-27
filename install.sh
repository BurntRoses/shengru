#!/bin/bash
# First installation only. Subsequent updates belong to the signed in-app updater.
set -euo pipefail
export LC_ALL=C
fail(){ printf '%s\n' "$*" >&2; exit 1; }
[[ $(uname -s) = Darwin ]] || fail '需要 macOS 14 或更高版本。'
major=$(sw_vers -productVersion | cut -d. -f1); (( major >= 14 )) || fail '需要 macOS 14 或更高版本。'
here=$(cd "$(dirname "$0")" && pwd); app='如流.app'; dest='/Applications'
open_installed(){
  local bundle="$1" uid; uid=$(/usr/bin/id -u)
  if [[ "$uid" = 0 || "$(/usr/bin/stat -f %u /dev/console)" != "$uid" ]]; then
    printf '已安装：%s\n登录 Mac 后即可打开如流。\n' "$bundle"; return 0
  fi
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$bundle" || :
  printf '正在打开：%s\n' "$bundle"
  /usr/bin/open "$bundle" --args --phraseflow-installed "$bundle" || fail "如流已安装，但未能启动。请在访达中打开：$bundle"
}
for d in /Applications "$HOME/Applications"; do
  for bundle in "$d"/*.app; do
    [[ -f "$bundle/Contents/Info.plist" ]] || continue
    id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$bundle/Contents/Info.plist" 2>/dev/null || true)
    if [[ "$id" = cn.shengru.dictation ]]; then open_installed "$bundle"; exit 0; fi
  done
done
if [[ ! -w "$dest" ]]; then dest="$HOME/Applications"; mkdir -p "$dest"; fi
url=$(/usr/bin/xmllint --nonet --xpath 'string(/rss/channel/item[1]/enclosure/@url)' "$here/appcast.xml")
[[ "$url" == https://github.com/BurntRoses/shengru/releases/download/*/Shengru.dmg ]] || fail '无法读取发布地址。'
url="${url%/Shengru.dmg}/PhraseFlow.dmg"
work=$(mktemp -d "${TMPDIR:-/tmp}/shengru-install.XXXXXX"); stage=''; mount="$work/volume"
finish(){ if [[ -d "$mount/$app" ]]; then hdiutil detach "$mount" -quiet || return; fi; rm -rf "$work"; if [[ -n "$stage" ]]; then rm -rf "$stage"; fi; }; trap finish EXIT
printf '正在下载如流…\n'; /usr/bin/curl --proto '=https' --proto-redir '=https' -fL --retry 2 "$url" -o "$work/PhraseFlow.dmg"
(cd "$work" && /usr/bin/shasum -a 256 -c "$here/SHA256SUMS")
mkdir "$mount"; hdiutil attach "$work/PhraseFlow.dmg" -nobrowse -readonly -mountpoint "$mount" -quiet
[[ $(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$mount/$app/Contents/Info.plist") = cn.shengru.dictation ]] || fail '安装镜像中的应用不匹配。'
stage=$(mktemp -d "$dest/.shengru-install.XXXXXX"); /usr/bin/ditto "$mount/$app" "$stage/$app"; /usr/bin/codesign --verify --strict --deep --all-architectures "$stage/$app"
# curl is not a Launch Services downloader. Mark the internet download for normal first-launch assessment.
if ! /usr/bin/xattr -p com.apple.quarantine "$stage/$app" >/dev/null 2>&1; then
  /usr/bin/xattr -w com.apple.quarantine "$(printf '0083;%x;PhraseFlow Installer;' "$(date +%s)")" "$stage/$app"
fi
/bin/mv -n "$stage/$app" "$dest/"; [[ ! -e "$stage/$app" ]] || fail '安装位置已有应用，未覆盖。'
open_installed "$dest/$app"
