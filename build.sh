#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
build_dir="${BREEZE_BUILD_DIR:-.build}"
mkdir -p "$build_dir" Breeze.app/Contents/MacOS Breeze.app/Contents/Resources
if [[ -f Breeze.icns ]]; then cp Breeze.icns Breeze.app/Contents/Resources/; fi
xcrun clang -O2 -arch arm64 -mmacosx-version-min=14.0 -c Source/Bridge/SMCBridge.c -o "$build_dir/SMCBridge.o"
common=(-swift-version 5 -O -target arm64-apple-macosx14.0 -import-objc-header Source/Bridge/SMCBridge.h Source/Core.swift "$build_dir/SMCBridge.o" -framework IOKit)
xcrun swiftc "${common[@]}" Source/Helper.swift -o Breeze.app/Contents/MacOS/BreezeHelper
xcrun swiftc "${common[@]}" Source/Widget.swift -o Breeze.app/Contents/MacOS/Breeze -framework AppKit -framework SwiftUI
cat > Breeze.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Breeze</string>
<key>CFBundleDisplayName</key><string>Breeze</string>
<key>CFBundleIdentifier</key><string>local.breeze.widget</string>
<key>CFBundleExecutable</key><string>Breeze</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.1</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleIconFile</key><string>Breeze.icns</string>
</dict></plist>
PLIST
xattr -cr Breeze.app
codesign --force --sign - Breeze.app/Contents/MacOS/BreezeHelper
xattr -d com.apple.FinderInfo Breeze.app 2>/dev/null || true
codesign --force --sign - Breeze.app
if [[ -f Tests/Tests.swift ]]; then
    xcrun swiftc "${common[@]}" Tests/Tests.swift -o "$build_dir/BreezeTests"
    "$build_dir/BreezeTests"
fi
print 'Готово: Breeze.app'
