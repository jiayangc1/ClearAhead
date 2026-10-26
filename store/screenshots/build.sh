#!/bin/sh
# Renders each slide in index.html to a 1320x2868 PNG (App Store 6.9" iPhone).
set -e
cd "$(dirname "$0")"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
mkdir -p out
for slide in $(grep -o '<section class="slide" data-name="[^"]*"' index.html | cut -d'"' -f4); do
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
    --window-size=1320,2868 --virtual-time-budget=4000 --allow-file-access-from-files \
    --screenshot="$PWD/out/$slide.png" "file://$PWD/index.html?slide=$slide" 2>/dev/null
  echo "out/$slide.png"
done
