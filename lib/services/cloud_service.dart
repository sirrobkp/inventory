import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';

import '../data/db.dart';
import '../data/repo.dart';
import '../data/secret_store.dart';

/// Cloud backup & restore on Google Firebase (Firestore + Email/Password auth), talking to Firebase's public REST
/// API with plain `http`. No Firebase plugins are compiled into the app, so there is nothing that can break the
/// Android / iOS / macOS / Windows builds (no CocoaPods or Swift Package Manager changes).
///
/// The local SQLite database stays the live store (a POS must keep working offline). The cloud holds a full
/// snapshot that is refreshed automatically and can be restored on a new or replacement device.
class CloudService {
  CloudService(this.repo);
  final Repo repo;

  String? _token, _uid;
  DateTime _exp = DateTime(2000);

  static const rules = '''rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    match /users/{uid}/{document=**} {
      allow read, write: if request.auth != null && request.auth.uid == uid;
    }
  }
}''';

  // Parents first. Deleted in reverse order, inserted in this order.
  static const _tables = [
    'settings', 'products', 'employees', 'sales', 'purchases', 'assets', 'expenses', 'z_reports', 'equity_ledger',
    'stock_movements', 'sale_items', 'sale_vat', 'payroll', 'sale_returns', 'sale_return_items', 'return_vat', 'purchase_returns',
  ];
  static const _chunk = 250000; // characters per Firestore document (limit is ~1 MiB)

  void forgetLogin() {
    _token = null;
    _uid = null;
    _exp = DateTime(2000);
  }

  Future<String> _cfg(String k) async => (await repo.getSetting(k)) ?? '';
  Future<bool> get configured async => (await _cfg('cloud_project')).isNotEmpty && (await _cfg('cloud_api_key')).isNotEmpty && (await _cfg('cloud_email')).isNotEmpty;

