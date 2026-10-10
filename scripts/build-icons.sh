#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

source_icon="Resources/AppIcon.png"
iconset=".build/AppIcon.iconset"
appicon="Sources/FiletoApp/Resources/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$iconset" "$appicon"

for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$source_icon" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    retina_size=$((size * 2))
    sips -z "$retina_size" "$retina_size" "$source_icon" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
    cp "$iconset/icon_${size}x${size}.png" "$appicon/"
    cp "$iconset/icon_${size}x${size}@2x.png" "$appicon/"
done

iconutil -c icns "$iconset" -o Sources/FiletoApp/Resources/AppIcon.icns
