#!/usr/bin/env bash
# macOS desktop build preparation. Separate from the Android/iOS script so those builds are unaffected.
set -euo pipefail
cd "$(dirname "$0")/.."

# 1) pubspec depends on the local plugin by path; for macOS a bare skeleton is enough
#    (the plugin only declares android/ios, so the macOS build ignores it).
if [ ! -d packages/kibo_signer ]; then
  mkdir -p packages
  flutter create --template=plugin --no-pub --org tz.co.kibo --project-name kibo_signer --platforms android,ios packages/kibo_signer
  rm -rf packages/kibo_signer/example packages/kibo_signer/test
fi

# 2) macOS project
if [ ! -d macos ]; then
  flutter create --no-pub --org tz.co.kibo --project-name kibo_trade --platforms macos .
fi
rm -f test/widget_test.dart

# 3) Sandbox entitlements (network for the supplier API + fonts, files, printing, camera) + camera text
python3 - <<'PY'
import plistlib
for f in ['macos/Runner/DebugProfile.entitlements', 'macos/Runner/Release.entitlements']:
    d = plistlib.load(open(f, 'rb'))
    d['com.apple.security.network.client'] = True
    d['com.apple.security.files.user-selected.read-write'] = True
    d['com.apple.security.print'] = True
    d['com.apple.security.device.camera'] = True
    plistlib.dump(d, open(f, 'wb'))
p = 'macos/Runner/Info.plist'
d = plistlib.load(open(p, 'rb'))
d['NSCameraUsageDescription'] = 'Used to scan product barcodes.'
plistlib.dump(d, open(p, 'wb'))
print('entitlements + Info.plist patched')
PY
echo "macOS preparation done."
