#!/usr/bin/env bash
# Turns code signing OFF for the Runner target and every CocoaPods target (unsigned IPA for AltStore/AltServer).
# Run AFTER `flutter pub get` and after the Podfile exists.
set -euo pipefail
cd "$(dirname "$0")/.."

# Runner target: Release.xcconfig is its base configuration
X=ios/Flutter/Release.xcconfig
grep -q 'CODE_SIGNING_ALLOWED' "$X" || printf '\nCODE_SIGNING_ALLOWED=NO\nCODE_SIGNING_REQUIRED=NO\nCODE_SIGN_IDENTITY=\n' >> "$X"
echo "xcconfig patched"

# Pods: resource bundles / frameworks must not ask for a Development Team
if [ -f ios/Podfile ]; then
python3 - <<'PY'
import re
p = 'ios/Podfile'
s = open(p).read()
if 'CODE_SIGNING_ALLOWED' not in s:
    s = re.sub(r"^\s*#?\s*platform :ios.*$", "platform :ios, '15.5'", s, count=1, flags=re.M)
    inject = """    target.build_configurations.each do |config|
      config.build_settings['CODE_SIGNING_ALLOWED'] = 'NO'
      config.build_settings['CODE_SIGNING_REQUIRED'] = 'NO'
      config.build_settings['CODE_SIGN_IDENTITY'] = ''
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.5'
    end
"""
    new = re.sub(r"(flutter_additional_ios_build_settings\(target\)\n)", lambda m: m.group(1) + inject, s, count=1)
    if new == s:
        raise SystemExit("Could not find flutter_additional_ios_build_settings(target) in Podfile")
    open(p, 'w').write(new)
    print("Podfile patched")
else:
    print("Podfile already patched")
PY
else
  echo "WARNING: ios/Podfile not found - only the xcconfig was patched"
fi
