import 'dart:io' show File, Platform;
import 'dart:typed_data';

import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:flutter/widgets.dart' show BuildContext;
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:permission_handler/permission_handler.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';
import 'package:printing/printing.dart';

import '../data/models.dart';
import '../data/platform_info.dart';
import '../data/tax.dart';
import 'share_helper.dart';

String _a(String? s) => (s ?? '').replaceAll(RegExp(r'[^\x20-\x7E]'), '?');
final _nf = NumberFormat('#,##0.00', 'en_US');
String _n(num v) => _nf.format(v);

/// One line of the receipt. Every line is already padded to the paper width, so the thermal printer and the
/// PDF (monospace font) print identical columns - the way TRA/EFD receipts look.
class RLine {
  const RLine(this.text, {this.bold = false, this.qr = false});
  final String text;
  final bool bold, qr;
}

const _idTypes = {1: 'TIN', 2: 'DRIVING LICENSE', 3: 'VOTERS NUMBER', 4: 'PASSPORT', 5: 'NATIONAL ID', 6: 'NIL'};

/// Builds a TRA-style fiscal receipt as fixed-width text of [w] columns (32 = 58 mm, 48 = 80 mm).
List<RLine> buildReceipt(Sale s, Map<String, String> c, int w) {
  final out = <RLine>[];
  List<String> wrap(String t) {
    final lines = <String>[];
    var cur = '';
    for (var word in t.split(RegExp(r'\s+'))) {
      while (word.length > w) {
        if (cur.isNotEmpty) {
          lines.add(cur);
          cur = '';
        }
        lines.add(word.substring(0, w));
        word = word.substring(w);
      }
      if (cur.isEmpty) {
        cur = word;
      } else if (cur.length + 1 + word.length <= w) {
        cur = '$cur $word';
      } else {
        lines.add(cur);
        cur = word;
      }
    }
    if (cur.isNotEmpty) lines.add(cur);
    return lines;
  }

  void ctr(String t, {bool bold = false}) {
    for (final l in wrap(_a(t))) {
      out.add(RLine(' ' * ((w - l.length) ~/ 2) + l, bold: bold));
    }
  }

  void left(String t, {bool bold = false}) {
    for (final l in wrap(_a(t))) {
      out.add(RLine(l, bold: bold));
    }
  }

  void lr(String l, String r, {bool bold = false}) {
    l = _a(l);
    final room = w - r.length - 1;
    if (l.length > room) l = l.substring(0, room < 0 ? 0 : room);
    out.add(RLine(l + ' ' * (w - l.length - r.length) + r, bold: bold));
  }

  void hr() => out.add(RLine('-' * w));
  String rjust(String t, int n) => t.length >= n ? t : ' ' * (n - t.length) + t;

  final name = (c['biz_name'] ?? '').isNotEmpty ? c['biz_name']! : (c['name'] ?? '');
  final legal = s.fiscal && (s.uploaded || s.rctvnum.isNotEmpty);

  ctr(name.toUpperCase(), bold: true);
  if (legal) {
    ctr('*** START OF LEGAL RECEIPT ***', bold: true);
  } else if (s.fiscal) {
    ctr('PROVISIONAL - AWAITING FISCALISATION', bold: true);
  } else {
    ctr('*** NON-FISCAL - VFD NOT REGISTERED ***', bold: true);
  }
  final addr = (c['biz_address'] ?? '').isNotEmpty ? c['biz_address']! : [c['address'], c['street'], c['city'], c['country']].where((e) => (e ?? '').isNotEmpty).join(', ');
  if (addr.isNotEmpty) ctr(addr);
  final phone = (c['biz_phone'] ?? '').isNotEmpty ? c['biz_phone']! : (c['mobile'] ?? '');
  if (phone.isNotEmpty) ctr('MOBILE: $phone');
  if (s.fiscal) {
    left('TIN: ${c['tin'] ?? ''}');
    if ((c['vrn'] ?? '').isNotEmpty) left('VRN: ${c['vrn']}');
    if ((c['serial'] ?? '').isNotEmpty) left('SERIAL NUMBER: ${c['serial']}');
    if ((c['uin'] ?? '').isNotEmpty) left('UIN: ${c['uin']}');
    if ((c['taxoffice'] ?? '').isNotEmpty) left('TAX OFFICE: ${c['taxoffice']}');
  }
  hr();
  if (s.customerName.isNotEmpty || s.customerId.isNotEmpty || s.mobile.isNotEmpty) {
    left('CUSTOMER NAME: ${s.customerName.isEmpty ? 'NIL' : s.customerName}');
    left('CUSTOMER ID TYPE: ${_idTypes[s.customerIdType] ?? 'NIL'}');
    left('CUSTOMER ID: ${s.customerId.isEmpty ? 'NIL' : s.customerId}');
    if (s.mobile.isNotEmpty) left('CUSTOMER MOBILE: ${s.mobile}');
    hr();
  }
  lr('RECEIPT NUMBER:', s.number);
  lr('Z NUMBER:', s.znum);
  lr('DATE: ${DateFormat('yyyy-MM-dd').format(s.createdAt)}', 'TIME: ${DateFormat('HH:mm:ss').format(s.createdAt)}');
  hr();
  lr('DESCRIPTION', 'AMOUNT', bold: true);
  for (final i in s.items) {
    left(i.name.toUpperCase());
    lr('  ${fmtQty(i.qty)} x ${_n(i.unitPrice)}', '${_n(i.amount)} ${i.taxCode}');
  }
  hr();
  lr('TOTAL EXCL OF TAX:', _n(s.totalExcl));
  lr('TOTAL TAX:', _n(s.totalVat));
  lr('TOTAL INCL OF TAX:', _n(s.totalIncl), bold: true);
  hr();
  // tax table: rate | turnover (excl) | tax amount
  final c1 = 9, c3 = (w - 9) ~/ 2, c2 = w - 9 - c3;
  out.add(RLine('TAX RATE'.padRight(c1) + rjust('TURNOVER', c2) + rjust('TAX', c3), bold: true));
  for (final v in s.vat) {
    out.add(RLine('${v.code}-${((taxRates[v.code] ?? 0) * 100).toStringAsFixed(2)}%'.padRight(c1) + rjust(_n(v.net), c2) + rjust(_n(v.vat), c3)));
  }
  hr();
  lr('PAYMENT:', s.paymentType);
  hr();
  if (legal) {
    ctr('*** END OF LEGAL RECEIPT ***', bold: true);
    if (s.rctvnum.isNotEmpty) {
      ctr('RECEIPT VERIFICATION CODE');
      ctr(s.rctvnum, bold: true);
    }
    if (s.verifyUrl.isNotEmpty) out.add(const RLine('', qr: true));
    ctr('verify.tra.go.tz');
  }
  if ((c['receipt_footer'] ?? '').isNotEmpty) {
    out.add(const RLine(''));
    ctr(c['receipt_footer']!);
  }
  return out;
}

