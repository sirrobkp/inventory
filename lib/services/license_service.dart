import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:http/http.dart' as http;

import '../data/repo.dart';
import '../license_config.dart';

enum LicenseState { disabled, ok, trial, grace, expired, suspended, needsCheck }

class LicenseInfo {
  const LicenseInfo(this.state, {this.paidUntil});
  final LicenseState state;
  final DateTime? paidUntil;
  bool get locked => state == LicenseState.expired || state == LicenseState.suspended || state == LicenseState.needsCheck;

  /// Whole days until expiry (rounded up); negative once expired.
  int? daysLeft(DateTime now) => paidUntil == null ? null : (paidUntil!.difference(now).inHours / 24).ceil();
}

/// Registers this installation with your Firebase project, sends a light heartbeat and fetches the subscription
/// state (status + paid-until) that the Kibo Admin app controls. Plain REST over `http`, no Firebase plugins.
class LicenseService {
  LicenseService(this.repo);
  final Repo repo;

  static bool get configured => licenseProject.isNotEmpty && licenseApiKey.isNotEmpty && licenseProject != 'YOUR-PROJECT-ID' && licenseApiKey != 'YOUR-WEB-API-KEY';

  String? _token, _uid;
  DateTime _exp = DateTime(2000);

  // ------------------------------------------------------------- pure rules (cached state -> lock decision)
  static LicenseInfo evaluate(Map<String, String> c, DateTime now) {
    if (!configured) return const LicenseInfo(LicenseState.disabled);
    DateTime? p(String k) => DateTime.tryParse(c[k] ?? '');
    int n(String k, int d) => int.tryParse(c[k] ?? '') ?? d;
    final status = c['lic_status'] ?? '';
    final checked = p('lic_checked_at'), paid = p('lic_paid_until'), clock = p('lic_clock');
    if (clock != null && now.isBefore(clock.subtract(const Duration(days: 1)))) return LicenseInfo(LicenseState.needsCheck, paidUntil: paid); // phone clock moved back
    if (status.isEmpty || checked == null || paid == null) {
      final first = p('lic_first_run') ?? now;
      final end = first.add(Duration(days: n('lic_trial', 14)));
      return now.isBefore(end) ? LicenseInfo(LicenseState.trial, paidUntil: end) : LicenseInfo(LicenseState.expired, paidUntil: end);
    }
    if (status == 'suspended') return LicenseInfo(LicenseState.suspended, paidUntil: paid);
    if (now.difference(checked).inDays > n('lic_offline', 14)) return LicenseInfo(LicenseState.needsCheck, paidUntil: paid);
    if (!now.isAfter(paid)) return LicenseInfo(status == 'trial' ? LicenseState.trial : LicenseState.ok, paidUntil: paid);
    if (!now.isAfter(paid.add(Duration(days: n('lic_grace', 3))))) return LicenseInfo(LicenseState.grace, paidUntil: paid);
    return LicenseInfo(LicenseState.expired, paidUntil: paid);
  }

  // ------------------------------------------------------------------------------- REST
  String get _db => 'projects/$licenseProject/databases/(default)/documents';
  Map<String, String> get _h => {'Authorization': 'Bearer $_token', 'Content-Type': 'application/json'};

  Map<String, dynamic> _enc(Object? v) {
    if (v is String) return {'stringValue': v};
    if (v is bool) return {'booleanValue': v};
    if (v is int) return {'integerValue': '$v'};
    if (v is double) return {'doubleValue': v};
    if (v is DateTime) return {'timestampValue': v.toUtc().toIso8601String()};
    return {'nullValue': null};
  }

  Future<void> _auth() async {
    if (_token != null && _exp.isAfter(DateTime.now())) return;
    final refresh = await repo.getSetting('lic_refresh');
    if (refresh != null && refresh.isNotEmpty) {
      final r = await http
          .post(Uri.parse('https://securetoken.googleapis.com/v1/token?key=$licenseApiKey'), headers: {'Content-Type': 'application/x-www-form-urlencoded'}, body: 'grant_type=refresh_token&refresh_token=${Uri.encodeQueryComponent(refresh)}')
          .timeout(const Duration(seconds: 30));
      if (r.statusCode == 200) {
        final j = jsonDecode(r.body) as Map<String, dynamic>;
        _token = j['id_token'] as String;
        _uid = j['user_id'] as String;
        _exp = DateTime.now().add(Duration(seconds: (int.tryParse('${j['expires_in']}') ?? 3600) - 120));
        await repo.setSetting('lic_refresh', j['refresh_token'] as String);
        return;
      }
      // network errors throw above (we must not create a second identity because of a bad connection);
      // only a real rejection of the old token falls through to a fresh anonymous identity
    }
    final r = await http.post(Uri.parse('https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=$licenseApiKey'), headers: {'Content-Type': 'application/json'}, body: jsonEncode({'returnSecureToken': true})).timeout(const Duration(seconds: 30));
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    if (r.statusCode != 200) throw StateError('License server refused sign-in: ${(j['error'] as Map?)?['message'] ?? r.statusCode} (enable Anonymous sign-in in Firebase Authentication)');
    _token = j['idToken'] as String;
    _uid = j['localId'] as String;
    _exp = DateTime.now().add(Duration(seconds: (int.tryParse('${j['expiresIn']}') ?? 3600) - 120));
    await repo.setSetting('lic_refresh', j['refreshToken'] as String);
    await repo.setSetting('lic_uid', _uid!);
  }

