#!/bin/sh
# Assemble CaptiveWatchdog.app depuis la cible SwiftPM CaptiveWatchdogApp.
# SwiftPM ne produit pas de bundle : Info.plist (LSUIElement, exception ATS)
# et signature ad hoc sont posés ici.
# Usage : Scripts/build-app.sh [release|debug] [dossier de sortie]
set -eu
config=${1:-release}
root=$(cd "$(dirname "$0")/.." && pwd)
out=${2:-$root/.build}
cd "$root"
swift build -c "$config" --product CaptiveWatchdogApp >&2
bin=$(swift build -c "$config" --show-bin-path)
version=$(/usr/bin/sed -nE 's/.*version = "([^"]+)".*/\1/p' Sources/CaptiveKit/BuildInfo.swift)
app="$out/CaptiveWatchdog.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/CaptiveWatchdogApp" "$app/Contents/MacOS/CaptiveWatchdog"
/usr/bin/sed "s/@VERSION@/$version/g" Packaging/Info.plist > "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist" >&2
codesign --force --sign - "$app" >&2
echo "$app"