class PrinterService {
  Future<bool> _perms() async {
    if (!Platform.isAndroid) return true; // iOS shows the Bluetooth prompt itself
    final r = await [Permission.bluetoothConnect, Permission.bluetoothScan].request();
    return r.values.every((s) => s.isGranted || s.isLimited);
  }

  Future<List<BluetoothInfo>> paired() async {
    if (isDesktop) return [];
    if (!await _perms()) return [];
    return PrintBluetoothThermal.pairedBluetooths;
  }

  Future<bool> _ensure(String mac) async {
    if (mac.isEmpty || !await _perms()) return false;
    if (await PrintBluetoothThermal.connectionStatus) return true;
    return PrintBluetoothThermal.connect(macPrinterAddress: mac);
  }

  int _cols(Map<String, String> c) => c['paper'] == '80' ? 48 : 32;

  // ------------------------------------------------------------ thermal (ESC/POS)
  /// Prints on a Bluetooth ESC/POS thermal printer: 58 mm = 32 columns, 80 mm = 48 columns, monospace Font A.
  Future<String> printSale(Sale s, Map<String, String> c) async {
    if (isDesktop) {
      await printPdf(s, c); // desktop: system print dialog (choose the thermal/receipt printer and paper there)
      return 'Print dialog opened';
    }
    final mac = c['printer_mac'] ?? '';
    if (mac.isEmpty) return 'No printer selected - choose one in Settings, or use PDF/Share.';
    if (!await _ensure(mac)) return 'Could not connect to printer. Is it on and paired?';
    final ok = await PrintBluetoothThermal.writeBytes(await _escpos(s, c));
    return ok ? 'Receipt sent to printer' : 'Printer rejected the data';
  }

