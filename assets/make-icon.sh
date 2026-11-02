#!/usr/bin/env bash
# Regenerate assets/nvim.icns from the official Neovim mark.
# Needs: curl, rsvg-convert (brew install librsvg), magick (brew install imagemagick), iconutil
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [[ ! -f neovim-mark.svg ]]; then
  curl -sSL --max-time 30 -o neovim-mark.svg https://neovim.io/logos/neovim-mark.svg
fi

# macOS icon grid: 1024 canvas, 824 rounded square, corner radius 185.
magick -size 824x824 gradient:"#2c2c3e"-"#16161e" "$WORK/grad.png"
magick -size 824x824 xc:none -fill white -draw "roundrectangle 0,0,823,823,185,185" "$WORK/mask.png"
magick "$WORK/grad.png" "$WORK/mask.png" -alpha off -compose CopyOpacity -composite "$WORK/round.png"
magick -size 1024x1024 xc:none "$WORK/round.png" -geometry +100+100 -composite "$WORK/base.png"

rsvg-convert -h 560 neovim-mark.svg -o "$WORK/mark.png"
magick "$WORK/base.png" "$WORK/mark.png" -gravity center -geometry +0-6 -composite "$WORK/icon1024.png"

ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
            "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" \
            "512 512x512" "1024 512x512@2x"; do
  set -- $spec
  magick "$WORK/icon1024.png" -resize "$1x$1" "$ICONSET/icon_$2.png"
done
iconutil -c icns "$ICONSET" -o nvim.icns
echo "wrote $(pwd)/nvim.icns"
