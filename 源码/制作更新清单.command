#!/bin/bash
# Publish the DMG under its immutable tag before pushing the signed feed to main.
set -euo pipefail
[[ $# = 3 ]] || { echo '用法：制作更新清单.command <PhraseFlow.dmg> <发布标签> <输出目录>' >&2; exit 1; }
img=$(cd "$(dirname "$1")" && pwd)/$(basename "$1"); tag=$2; out=$3; tools=${SPARKLE_TOOLS:?请指定 Sparkle 发布工具 bin 目录}; account='cn.shengru.dictation.updates'
[[ $(basename "$img") = PhraseFlow.dmg && "$tag" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || exit 2
mkdir -p "$out"; t=$(mktemp -d); m="$t/mnt"; mkdir "$m"; trap 'if [[ -d "$m/如流.app" ]]; then hdiutil detach "$m" -quiet || exit 1; fi; rm -rf "$t"' EXIT
hdiutil verify -quiet "$img"; hdiutil attach "$img" -readonly -nobrowse -mountpoint "$m" -quiet
bundle="$m/如流.app"; codesign --verify --deep --strict --all-architectures "$bundle"
readkey(){ /usr/libexec/PlistBuddy -c "Print $1" "$bundle/Contents/Info.plist"; }
[[ $(readkey CFBundleIdentifier) = cn.shengru.dictation && $("$tools/generate_keys" --account "$account" -p) = "$(readkey SUPublicEDKey)" ]] || { echo '更新签名与这份应用不一致。' >&2; exit 1; }
v=$(readkey CFBundleVersion); short=$(readkey CFBundleShortVersionString); os=$(readkey LSMinimumSystemVersion); [[ $v =~ ^[0-9]+$ && $short =~ ^[0-9.]+$ && $os =~ ^[0-9.]+$ ]] || exit 3
sig=$("$tools/sign_update" --account "$account" -p "$img"); "$tools/sign_update" --account "$account" --verify "$img" "$sig"
size=$(stat -f%z "$img"); date_rfc=$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')
# Existing 1.0 clients accept this immutable legacy asset name only. Publish it as a byte-identical alias.
notes=$(readkey PhraseFlowReleaseNotes | sed 's/\&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
cat >"$t/appcast.xml" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
 <channel><title>如流 · PhraseFlow</title><link>https://github.com/BurntRoses/shengru</link><description>macOS</description>
  <item><title>如流 $short</title><pubDate>$date_rfc</pubDate>
   <sparkle:version>$v</sparkle:version><sparkle:shortVersionString>$short</sparkle:shortVersionString><sparkle:minimumSystemVersion>$os</sparkle:minimumSystemVersion>
   <description sparkle:descriptionFormat="plain-text">$notes</description>
   <enclosure url="https://github.com/BurntRoses/shengru/releases/download/$tag/Shengru.dmg" type="application/octet-stream" length="$size" sparkle:edSignature="$sig"/>
  </item>
 </channel>
</rss>
XML
"$tools/sign_update" --account "$account" "$t/appcast.xml"; "$tools/sign_update" --account "$account" --verify "$t/appcast.xml"; (cd "$(dirname "$img")" && shasum -a 256 PhraseFlow.dmg) > "$t/SHA256SUMS"
mv "$t/SHA256SUMS" "$t/appcast.xml" "$out/"
