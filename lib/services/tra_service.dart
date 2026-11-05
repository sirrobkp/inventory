import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';

import '../data/models.dart';
import '../data/repo.dart';
import '../data/tax.dart';

/// ---------------------------------------------------------------------------
/// TRA Virtual Fiscal Device (VFD) client for the EFDMS web API.
///
/// IMPORTANT: The XML layouts, header names, tax codes and endpoints below follow
/// the publicly known EFDMS "VFD API" flow (register -> token -> receipt / Z-report,
/// each payload signed with SHA1withRSA using the PFX certificate TRA issues you).
/// TRA only gives you the authoritative, current spec + test credentials during VFD
/// onboarding/type-approval. Validate every element against that document in the
/// TRA test environment BEFORE going live. See README "Before you go live".
/// ---------------------------------------------------------------------------

class TraResult {
  TraResult({required this.ok, this.code = '', this.msg = '', this.retryLater = false});
  final bool ok;
  final String code, msg;
  final bool retryLater; // auth/network: leave in queue, try again
}

String esc(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;').replaceAll("'", '&apos;');
String tag(String n, Object? v) => '<$n>${esc('${v ?? ''}')}</$n>';
String? pick(String xml, String name) => RegExp('<$name>(.*?)</$name>', dotAll: true).firstMatch(xml)?.group(1)?.trim();
String _f(double v) => v.toStringAsFixed(2);

class TraService {
  TraService(this.repo);
  final Repo repo;

  static const _ch = MethodChannel('kibo/signer');
  static const _sec = FlutterSecureStorage();
  static const defaultBase = 'https://virtual.tra.go.tz/efdmsRctApi'; // TEST environment - replace per TRA onboarding docs

  String? _token;
  DateTime _tokenExp = DateTime(2000);
  bool _busy = false;

  Future<String> _cfg(String k, [String d = '']) async => (await repo.getSetting(k)) ?? d;
  Future<String> get _base async => (await _cfg('tra_base', defaultBase)).replaceAll(RegExp(r'/+$'), '');
  Future<bool> get isRegistered async => (await _cfg('regid')).isNotEmpty;

  Future<String> get pfxPath async => '${(await getApplicationDocumentsDirectory()).path}/vfd_cert.pfx';
  Future<bool> get hasCert async => File(await pfxPath).exists();

  // ------------------------------------------------------------ signing (native)
  Future<Map<String, String>> _signArgs(String data) async => {
        'path': await pfxPath,
        'password': await _sec.read(key: 'pfx_password') ?? '',
        'data': data,
      };

  Future<String> _sign(String data) async => (await _ch.invokeMethod<String>('sign', await _signArgs(data))) ?? '';

  /// Serial number of the certificate (hex). Also validates the PFX password.
  Future<String> certSerialHex() async => (await _ch.invokeMethod<String>('serial', await _signArgs(''))) ?? '';

  /// Value for the Cert-Serial header (Base64 of the certificate serial).
  Future<String> _certSerialHeader() async => base64.encode(utf8.encode(await certSerialHex()));

  Future<String> _envelope(String inner) async => '<?xml version="1.0" encoding="UTF-8"?>\n<EFDMS>$inner<EFDMSSIGNATURE>${await _sign(inner)}</EFDMSSIGNATURE></EFDMS>';

  Future<http.Response> _post(String url, String body, Map<String, String> headers) => http.post(Uri.parse(url), headers: headers, body: body).timeout(const Duration(seconds: 30));

  // -------------------------------------------------------------- registration
  Future<TraResult> register({required String tin, required String certKey}) async {
    try {
      final inner = '<REGDATA>${tag('TIN', tin)}${tag('CERTKEY', certKey)}</REGDATA>';
      final res = await _post('${await _base}/api/vfdRegReq', await _envelope(inner), {
        'Content-Type': 'Application/xml',
        'Cert-Serial': await _certSerialHeader(),
        'Client': 'WEBAPI',
      });
      final x = res.body;
      final code = pick(x, 'ACKCODE') ?? '';
      final msg = pick(x, 'ACKMSG') ?? 'HTTP ${res.statusCode}';
      if (code != '0') return TraResult(ok: false, code: code, msg: msg);

      final map = <String, String?>{
        'regid': pick(x, 'REGID'),
        'serial': pick(x, 'SERIAL'),
        'uin': pick(x, 'UIN'),
        'tin': pick(x, 'TIN') ?? tin,
        'vrn': pick(x, 'VRN'),
        'name': pick(x, 'NAME'),
        'mobile': pick(x, 'MOBILE'),
        'address': pick(x, 'ADDRESS'),
        'street': pick(x, 'STREET'),
        'city': pick(x, 'CITY'),
        'region': pick(x, 'REGION'),
        'country': pick(x, 'COUNTRY'),
        'taxoffice': pick(x, 'TAXOFFICE'),
        'receiptcode': pick(x, 'RECEIPTCODE'),
        'username': pick(x, 'USERNAME'),
        'tokenpath': pick(x, 'TOKENPATH'),
        'cert_key': certKey,
        'reg_date': DateFormat('yyyy-MM-dd').format(DateTime.now()),
      };
      for (final e in map.entries) {
        if (e.value != null) await repo.setSetting(e.key, e.value!);
      }
      final pw = pick(x, 'PASSWORD');
      if (pw != null) await _sec.write(key: 'vfd_password', value: pw);
      _token = null;
      return TraResult(ok: true, code: code, msg: msg);
    } on PlatformException catch (e) {
      return TraResult(ok: false, code: 'SIGN', msg: 'Certificate error: ${e.message}');
    } catch (e) {
      return TraResult(ok: false, code: 'NET', msg: '$e', retryLater: true);
    }
  }

  // --------------------------------------------------------------------- token
  Future<String> _getToken() async {
    if (_token != null && _tokenExp.isAfter(DateTime.now())) return _token!;
    final origin = Uri.parse(await _base).origin;
    var path = await _cfg('tokenpath');
    if (!path.startsWith('/')) path = '/$path';
    final res = await http.post(Uri.parse('$origin$path'), body: {
      'username': await _cfg('username'),
      'password': await _sec.read(key: 'vfd_password') ?? '',
      'grant_type': 'password',
    }).timeout(const Duration(seconds: 30));
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    final tok = j['access_token'] as String?;
    if (tok == null) throw StateError('Token request failed: ${res.body}');
    _token = tok;
    _tokenExp = DateTime.now().add(Duration(seconds: ((j['expires_in'] as num?)?.toInt() ?? 600) - 30));
    return tok;
  }

  Future<Map<String, String>> _authHeaders(String routingKey) async => {
        'Content-Type': 'Application/xml',
        'Routing-Key': routingKey,
        'Cert-Serial': await _certSerialHeader(),
        'Authorization': 'Bearer ${await _getToken()}',
      };

  // ------------------------------------------------------------------ receipts
  String receiptXml(Sale s, Map<String, String> c) {
    final b = StringBuffer('<RCT>')
      ..write(tag('DATE', DateFormat('yyyy-MM-dd').format(s.createdAt)))
      ..write(tag('TIME', DateFormat('HH:mm:ss').format(s.createdAt)))
      ..write(tag('TIN', c['tin']))
      ..write(tag('REGID', c['regid']))
      ..write(tag('EFDSERIAL', c['serial']))
      ..write(tag('CUSTIDTYPE', s.customerIdType))
      ..write(tag('CUSTID', s.customerId))
      ..write(tag('CUSTNAME', s.customerName))
      ..write(tag('MOBILENUM', s.mobile))
      ..write(tag('RCTNUM', s.gc))
      ..write(tag('DC', s.dc))
      ..write(tag('GC', s.gc))
      ..write(tag('ZNUM', s.znum))
      ..write(tag('RCTVNUM', s.rctvnum))
      ..write('<TOTALS>${tag('TOTALTAXEXCL', _f(s.totalExcl))}${tag('TOTALTAXINCL', _f(s.totalIncl))}${tag('DISCOUNT', '0.00')}</TOTALS>')
      ..write('<PAYMENTS>${tag('PMTTYPE', s.paymentType)}${tag('PMTAMOUNT', _f(s.totalIncl))}</PAYMENTS>');
    for (final code in taxLetters) {
      final v = s.vat.where((e) => e.code == code).firstOrNull;
      b.write('<VATTOTALS>${tag('VATRATE', code)}${tag('NETTAMOUNT', _f(v?.net ?? 0))}${tag('TAXAMOUNT', _f(v?.vat ?? 0))}</VATTOTALS>');
    }
    b.write('<ITEMS>');
    for (final it in s.items) {
      b.write('<ITEM>${tag('ID', it.productId ?? it.sku)}${tag('DESC', it.name)}${tag('QTY', fmtQty(it.qty))}${tag('TAXCODE', taxTraCode[it.taxCode] ?? 1)}${tag('AMT', _f(it.amount))}</ITEM>');
    }
    b.write('</ITEMS></RCT>');
    return b.toString();
  }

  Future<TraResult> _uploadSale(Sale s) async {
    final c = await repo.allSettings();
    final body = await _envelope(receiptXml(s, c));
    final res = await _post('${await _base}/api/efdmsRctInfo', body, await _authHeaders('vfdrct'));
    if (res.statusCode == 401 || res.statusCode == 403) {
      _token = null;
      return TraResult(ok: false, code: '${res.statusCode}', msg: 'Not authorised - will retry', retryLater: true);
    }
    final code = pick(res.body, 'ACKCODE') ?? '';
    final msg = pick(res.body, 'ACKMSG') ?? 'HTTP ${res.statusCode}';
    return TraResult(ok: code == '0', code: code, msg: msg);
  }

  /// Uploads every queued fiscal receipt in GC order. Called right after each approved sale,
  /// on a timer, and when connectivity returns. Network failures leave receipts queued.
  Future<int> uploadPending() async {
    if (_busy || !await isRegistered || !await hasCert) return 0;
    _busy = true;
    var sent = 0;
    try {
      for (final s in await repo.queuedSales()) {
        try {
          final r = await _uploadSale(s);
          if (r.ok) {
            await repo.markUploaded(s.id!, r.code, r.msg);
            sent++;
          } else if (r.retryLater) {
            await repo.noteAttempt(s.id!, r.msg);
            break;
          } else {
            await repo.markFailed(s.id!, '${r.code}: ${r.msg}');
          }
        } on SocketException catch (e) {
          await repo.noteAttempt(s.id!, 'Offline: ${e.message}');
          break;
        } on TimeoutException {
          await repo.noteAttempt(s.id!, 'Timed out');
          break;
        } on http.ClientException catch (e) {
          await repo.noteAttempt(s.id!, 'Network: ${e.message}');
          break;
        } on PlatformException catch (e) {
          await repo.markFailed(s.id!, 'Signing: ${e.message}');
          break;
        } catch (e) {
          await repo.markFailed(s.id!, '$e');
        }
      }
    } finally {
      _busy = false;
    }
    return sent;
  }

  // ------------------------------------------------------------------ Z-report
  Future<String> zReportXml(String day) async {
    final c = await repo.allSettings();
    final t = await repo.dayTotals(day);
    final now = DateTime.now();
    final b = StringBuffer('<ZREPORT>')
      ..write(tag('DATE', day))
      ..write(tag('TIME', DateFormat('HH:mm:ss').format(now)))
      ..write('<HEADER>')
      ..write(tag('LINE', c['name'] ?? c['biz_name']))
      ..write(tag('LINE', c['address']))
      ..write(tag('LINE', c['city']))
      ..write(tag('LINE', c['country']))
      ..write('</HEADER>')
      ..write(tag('VRN', c['vrn']))
      ..write(tag('TIN', c['tin']))
      ..write(tag('TAXOFFICE', c['taxoffice']))
      ..write(tag('REGID', c['regid']))
      ..write(tag('ZNUMBER', day.replaceAll('-', '')))
      ..write(tag('EFDSERIAL', c['serial']))
      ..write(tag('REGISTRATIONDATE', c['reg_date']))
      ..write(tag('USER', c['uin']))
      ..write(tag('SIMIMSI', 'WEBAPI'))
      ..write('<TOTALS>')
      ..write(tag('DAILYTOTALAMOUNT', _f(t.gross)))
      ..write(tag('GROSS', _f(t.cumulativeGross)))
      ..write(tag('CORRECTIONS', '0.00'))
      ..write(tag('DISCOUNTS', '0.00'))
      ..write(tag('SURCHARGES', '0.00'))
      ..write(tag('TICKETSVOID', 0))
      ..write(tag('TICKETSVOIDTOTAL', '0.00'))
      ..write(tag('TICKETSFISCAL', t.count))
      ..write(tag('TICKETSNONFISCAL', 0))
      ..write('</TOTALS>');
    for (final code in taxLetters) {
      final v = t.vat[code];
      final rate = ((taxRates[code] ?? 0) * 100).toStringAsFixed(2);
      b.write('<VATTOTALS>${tag('VATRATE', '$code-$rate')}${tag('NETTAMOUNT', _f(v?.net ?? 0))}${tag('TAXAMOUNT', _f(v?.vat ?? 0))}</VATTOTALS>');
    }
    if (t.payments.isEmpty) {
      b.write('<PAYMENTS>${tag('PMTTYPE', 'CASH')}${tag('PMTAMOUNT', '0.00')}</PAYMENTS>');
    }
    for (final e in t.payments.entries) {
      b.write('<PAYMENTS>${tag('PMTTYPE', e.key)}${tag('PMTAMOUNT', _f(e.value))}</PAYMENTS>');
    }
    b.write('<CHANGES><CHANGENUM>0</CHANGENUM><CHANGETYPE>NONE</CHANGETYPE></CHANGES><ERRORS/>${tag('FWVERSION', '1.0.0')}${tag('FWCHECKSUM', 'KIBO')}</ZREPORT>');
    return b.toString();
  }

  /// Builds, stores and uploads the Z-report for [day]. Stores it locally even if upload fails.
  Future<TraResult> submitZReport(String day) async {
    final inner = await zReportXml(day);
    final znum = day.replaceAll('-', '');
    try {
      final body = await _envelope(inner);
      final res = await _post('${await _base}/api/efdmszreport', body, await _authHeaders('vfdzreport'));
      final code = pick(res.body, 'ACKCODE') ?? '';
      final msg = pick(res.body, 'ACKMSG') ?? 'HTTP ${res.statusCode}';
      final ok = code == '0';
      await repo.saveZ(day, znum, inner, ok ? 'submitted' : 'failed', '$code $msg');
      return TraResult(ok: ok, code: code, msg: msg);
    } catch (e) {
      await repo.saveZ(day, znum, inner, 'pending', '$e');
      return TraResult(ok: false, code: 'NET', msg: '$e', retryLater: true);
    }
  }

  /// Auto-submits Z-reports for every past trading day that has none yet.
  Future<void> submitDueZReports() async {
    if (!await isRegistered || !await hasCert) return;
    for (final d in await repo.daysNeedingZ()) {
      final r = await submitZReport(d);
      if (r.retryLater) break;
    }
  }
}
