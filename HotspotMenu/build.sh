#!/bin/zsh
set -eu
cd -- "${0:A:h}"
app='HotspotMenu.app'
mkdir -p "$app/Contents/MacOS"
xcrun clang -fobjc-arc -Wall -Wextra -framework Foundation -framework CoreWLAN ../HotspotProbe/main.m -o "$app/Contents/MacOS/hotspot-probe"
xcrun swiftc main.swift -o "$app/Contents/MacOS/HotspotMenu" -framework AppKit -framework Network -framework CoreWLAN
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>HotspotMenu</string>
<key>CFBundleIdentifier</key><string>local.hotspotmenu.app</string>
<key>CFBundleName</key><string>HotspotMenu</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>15.0</string>
</dict></plist>
PLIST
xattr -cr "$app"
codesign --force --sign - "$app/Contents/MacOS/hotspot-probe"
xattr -d com.apple.FinderInfo "$app" 2>/dev/null || true
codesign --force --sign - "$app"
"$app/Contents/MacOS/HotspotMenu" --self-test