  // ------------------------------------------------------------------ auth
  Future<void> _auth() async {
    if (_token != null && _exp.isAfter(DateTime.now())) return;
    final key = await _cfg('cloud_api_key');
    final res = await http
        .post(Uri.parse('https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=$key'),
            headers: {'Content-Type': 'application/json'}, body: jsonEncode({'email': await _cfg('cloud_email'), 'password': await SecretStore.read('cloud_password') ?? '', 'returnSecureToken': true}))
        .timeout(const Duration(seconds: 30));
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode != 200) throw StateError(_friendly((j['error'] as Map?)?['message'] as String? ?? 'HTTP ${res.statusCode}'));
    _token = j['idToken'] as String;
    _uid = j['localId'] as String;
    _exp = DateTime.now().add(Duration(seconds: (int.tryParse('${j['expiresIn']}') ?? 3600) - 120));
  }

  String _friendly(String m) {
    if (m.contains('EMAIL_NOT_FOUND') || m.contains('INVALID_PASSWORD') || m.contains('INVALID_LOGIN_CREDENTIALS')) return 'Wrong email or password (create the user in Firebase Console > Authentication)';
    if (m.contains('API key not valid') || m.contains('API_KEY')) return 'The Web API key is not valid';
    if (m.contains('OPERATION_NOT_ALLOWED')) return 'Enable Email/Password sign-in in Firebase Console > Authentication > Sign-in method';
    if (m.contains('PERMISSION_DENIED')) return 'Permission denied - paste the security rules into Firestore > Rules';
    return m;
  }

  String get _db => 'projects/${_pidCache}/databases/(default)/documents';
  String _pidCache = '';

  Map<String, String> get _h => {'Authorization': 'Bearer $_token', 'Content-Type': 'application/json'};

  Future<http.Response> _get(String path, [String query = '']) => http.get(Uri.parse('https://firestore.googleapis.com/v1/$_db/$path$query'), headers: _h).timeout(const Duration(seconds: 60));

  Future<void> _commit(List<Map<String, dynamic>> writes) async {
    final res = await http.post(Uri.parse('https://firestore.googleapis.com/v1/$_db:commit'), headers: _h, body: jsonEncode({'writes': writes})).timeout(const Duration(seconds: 120));
    if (res.statusCode != 200) {
      String m = 'HTTP ${res.statusCode}';
      try {
        m = ((jsonDecode(res.body) as Map)['error'] as Map)['message'] as String;
      } catch (_) {}
      throw StateError(_friendly(m));
    }
  }

  Future<void> _ready() async {
    _pidCache = await _cfg('cloud_project');
    await _auth();
  }

  // ------------------------------------------------------------------ test
  Future<String> test() async {
    try {
      await _ready();
      final r = await _get('users/$_uid/meta/backup');
      if (r.statusCode == 404) return 'Signed in. No backup in the cloud yet.';
      if (r.statusCode == 403) return _friendly('PERMISSION_DENIED');
      final f = ((jsonDecode(r.body) as Map)['fields'] as Map?) ?? const {};
      return 'Signed in. Last cloud backup: ${(f['createdAt'] as Map?)?['stringValue'] ?? 'unknown'} from ${(f['device'] as Map?)?['stringValue'] ?? 'unknown device'}.';
    } on StateError catch (e) {
      return e.message;
    } catch (e) {
      return 'Could not reach Firebase: $e';
    }
  }

  // ------------------------------------------------------------------ backup
  Future<void> backup([void Function(String)? progress]) async {
    await _ready();
    final db = await Db.instance;
    progress?.call('Reading local data...');
    final chunks = <Map<String, dynamic>>[];
    final counts = <String, int>{};
    for (final table in _tables) {
      var rows = await db.query(table);
      if (table == 'settings') {
        rows = rows.where((r) {
          final k = (r['key'] as String?) ?? '';
          return !k.startsWith('secret:') && k != 'vfd_last_response';
        }).toList();
      }
      counts[table] = rows.length;
      final text = jsonEncode(rows);
      for (var i = 0, n = 0; i < text.length || n == 0; i += _chunk, n++) {
        final part = text.substring(i, i + _chunk > text.length ? text.length : i + _chunk);
        chunks.add({'id': '${table}__${n.toString().padLeft(4, '0')}', 't': table, 'i': n, 'd': part});
        if (text.length <= _chunk) break;
      }
    }
    final snap = DateTime.now().millisecondsSinceEpoch.toString();
    String? previous;
    final meta = await _get('users/$_uid/meta/backup');
    if (meta.statusCode == 200) previous = (((jsonDecode(meta.body) as Map)['fields'] as Map?)?['snapshotId'] as Map?)?['stringValue'] as String?;

    for (var i = 0; i < chunks.length; i += 8) {
      progress?.call('Uploading ${i + 1}-${i + 8 > chunks.length ? chunks.length : i + 8} of ${chunks.length}...');
      await _commit([
        for (final c in chunks.skip(i).take(8))
          {
            'update': {
              'name': '$_db/users/$_uid/snapshots/$snap/chunks/${c['id']}',
              'fields': {'t': {'stringValue': c['t']}, 'i': {'integerValue': '${c['i']}'}, 'd': {'stringValue': c['d']}},
            }
          }
      ]);
    }
    final now = DateTime.now().toIso8601String();
    await _commit([
      {
        'update': {
          'name': '$_db/users/$_uid/meta/backup',
          'fields': {
            'snapshotId': {'stringValue': snap},
            'createdAt': {'stringValue': now},
            'device': {'stringValue': Platform.operatingSystem},
            'counts': {'stringValue': jsonEncode(counts)},
          },
        }
      }
    ]);
    await repo.setSetting('cloud_last_backup', now);
    if (previous != null && previous != snap) {
      progress?.call('Removing the previous backup...');
      try {
        await _deleteSnapshot(previous);
      } catch (_) {} // harmless leftovers
    }
    progress?.call('Backup complete');
  }

  Future<void> _deleteSnapshot(String snap) async {
    String? token;
    final names = <String>[];
    do {
      final r = await _get('users/$_uid/snapshots/$snap/chunks', '?pageSize=100&mask.fieldPaths=i${token == null ? '' : '&pageToken=$token'}');
      if (r.statusCode != 200) return;
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      for (final d in (j['documents'] as List? ?? const [])) {
        names.add((d as Map)['name'] as String);
      }
      token = j['nextPageToken'] as String?;
    } while (token != null);
    for (var i = 0; i < names.length; i += 100) {
      await _commit([for (final n in names.skip(i).take(100)) {'delete': n}]);
    }
  }

  // ------------------------------------------------------------------ restore
  /// Replaces ALL local data with the cloud snapshot. Device-only settings (printer, cloud login, secrets) are kept.
  Future<void> restore([void Function(String)? progress]) async {
    await _ready();
    progress?.call('Finding the latest backup...');
    final meta = await _get('users/$_uid/meta/backup');
    if (meta.statusCode == 404) throw StateError('There is no backup in the cloud yet');
    if (meta.statusCode != 200) throw StateError(_friendly('PERMISSION_DENIED'));
    final snap = ((((jsonDecode(meta.body) as Map)['fields'] as Map)['snapshotId']) as Map)['stringValue'] as String;

    final parts = <String, List<MapEntry<int, String>>>{};
    String? token;
    var n = 0;
    do {
      final r = await _get('users/$_uid/snapshots/$snap/chunks', '?pageSize=20${token == null ? '' : '&pageToken=$token'}');
      if (r.statusCode != 200) throw StateError('Could not download the backup (HTTP ${r.statusCode})');
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      for (final d in (j['documents'] as List? ?? const [])) {
        final f = (d as Map)['fields'] as Map;
        final t = (f['t'] as Map)['stringValue'] as String;
        final i = int.parse('${(f['i'] as Map)['integerValue']}');
        parts.putIfAbsent(t, () => []).add(MapEntry(i, (f['d'] as Map)['stringValue'] as String));
        n++;
      }
      progress?.call('Downloaded $n pieces...');
      token = j['nextPageToken'] as String?;
    } while (token != null);

    final data = <String, List<Map<String, Object?>>>{};
    for (final t in _tables) {
      final p = parts[t];
      if (p == null) throw StateError('Backup is incomplete (missing $t) - restore cancelled, nothing was changed');
      p.sort((a, b) => a.key.compareTo(b.key));
      final rows = jsonDecode(p.map((e) => e.value).join()) as List;
      data[t] = [for (final r in rows) (r as Map).cast<String, Object?>()];
    }

    progress?.call('Replacing local data...');
    final db = await Db.instance;
    final keep = (await db.query('settings')).where((r) {
      final k = (r['key'] as String?) ?? '';
      return k.startsWith('secret:') || k.startsWith('cloud_') || k == 'printer_mac' || k == 'printer_name';
    }).toList();
    await db.transaction((t) async {
      for (final table in _tables.reversed) {
        await t.delete(table);
      }
      for (final table in _tables) {
        for (final row in data[table]!) {
          if (table == 'settings' && ((row['key'] as String?) ?? '').startsWith('cloud_')) continue;
          await t.insert(table, row, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
      for (final r in keep) {
        await t.insert('settings', r, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
    progress?.call('Restore complete');
  }
}