  Future<List<int>> _escpos(Sale s, Map<String, String> c) async {
    final g = Generator(c['paper'] == '80' ? PaperSize.mm80 : PaperSize.mm58, await CapabilityProfile.load());
    List<int> b = [];
    b += g.reset();
    for (final l in buildReceipt(s, c, _cols(c))) {
      if (l.qr) {
        b += g.qrcode(s.verifyUrl);
      } else {
        b += g.text(l.text, styles: PosStyles(bold: l.bold, align: PosAlign.left, fontType: PosFontType.fontA));
      }
    }
    b += g.feed(3);
    b += g.cut();
    return b;
  }

  // ------------------------------------------------------------------------- PDF
  static const _a4Cols = 48;

  /// Receipt PDF laid out for [format]: a narrow roll (thermal) gets the compact 32/48-column layout at the roll's
  /// own width; anything wider (A4/Letter) gets the same receipt scaled up to fill the page width.
  Future<Uint8List> pdfBytes(Sale s, Map<String, String> c, {PdfPageFormat? format}) async {
    final fmt = format ?? PdfPageFormat.a4;
    final thermal = fmt.width < 100 * PdfPageFormat.mm;
    final cols = thermal ? (fmt.width >= 190 ? 48 : 32) : _a4Cols;
    final margin = thermal ? 5.0 : 40.0;
    final avail = fmt.width - 2 * margin;
    var fs = avail / (cols * 0.6); // Courier glyph width = 0.6 em
    if (!thermal && fs > 16) fs = 16;
    final lines = buildReceipt(s, c, cols);
    final regular = pw.Font.courier(), boldF = pw.Font.courierBold();
    final qrSize = thermal ? avail * 0.55 : 150.0;

    pw.Widget body() => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.center,
          children: [
            pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              for (final l in lines)
                if (l.qr)
                  pw.SizedBox(
                    width: cols * 0.6 * fs,
                    child: pw.Center(child: pw.Padding(padding: const pw.EdgeInsets.symmetric(vertical: 6), child: pw.BarcodeWidget(barcode: pw.Barcode.qrCode(), data: s.verifyUrl, width: qrSize, height: qrSize))),
                  )
                else
                  pw.Text(l.text.isEmpty ? ' ' : l.text, softWrap: false, style: pw.TextStyle(font: l.bold ? boldF : regular, fontSize: fs, lineSpacing: 1.5)),
            ]),
          ],
        );

    final doc = pw.Document();
    if (thermal) {
      // roll paper: fixed width, height grows with the content
      doc.addPage(pw.Page(pageFormat: PdfPageFormat(fmt.width, double.infinity, marginAll: margin), build: (_) => body()));
    } else {
      doc.addPage(pw.MultiPage(pageFormat: fmt.copyWith(marginLeft: margin, marginRight: margin, marginTop: 40, marginBottom: 40), build: (_) => [body()]));
    }
    return doc.save();
  }

  /// Full-page A4 PDF saved to a file and handed to the share sheet (iOS-safe anchor).
  Future<void> sharePdf(BuildContext context, Sale s, Map<String, String> c) async {
    final bytes = await pdfBytes(s, c, format: PdfPageFormat.a4);
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/receipt_${s.number}.pdf');
    await f.writeAsBytes(bytes, flush: true);
    if (!context.mounted) return;
    await shareFile(context, f.path);
  }

  /// System print dialog (AirPrint / Wi-Fi / USB / roll printers). The layout follows the paper the user picks.
  Future<void> printPdf(Sale s, Map<String, String> c) => Printing.layoutPdf(name: 'Receipt ${s.number}', onLayout: (format) => pdfBytes(s, c, format: format));
}
