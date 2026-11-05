#!/usr/bin/env bash
# Generates/patches android/ + ios/ and the local signing plugin. Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")/.."

# 1) Platform folders
if [ ! -d android ] || [ ! -d ios ]; then
  flutter create --org tz.co.kibo --project-name kibo_trade --platforms android,ios .
fi
rm -f test/widget_test.dart

# 2) Local plugin 'kibo_signer' (certificate signing on Android + iOS).
#    Generated from Flutter's own plugin template so Gradle/Pod config always matches your Flutter version.
if [ ! -d packages/kibo_signer ]; then
  mkdir -p packages
  flutter create --template=plugin --org tz.co.kibo --project-name kibo_signer --platforms android,ios packages/kibo_signer
  rm -rf packages/kibo_signer/example packages/kibo_signer/test
fi
KT=$(find packages/kibo_signer/android -name '*.kt' -path '*main*' | head -1)
PKG=$(grep -m1 '^package ' "$KT" | sed 's/package //; s/;//' | tr -d '\r ')
CLASS=$(basename "$KT" .kt)
if [ "$CLASS" != "KiboSignerPlugin" ]; then echo "Unexpected plugin class $CLASS"; exit 1; fi
sed "s/__PKG__/$PKG/" plugin_overlay/KiboSignerPlugin.kt.tmpl > "$KT"
SW=$(find packages/kibo_signer/ios -name '*.swift' | head -1)
cp plugin_overlay/KiboSignerPlugin.swift "$SW"
echo "Signing plugin installed: $KT / $SW"

# 3) Android: permissions + minSdk >= 23
MANIFEST=android/app/src/main/AndroidManifest.xml
if ! grep -q 'android.permission.CAMERA' "$MANIFEST"; then
  python3 - "$MANIFEST" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace('<application', open('android_overlay/permissions.xml').read() + '\n    <application', 1)
open(p, 'w').write(s)
PY
fi
G=$(ls android/app/build.gradle.kts android/app/build.gradle 2>/dev/null | head -1)
sed -i.bak -E 's/minSdk = flutter\.minSdkVersion/minSdk = maxOf(23, flutter.minSdkVersion)/; s/minSdkVersion flutter\.minSdkVersion/minSdkVersion Math.max(23, flutter.minSdkVersion)/' "$G" && rm -f "$G.bak"

# 4) iOS: usage descriptions + deployment target 15.5 (ML Kit barcode scanner needs it)
python3 - <<'PY'
import plistlib
p = 'ios/Runner/Info.plist'
d = plistlib.load(open(p, 'rb'))
d['NSCameraUsageDescription'] = 'Used to scan product barcodes.'
d['NSBluetoothAlwaysUsageDescription'] = 'Used to connect to your receipt printer.'
d['NSBluetoothPeripheralUsageDescription'] = 'Used to connect to your receipt printer.'
plistlib.dump(d, open(p, 'wb'))
PY
sed -i.bak -E 's/IPHONEOS_DEPLOYMENT_TARGET = [0-9.]+;/IPHONEOS_DEPLOYMENT_TARGET = 15.5;/g' ios/Runner.xcodeproj/project.pbxproj && rm -f ios/Runner.xcodeproj/project.pbxproj.bak
if [ -f ios/Podfile ]; then
  sed -i.bak -E "s/^# *platform :ios.*/platform :ios, '15.5'/; s/^platform :ios.*/platform :ios, '15.5'/" ios/Podfile && rm -f ios/Podfile.bak
fi
echo "Platform preparation done."
