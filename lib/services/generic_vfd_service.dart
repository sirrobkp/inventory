import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

import '../data/models.dart';
import '../data/secret_store.dart';
import '../data/repo.dart';
import '../data/tax.dart';
import 'fiscal_result.dart';

/// ---------------------------------------------------------------------------
/// Generic "any VFD supplier" connector.
///
/// A supplier is described by a JSON *profile* (name, base URL, credential fields, auth, the receipt request
/// template and where to find the receipt number / verification code in the response). The user imports the
/// profile once and types the credentials in the app - no code change per supplier.
///
/// Supported: static headers (API key / bearer), HTTP Basic, and token-login flows; JSON, XML or form bodies;
/// JSON-path or xml:TAG response mapping. NOT supported: multi-step flows (create then confirm), request
/// signing, mutual TLS, file uploads. Those need code.
/// ---------------------------------------------------------------------------

class VfdField {
  VfdField(this.key, this.label, this.secret);
  final String key, label;
  final bool secret;
}

class VfdProfile {
  VfdProfile(this.raw);
  final Map<String, dynamic> raw;

  static VfdProfile parse(String json) {
    final dynamic m = jsonDecode(json);
    if (m is! Map<String, dynamic>) throw const FormatException('Profile must be a JSON object');
    final rc = m['receipt'];
    if (m['baseUrl'] is! String) throw const FormatException('Missing "baseUrl"');
    if (rc is! Map || rc['path'] is! String || rc['body'] is! String) throw const FormatException('"receipt" needs "path" and "body"');
    if (m['response'] is! Map) throw const FormatException('Missing "response" mapping');
    return VfdProfile(m);
  }

  String get name => (raw['name'] as String?) ?? 'Supplier';
  List<VfdField> get fields => [
        for (final f in (raw['fields'] as List? ?? const []))
          if (f is Map && f['key'] is String) VfdField(f['key'] as String, (f['label'] as String?) ?? f['key'] as String, f['secret'] == true),
      ];
  Map<String, dynamic> sec(String k) => ((raw[k] as Map?) ?? const {}).cast<String, dynamic>();

  static const example = r'''{
  "_note": "EXAMPLE ONLY - replace the URLs, field names and paths with your supplier's API documentation",
  "name": "Example Supplier",
  "baseUrl": "https://api.example-vfd.co.tz",
  "fields": [
    {"key": "api_key", "label": "API key", "secret": true},
    {"key": "username", "label": "Username"},
    {"key": "password", "label": "Password", "secret": true}
  ],
  "headers": {"X-Api-Key": "{{api_key}}"},
  "auth": {
    "type": "login",
    "path": "/v1/auth/login",
    "method": "POST",
    "contentType": "json",
    "body": "{\"username\":\"{{username}}\",\"password\":\"{{password}}\"}",
    "tokenPath": "data.token",
    "expiresInPath": "data.expires_in",
    "tokenHeader": "Authorization",
    "tokenPrefix": "Bearer "
  },
  "receipt": {
    "method": "POST",
    "path": "/v1/receipts",
    "contentType": "json",
    "body": "{\"reference\":\"{{sale.id}}\",\"tin\":\"{{tin}}\",\"datetime\":\"{{sale.datetime}}\",\"paymentType\":\"{{sale.payment}}\",\"customer\":{\"name\":\"{{sale.customerName}}\",\"tin\":\"{{sale.customerTin}}\",\"mobile\":\"{{sale.mobile}}\"},\"totalExcl\":{{sale.totalExcl}},\"vat\":{{sale.vat}},\"total\":{{sale.total}},\"items\":[{{#items|,}}{\"name\":\"{{item.name}}\",\"qty\":{{item.qty}},\"price\":{{item.price}},\"amount\":{{item.amount}},\"taxCode\":\"{{item.taxCode}}\"}{{/items}}]}"
  },
  "response": {
    "successPath": "success",
    "successValues": ["true"],
    "receiptNoPath": "data.receiptNumber",
    "verificationCodePath": "data.verificationCode",
    "verifyUrlPath": "data.verifyUrl",
    "messagePath": "message"
  },
  "test": {"method": "GET", "path": "/v1/ping"}
}''';
}

/// Tiny template engine: {{var}}, and loops {{#items|,}}...{{/items}} (separator after |).
/// Values are escaped for the body type (json / xml / form).
class Tpl {
  static String _esc(String v, String mode) {
    switch (mode) {
      case 'json':
        final e = jsonEncode(v);
        return e.substring(1, e.length - 1);
      case 'xml':
        return v.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;').replaceAll("'", '&apos;');
      case 'form':
        return Uri.encodeQueryComponent(v);
      default:
        return v;
    }
  }