  Future<http.Response> _commit(Map<String, dynamic> write) => http.post(Uri.parse('https://firestore.googleapis.com/v1/$_db:commit'), headers: _h, body: jsonEncode({'writes': [write]})).timeout(const Duration(seconds: 30));
  Future<http.Response> _get(String path) => http.get(Uri.parse('https://firestore.googleapis.com/v1/$_db/$path'), headers: _h).timeout(const Duration(seconds: 30));

  String? _s(Map? f, String k) => ((f?[k]) as Map?)?['stringValue'] as String?;
  int? _i(Map? f, String k) => int.tryParse('${((f?[k]) as Map?)?['integerValue'] ?? ''}');

  /// Registers (first time), sends the heartbeat and refreshes the cached subscription state.
  /// Returns an error text, or null when the server was reached.
  Future<String?> sync(Map<String, String> cfg, Map<String, Object> stats) async {
    try {
      await _auth();
      final name = (cfg['biz_name'] ?? '').isNotEmpty ? cfg['biz_name']! : (cfg['name'] ?? '');
      final os = Platform.operatingSystemVersion;
      final beat = <String, Object>{
        'businessName': name,
        'tin': cfg['tin'] ?? '',
        'platform': Platform.operatingSystem,
        'osVersion': os.length > 80 ? os.substring(0, 80) : os,
        'appVersion': appVersion,
        'fiscalMode': cfg['fiscal_mode'] ?? 'direct',
        ...stats,
      };
      final docName = '$_db/installations/$_uid';
      var r = await _commit({
        'update': {'name': docName, 'fields': {for (final e in beat.entries) e.key: _enc(e.value)}},
        'updateMask': {'fieldPaths': beat.keys.toList()},
        'updateTransforms': [{'fieldPath': 'lastSeen', 'setToServerValue': 'REQUEST_TIME'}],
        'currentDocument': {'exists': true},
      });
      if (r.statusCode == 404 || (r.statusCode == 400 && r.body.contains('NOT_FOUND'))) {
        // first run on this installation: create it as a trial (the server rules cap the trial length)
        var trialDays = 14;
        final cr = await _get('config/app');
        if (cr.statusCode == 200) trialDays = _i((jsonDecode(cr.body) as Map)['fields'] as Map?, 'trialDays') ?? 14;
        r = await _commit({
          'update': {
            'name': docName,
            'fields': {
              'uid': _enc(_uid),
              'status': _enc('trial'),
              'paidUntil': _enc(DateTime.now().toUtc().add(Duration(days: trialDays))),
              for (final e in beat.entries) e.key: _enc(e.value),
            },
          },
          'updateTransforms': [{'fieldPath': 'lastSeen', 'setToServerValue': 'REQUEST_TIME'}, {'fieldPath': 'createdAt', 'setToServerValue': 'REQUEST_TIME'}],
          'currentDocument': {'exists': false},
        });
      }
      if (r.statusCode != 200) return 'License server error (HTTP ${r.statusCode})';

      final me = await _get('installations/$_uid');
      if (me.statusCode != 200) return 'Could not read subscription (HTTP ${me.statusCode})';
      final f = (jsonDecode(me.body) as Map)['fields'] as Map?;
      final paid = ((f?['paidUntil']) as Map?)?['timestampValue'] as String?;
      await repo.setSetting('lic_status', _s(f, 'status') ?? 'trial');
      if (paid != null) await repo.setSetting('lic_paid_until', DateTime.parse(paid).toUtc().toIso8601String());
      await repo.setSetting('lic_msg', _s(f, 'adminMessage') ?? '');
      await repo.setSetting('lic_checked_at', DateTime.now().toUtc().toIso8601String());

      final cr = await _get('config/app');
      if (cr.statusCode == 200) {
        final c = (jsonDecode(cr.body) as Map)['fields'] as Map?;
        await repo.setSetting('lic_price', '${_i(c, 'monthlyPrice') ?? 50000}');
        await repo.setSetting('lic_instr', _s(c, 'paymentInstructions') ?? '');
        await repo.setSetting('lic_support', _s(c, 'supportContact') ?? '');
        await repo.setSetting('lic_grace', '${_i(c, 'graceDays') ?? 3}');
        await repo.setSetting('lic_offline', '${_i(c, 'maxOfflineDays') ?? 14}');
        await repo.setSetting('lic_trial', '${_i(c, 'trialDays') ?? 14}');
      }
      return null;
    } on StateError catch (e) {
      return e.message;
    } catch (e) {
      return 'Offline or license server unreachable';
    }
  }
}
