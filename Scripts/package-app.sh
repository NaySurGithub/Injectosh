#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
MINGW_CXX=${MINGW_CXX:-x86_64-w64-mingw32-g++}
command -v "$MINGW_CXX" >/dev/null 2>&1 || {
    echo "Missing x86_64 MinGW compiler: $MINGW_CXX" >&2
    exit 1
}
mkdir -p Sources/Injectosh/Resources
"$MINGW_CXX" -std=c++20 -O2 -municode -static -static-libgcc -static-libstdc++ \
    Scripts/InjectorHelper.cpp -o Sources/Injectosh/Resources/InjectoshInjector.exe
swift build -c release
APP="$ROOT/dist/Injectosh.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Injectosh "$APP/Contents/MacOS/Injectosh"
cp -R .build/release/Injectosh_Injectosh.bundle "$APP/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Injectosh</string>
<key>CFBundleIdentifier</key><string>dev.injectosh.app</string>
<key>CFBundleName</key><string>Injectosh</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