  static String render(String t, Map<String, String> vars, {Map<String, List<Map<String, String>>> loops = const {}, String mode = 'none'}) {
    final expanded = t.replaceAllMapped(RegExp(r'\{\{#(\w+)(?:\|([^}]*))?\}\}(.*?)\{\{/\1\}\}', dotAll: true), (m) {
      final rows = loops[m[1]] ?? const <Map<String, String>>[];
      return rows.map((r) => render(m[3]!, {...vars, ...r}, mode: mode)).join(m[2] ?? '');
    });
    return expanded.replaceAllMapped(RegExp(r'\{\{\s*([\w.]+)\s*\}\}'), (m) => _esc(vars[m[1]] ?? '', mode));
  }
}

class GenericVfdService {
  GenericVfdService(this.repo);
  final Repo repo;
  String? _token;
  DateTime _exp = DateTime(2000);

  // ------------------------------------------------------------ profile + credentials
  Future<VfdProfile?> profile() async {
    final j = await repo.getSetting('vfd_profile');
    if (j == null || j.isEmpty) return null;
    try {
      return VfdProfile.parse(j);
    } catch (_) {
      return null;
    }
  }

  Future<void> saveProfile(String json) async {
    final p = VfdProfile.parse(json); // throws FormatException with a readable message
    await repo.setSetting('vfd_profile', json);
    await repo.setSetting('vfd_profile_name', p.name);
    _token = null;
  }

  Future<Map<String, String>> credentials(VfdProfile p) async => {for (final f in p.fields) f.key: await SecretStore.read('vfdc_${f.key}') ?? ''};

  Future<void> saveCredentials(Map<String, String> v) async {
    for (final e in v.entries) {
      await SecretStore.write('vfdc_${e.key}', e.value);
    }
    _token = null;
  }

  // ------------------------------------------------------------------ variables
  String _f(double v) => v.toStringAsFixed(2);

  Map<String, String> saleVars(Sale s) => {
        'sale.id': '${s.id}',
        'sale.number': s.number,
        'sale.date': DateFormat('yyyy-MM-dd').format(s.createdAt),
        'sale.time': DateFormat('HH:mm:ss').format(s.createdAt),
        'sale.datetime': DateFormat("yyyy-MM-dd'T'HH:mm:ss").format(s.createdAt),
        'sale.total': _f(s.totalIncl),
        'sale.totalExcl': _f(s.totalExcl),
        'sale.vat': _f(s.totalVat),
        'sale.payment': s.paymentType,
        'sale.customerName': s.customerName,
        'sale.customerTin': s.customerId,
        'sale.customerIdType': '${s.customerIdType}',
        'sale.mobile': s.mobile,
        'sale.znum': s.znum,
        'sale.itemCount': '${s.items.length}',
      };

  List<Map<String, String>> itemRows(Sale s) => [
        for (var i = 0; i < s.items.length; i++)
          () {
            final it = s.items[i];
            final sp = splitGross(it.amount, it.taxCode);
            return {
              'item.index': '${i + 1}',
              'item.name': it.name,
              'item.sku': it.sku,
              'item.qty': fmtQty(it.qty),
              'item.price': _f(it.unitPrice),
              'item.amount': _f(it.amount),
              'item.net': _f(sp.net),
              'item.vat': _f(sp.vat),
              'item.taxCode': it.taxCode,
              'item.traTaxCode': '${taxTraCode[it.taxCode] ?? 1}',
              'item.taxRate': ((taxRates[it.taxCode] ?? 0) * 100).toStringAsFixed(0),
            };
          }(),
      ];

  List<Map<String, String>> vatRows(Sale s) => [
        for (final v in s.vat) {'vat.code': v.code, 'vat.rate': ((taxRates[v.code] ?? 0) * 100).toStringAsFixed(0), 'vat.net': _f(v.net), 'vat.tax': _f(v.vat), 'vat.gross': _f(v.gross)},
      ];

  Future<Map<String, String>> _baseVars(VfdProfile p) async => {...await repo.allSettings(), ...await credentials(p)};

  // ------------------------------------------------------------------ HTTP helpers
  String _ct(String mode) => mode == 'xml' ? 'application/xml' : (mode == 'form' ? 'application/x-www-form-urlencoded' : 'application/json');

  String _url(VfdProfile p, Map<String, String> vars, Object? path) {
    final base = Tpl.render((p.raw['baseUrl'] as String), vars).replaceAll(RegExp(r'/+$'), '');
    final pa = Tpl.render('${path ?? ''}', vars);
    return pa.startsWith('http') ? pa : '$base${pa.startsWith('/') ? '' : '/'}$pa';
  }

