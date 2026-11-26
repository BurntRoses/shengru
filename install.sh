#!/bin/bash
# First installation only. Subsequent updates belong to the signed in-app updater.
set -euo pipefail
export LC_ALL=C
fail(){ printf '%s\n' "$*" >&2; exit 1; }
[[ $(uname -s) = Darwin ]] || fail '需要 macOS 14 或更高版本。'
major=$(sw_vers -productVersion | cut -d. -f1); (( major >= 14 )) || fail '需要 macOS 14 或更高版本。'
here=$(cd "$(dirname "$0")" && pwd); app='语音输入.app'; dest='/Applications'
for d in /Applications "$HOME/Applications"; do [[ ! -e "$d/$app" && ! -L "$d/$app" ]] || fail "已安装：$d/$app。请在应用的「设置 → 更新」中检查更新。"; done
if [[ ! -w "$dest" ]]; then dest="$HOME/Applications"; mkdir -p "$dest"; fi
url=$(/usr/bin/xmllint --nonet --xpath 'string(/rss/channel/item[1]/enclosure/@url)' "$here/appcast.xml")
[[ "$url" == https://github.com/BurntRoses/shengru/releases/download/*/Shengru.dmg ]] || fail '无法读取发布地址。'
work=$(mktemp -d "${TMPDIR:-/tmp}/shengru-install.XXXXXX"); stage=''; mount="$work/volume"
finish(){ if [[ -d "$mount/$app" ]]; then hdiutil detach "$mount" -quiet || return; fi; rm -rf "$work"; if [[ -n "$stage" ]]; then rm -rf "$stage"; fi; }; trap finish EXIT
printf '正在下载语音输入…\n'; /usr/bin/curl --proto '=https' --proto-redir '=https' -fL --retry 2 "$url" -o "$work/Shengru.dmg"
(cd "$work" && /usr/bin/shasum -a 256 -c "$here/SHA256SUMS")
mkdir "$mount"; hdiutil attach "$work/Shengru.dmg" -nobrowse -readonly -mountpoint "$mount" -quiet
[[ $(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$mount/$app/Contents/Info.plist") = cn.shengru.dictation ]] || fail '安装镜像中的应用不匹配。'
stage=$(mktemp -d "$dest/.shengru-install.XXXXXX"); /usr/bin/ditto "$mount/$app" "$stage/$app"; /usr/bin/codesign --verify --strict --deep --all-architectures "$stage/$app"
# curl is not a Launch Services downloader. Mark the internet download for normal first-launch assessment.
if ! /usr/bin/xattr -p com.apple.quarantine "$stage/$app" >/dev/null 2>&1; then
  /usr/bin/xattr -w com.apple.quarantine "$(printf '0083;%x;Shengru Installer;' "$(date +%s)")" "$stage/$app"
fi
/bin/mv -n "$stage/$app" "$dest/"; [[ ! -e "$stage/$app" ]] || fail '安装位置已有应用，未覆盖。'
printf '已安装：%s/%s\n请从 Finder 打开，按系统提示授权。\n' "$dest" "$app"
