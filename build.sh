#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
  dev=/Applications/Xcode.app/Contents/Developer
  compiler="$dev/Toolchains/XcodeDefault.xctoolchain/usr/bin"
  sdk="$dev/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
else
  compiler="$(dirname "$(xcrun --find swiftc)")"
  sdk="$(xcrun --sdk macosx --show-sdk-path)"
fi
mkdir -p .build/module-cache 'MacMonitor.app/Contents/MacOS'
"$compiler/clang" -isysroot "$sdk" -O2 -mmacosx-version-min=14.0 -c Metrics.c -o .build/Metrics.o
"$compiler/swiftc" -sdk "$sdk" -target arm64-apple-macos14.0 -O \
  -module-cache-path .build/module-cache -import-objc-header Metrics.h \
  main.swift SSDReader.swift ComputeReader.swift ExternalStorageReader.swift AppSettings.swift .build/Metrics.o -o 'MacMonitor.app/Contents/MacOS/MacMonitor'
cp Info.plist 'MacMonitor.app/Contents/Info.plist'
mkdir -p 'MacMonitor.app/Contents/Resources'
cp -R Resources/ja.lproj Resources/en.lproj 'MacMonitor.app/Contents/Resources/'
/usr/bin/codesign --force --sign - 'MacMonitor.app'
'MacMonitor.app/Contents/MacOS/MacMonitor' --self-test
printf '%s\n' '完成：MacMonitor.app'