  Future<http.Response> _send(String method, String url, Map<String, String> headers, String body) async {
    final req = http.Request(method.toUpperCase(), Uri.parse(url));
    req.headers.addAll(headers);
    if (body.isNotEmpty && method.toUpperCase() != 'GET') req.body = body;
    final streamed = await req.send().timeout(const Duration(seconds: 30));
    return http.Response.fromStream(streamed);
  }

  Map<String, String> _staticHeaders(VfdProfile p, Map<String, String> vars) {
    final h = <String, String>{'Accept': 'application/json, application/xml, */*'};
    ((p.raw['headers'] as Map?) ?? const {}).forEach((k, v) => h['$k'] = Tpl.render('$v', vars));
    return h;
  }

  Future<String> _login(VfdProfile p, Map<String, String> vars) async {
    if (_token != null && _exp.isAfter(DateTime.now())) return _token!;
    final a = p.sec('auth');
    final mode = (a['contentType'] as String?) ?? 'json';
    final h = _staticHeaders(p, vars)..['Content-Type'] = _ct(mode);
    final res = await _send((a['method'] as String?) ?? 'POST', _url(p, vars, a['path']), h, Tpl.render((a['body'] as String?) ?? '', vars, mode: mode));
    await _remember('LOGIN', res);
    final tok = extract(res.body, a['tokenPath'] as String?);
    if (tok == null || tok.isEmpty) throw StateError('Login failed (HTTP ${res.statusCode}): ${_clip(res.body, 300)}');
    _token = tok;
    final secs = int.tryParse(extract(res.body, a['expiresInPath'] as String?) ?? '') ?? 3000;
    _exp = DateTime.now().add(Duration(seconds: secs > 60 ? secs - 30 : secs));
    return tok;
  }

  Future<Map<String, String>> _authHeaders(VfdProfile p, Map<String, String> vars, String mode) async {
    final h = _staticHeaders(p, vars);
    final a = p.sec('auth');
    final type = (a['type'] as String?) ?? 'none';
    if (type == 'basic') {
      h['Authorization'] = 'Basic ${base64.encode(utf8.encode('${vars[a['userField'] ?? 'username'] ?? ''}:${vars[a['passField'] ?? 'password'] ?? ''}'))}';
    } else if (type == 'login') {
      final t = await _login(p, vars);
      h[(a['tokenHeader'] as String?) ?? 'Authorization'] = '${(a['tokenPrefix'] as String?) ?? 'Bearer '}$t';
    }
    h.putIfAbsent('Content-Type', () => _ct(mode));
    return h;
  }

  String _clip(String s, [int n = 1500]) => s.length > n ? '${s.substring(0, n)}...' : s;

  Future<void> _remember(String what, http.Response r) async => repo.setSetting('vfd_last_response', '$what  HTTP ${r.statusCode}\n${_clip(r.body)}');

  // ------------------------------------------------------------------ response mapping
  /// JSON dot-path (a.b.0.c) or "xml:TAG".
  static String? extract(String body, String? path) {
    if (path == null || path.isEmpty) return null;
    if (path.startsWith('xml:')) {
      final tag = path.substring(4);
      return RegExp('<$tag(?:\\s[^>]*)?>(.*?)</$tag>', dotAll: true).firstMatch(body)?.group(1)?.trim();
    }
    try {
      dynamic cur = jsonDecode(body);
      for (final part in path.split('.')) {
        if (cur is Map) {
          cur = cur[part];
        } else if (cur is List) {
          final i = int.tryParse(part);
          cur = (i != null && i < cur.length) ? cur[i] : null;
        } else {
          return null;
        }
        if (cur == null) return null;
      }
      return cur is String ? cur : (cur is num || cur is bool ? '$cur' : jsonEncode(cur));
    } catch (_) {
      return null;
    }
  }

