# Windows desktop build preparation (PowerShell). Separate from the Android/iOS/macOS scripts.
$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")

# 1) local plugin skeleton (pubspec depends on it by path; Windows ignores it - it only declares android/ios)
if (-not (Test-Path "packages/kibo_signer")) {
  New-Item -ItemType Directory -Force -Path "packages" | Out-Null
  flutter create --template=plugin --no-pub --org tz.co.kibo --project-name kibo_signer --platforms android,ios packages/kibo_signer
  if ($LASTEXITCODE -ne 0) { throw "plugin skeleton failed" }
  Remove-Item -Recurse -Force "packages/kibo_signer/example", "packages/kibo_signer/test" -ErrorAction SilentlyContinue
}

# 2) Windows project
if (-not (Test-Path "windows")) {
  flutter create --no-pub --org tz.co.kibo --project-name kibo_trade --platforms windows .
  if ($LASTEXITCODE -ne 0) { throw "flutter create failed" }
}
Remove-Item -Force "test/widget_test.dart" -ErrorAction SilentlyContinue

# 3) SQLite for Windows: sqflite_common_ffi (bundles SQLite via build hooks) - added only here, so phone builds are untouched
flutter pub add sqflite_common_ffi
if ($LASTEXITCODE -ne 0) { throw "pub add sqflite_common_ffi failed" }

$init = @'
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Windows/Linux: use the FFI SQLite and keep the database in the app-support folder.
Future<void> initPlatform() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final dir = await getApplicationSupportDirectory();
  await databaseFactory.setDatabasesPath(p.join(dir.path, 'databases'));
}
'@
Set-Content -Path "lib/data/platform_init.dart" -Value $init -Encoding UTF8
Write-Host "Windows preparation done."
