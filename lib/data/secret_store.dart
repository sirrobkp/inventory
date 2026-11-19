import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'repo.dart';

/// Secrets (VFD passwords, supplier credentials, certificate password).
/// Android/iOS/Windows/Linux: platform secure storage. macOS: Keychain needs a signing entitlement that
/// ad-hoc/CI builds do not have, so secrets are kept in the local app database (base64-obfuscated, NOT encrypted).
class SecretStore {
  static const _s = FlutterSecureStorage();
  static final _repo = Repo();
  static bool get _fallback => Platform.isMacOS;

  static Future<String?> read(String key) async {
    if (_fallback) {
      final v = await _repo.getSetting('secret:$key');
      return v == null ? null : utf8.decode(base64.decode(v));
    }
    return _s.read(key: key);
  }

  static Future<void> write(String key, String value) async {
    if (_fallback) {
      await _repo.setSetting('secret:$key', base64.encode(utf8.encode(value)));
      return;
    }
    await _s.write(key: key, value: value);
  }
}