  // ------------------------------------------------------------------ public API
  /// Sends one sale to the supplier. Network/auth problems -> retryLater (receipt stays queued).
  Future<TraResult> submit(Sale s) async {
    final p = await profile();
    if (p == null) return TraResult(ok: false, code: 'CFG', msg: 'No supplier profile imported', retryLater: true);
    try {
      final vars = {...await _baseVars(p), ...saleVars(s)};
      final rc = p.sec('receipt');
      final mode = (rc['contentType'] as String?) ?? 'json';
      final body = Tpl.render(rc['body'] as String, vars, loops: {'items': itemRows(s), 'vat': vatRows(s)}, mode: mode);
      final res = await _send((rc['method'] as String?) ?? 'POST', _url(p, vars, rc['path']), await _authHeaders(p, vars, mode), body);
      await _remember('RECEIPT ${s.number}', res);

      if (res.statusCode == 401 || res.statusCode == 403) {
        _token = null;
        return TraResult(ok: false, code: '${res.statusCode}', msg: 'Not authorised - check credentials', retryLater: true);
      }
      if (res.statusCode >= 500 || res.statusCode == 408 || res.statusCode == 429) {
        return TraResult(ok: false, code: '${res.statusCode}', msg: 'Supplier unavailable', retryLater: true);
      }
      final r = p.sec('response');
      final okPath = r['successPath'] as String?;
      bool ok;
      if (okPath != null && okPath.isNotEmpty) {
        final v = (extract(res.body, okPath) ?? '').toLowerCase();
        final allowed = ((r['successValues'] as List?) ?? const ['true', 'ok', 'success', '0', '1']).map((e) => '$e'.toLowerCase()).toList();
        ok = allowed.contains(v);
      } else {
        ok = res.statusCode >= 200 && res.statusCode < 300;
      }
      final msg = extract(res.body, r['messagePath'] as String?) ?? 'HTTP ${res.statusCode}';
      if (!ok) return TraResult(ok: false, code: '${res.statusCode}', msg: msg);
      return TraResult(
        ok: true,
        code: '${res.statusCode}',
        msg: msg,
        receiptNo: extract(res.body, r['receiptNoPath'] as String?) ?? '',
        verifyCode: extract(res.body, r['verificationCodePath'] as String?) ?? '',
        verifyUrl: extract(res.body, r['verifyUrlPath'] as String?) ?? '',
      );
    } on SocketException catch (e) {
      return TraResult(ok: false, code: 'NET', msg: 'Offline: ${e.message}', retryLater: true);
    } on TimeoutException {
      return TraResult(ok: false, code: 'NET', msg: 'Timed out', retryLater: true);
    } on http.ClientException catch (e) {
      return TraResult(ok: false, code: 'NET', msg: 'Network: ${e.message}', retryLater: true);
    } on StateError catch (e) {
      return TraResult(ok: false, code: 'AUTH', msg: e.message, retryLater: true);
    } catch (e) {
      return TraResult(ok: false, code: 'ERR', msg: '$e', retryLater: true);
    }
  }

  /// Logs in (if the profile uses login) and calls the optional "test" endpoint.
  Future<String> test() async {
    final p = await profile();
    if (p == null) return 'Import a supplier profile first.';
    try {
      final vars = await _baseVars(p);
      final missing = [for (final f in p.fields) if ((vars[f.key] ?? '').isEmpty) f.label];
      if (missing.isNotEmpty) return 'Fill in: ${missing.join(', ')}';
      final h = await _authHeaders(p, vars, 'json');
      final t = p.sec('test');
      if (t['path'] == null) return (p.sec('auth')['type'] == 'login') ? 'Login OK.' : 'Credentials saved. This profile has no test endpoint.';
      final res = await _send((t['method'] as String?) ?? 'GET', _url(p, vars, t['path']), h, '');
      await _remember('TEST', res);
      return 'HTTP ${res.statusCode} - ${res.statusCode < 300 ? 'connection OK' : 'check credentials/URL'}';
    } on SocketException catch (e) {
      return 'No connection: ${e.message}';
    } on TimeoutException {
      return 'Timed out';
    } catch (e) {
      return '$e';
    }
  }

  /// What would be sent for [s] (secrets masked) - lets you compare with the supplier's documentation.
  Future<String> preview(Sale s) async {
    final p = await profile();
    if (p == null) return 'Import a supplier profile first.';
    final vars = {...await _baseVars(p), ...saleVars(s)};
    final rc = p.sec('receipt');
    final mode = (rc['contentType'] as String?) ?? 'json';
    final body = Tpl.render(rc['body'] as String, vars, loops: {'items': itemRows(s), 'vat': vatRows(s)}, mode: mode);
    final secrets = [for (final f in p.fields) if (f.secret && (vars[f.key] ?? '').isNotEmpty) vars[f.key]!];
    String mask(String t) => secrets.fold(t, (a, e) => a.replaceAll(e, '****'));
    final hdr = _staticHeaders(p, vars).entries.map((e) => '${e.key}: ${e.value}').join('\n');
    return mask('${(rc['method'] as String?) ?? 'POST'} ${_url(p, vars, rc['path'])}\nContent-Type: ${_ct(mode)}\n$hdr\n\n$body');
  }
}
