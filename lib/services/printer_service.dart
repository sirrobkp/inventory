import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:permission_handler/permission_handler.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';
import 'package:printing/printing.dart';

import '../data/models.dart';
import '../data/tax.dart';

String _a(String? s) => (s ?? '').replaceAll(RegExp(r'[^\x20-\x7E]'), '?');
String _n(num v) => NumberFormat('#,##0.00', 'en_US').format(v);

class PrinterService {
  Future<bool> _perms() async {
    if (!Platform.isAndroid) return true; // iOS shows the Bluetooth prompt itself
    final r = await [Permission.bluetoothConnect, Permission.bluetoothScan].request();
    return r.values.every((s) => s.isGranted || s.isLimited);
  }

  Future<List<BluetoothInfo>> paired() async {
    if (!await _perms()) return [];
    return PrintBluetoothThermal.pairedBluetooths;
  }

  Future<bool> _ensure(String mac) async {
    if (mac.isEmpty || !await _perms()) return false;
    if (await PrintBluetoothThermal.connectionStatus) return true;
    return PrintBluetoothThermal.connect(macPrinterAddress: mac);
  }

  /// Prints a fiscal (or NON-FISCAL) receipt on a Bluetooth ESC/POS thermal printer.
  Future<String> printSale(Sale s, Map<String, String> c) async {
    final mac = c['printer_mac'] ?? '';
    if (mac.isEmpty) return 'No printer selected - choose one in Settings, or use PDF/Share.';
    if (!await _ensure(mac)) return 'Could not connect to printer. Is it on and paired?';
    final ok = await PrintBluetoothThermal.writeBytes(await _escpos(s, c));
    return ok ? 'Receipt sent to printer' : 'Printer rejected the data';
  }

  Future<List<int>> _escpos(Sale s, Map<String, String> c) async {
    final g = Generator(c['paper'] == '80' ? PaperSize.mm80 : PaperSize.mm58, await CapabilityProfile.load());
    final ctr = PosStyles(align: PosAlign.center);
    final bold = PosStyles(bold: true);
    List<int> b = [];
    b += g.reset();
    b += g.text(_a(c['biz_name']?.isNotEmpty == true ? c['biz_name'] : c['name']), styles: PosStyles(align: PosAlign.center, bold: true, height: PosTextSize.size2));
    for (final l in [c['biz_address'] ?? c['address'], c['biz_phone'] ?? c['mobile']]) {
      if ((l ?? '').isNotEmpty) b += g.text(_a(l), styles: ctr);
    }
    if (s.fiscal) {
      b += g.text('TIN: ${c['tin'] ?? ''}', styles: ctr);
      b += g.text('VRN: ${c['vrn'] ?? ''}', styles: ctr);
      b += g.text('SERIAL: ${c['serial'] ?? ''}  UIN: ${c['uin'] ?? ''}', styles: ctr);
      b += g.text('TAX OFFICE: ${_a(c['taxoffice'])}', styles: ctr);
    } else {
      b += g.text('*** NON-FISCAL - VFD NOT REGISTERED ***', styles: PosStyles(align: PosAlign.center, bold: true));
    }
    b += g.hr();
    b += g.row([PosColumn(text: 'Receipt No', width: 6), PosColumn(text: s.number, width: 6, styles: PosStyles(align: PosAlign.right))]);
    b += g.row([PosColumn(text: 'Date', width: 4), PosColumn(text: DateFormat('dd/MM/yyyy HH:mm').format(s.createdAt), width: 8, styles: PosStyles(align: PosAlign.right))]);
    if (s.customerName.isNotEmpty) b += g.text('Customer: ${_a(s.customerName)}');
    if (s.customerId.isNotEmpty) b += g.text('Customer TIN: ${s.customerId}');
    b += g.hr();
    for (final i in s.items) {
      b += g.text('${_a(i.name)} [${i.taxCode}]');
      b += g.row([
        PosColumn(text: '${fmtQty(i.qty)} x ${_n(i.unitPrice)}', width: 7),
        PosColumn(text: _n(i.amount), width: 5, styles: PosStyles(align: PosAlign.right)),
      ]);
    }
    b += g.hr();
    b += g.row([PosColumn(text: 'Total excl. VAT', width: 7), PosColumn(text: _n(s.totalExcl), width: 5, styles: PosStyles(align: PosAlign.right))]);
    for (final v in s.vat) {
      b += g.row([PosColumn(text: 'VAT ${v.code} (${((taxRates[v.code] ?? 0) * 100).toStringAsFixed(0)}%)', width: 7), PosColumn(text: _n(v.vat), width: 5, styles: PosStyles(align: PosAlign.right))]);
    }
    b += g.row([PosColumn(text: 'TOTAL TZS', width: 6, styles: bold), PosColumn(text: _n(s.totalIncl), width: 6, styles: PosStyles(align: PosAlign.right, bold: true))]);
    b += g.text('Paid by: ${s.paymentType}');
    if (s.fiscal) {
      b += g.hr();
      b += g.text('RECEIPT VERIFICATION CODE', styles: ctr);
      b += g.text(s.rctvnum, styles: PosStyles(align: PosAlign.center, bold: true, height: PosTextSize.size2));
      b += g.qrcode(s.verifyUrl);
      b += g.text('verify.tra.go.tz', styles: ctr);
    }
    if ((c['receipt_footer'] ?? '').isNotEmpty) b += g.text(_a(c['receipt_footer']), styles: ctr);
    b += g.feed(3);
    b += g.cut();
    return b;
  }

  /// PDF receipt (80mm roll) - opens Android's print/share dialog (works for Wi-Fi, USB or any print service).
  Future<void> printPdf(Sale s, Map<String, String> c) => Printing.layoutPdf(name: 'Receipt ${s.number}', onLayout: (_) => pdfBytes(s, c));

  Future<Uint8List> pdfBytes(Sale s, Map<String, String> c) async {
    final doc = pw.Document();
    pw.Widget line(String l, String r, {bool bold = false}) => pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
          pw.Text(l, style: pw.TextStyle(fontSize: 8, fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal)),
          pw.Text(r, style: pw.TextStyle(fontSize: 8, fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal)),
        ]);
    pw.Widget center(String t, {double size = 8, bool bold = false}) => pw.Center(child: pw.Text(_a(t), style: pw.TextStyle(fontSize: size, fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal)));
    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat.roll80,
      margin: const pw.EdgeInsets.all(10),
      build: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
        center(c['biz_name']?.isNotEmpty == true ? c['biz_name']! : (c['name'] ?? ''), size: 12, bold: true),
        center(c['biz_address'] ?? c['address'] ?? ''),
        if (s.fiscal) ...[center('TIN: ${c['tin'] ?? ''}   VRN: ${c['vrn'] ?? ''}'), center('SERIAL: ${c['serial'] ?? ''}  UIN: ${c['uin'] ?? ''}'), center('TAX OFFICE: ${c['taxoffice'] ?? ''}')] else center('*** NON-FISCAL - VFD NOT REGISTERED ***', bold: true),
        pw.Divider(),
        line('Receipt No', s.number),
        line('Date', DateFormat('dd/MM/yyyy HH:mm').format(s.createdAt)),
        if (s.customerName.isNotEmpty) line('Customer', _a(s.customerName)),
        if (s.customerId.isNotEmpty) line('Customer TIN', s.customerId),
        pw.Divider(),
        for (final i in s.items) ...[pw.Text('${_a(i.name)} [${i.taxCode}]', style: const pw.TextStyle(fontSize: 8)), line('${fmtQty(i.qty)} x ${_n(i.unitPrice)}', _n(i.amount))],
        pw.Divider(),
        line('Total excl. VAT', _n(s.totalExcl)),
        for (final v in s.vat) line('VAT ${v.code} (${((taxRates[v.code] ?? 0) * 100).toStringAsFixed(0)}%)', _n(v.vat)),
        line('TOTAL TZS', _n(s.totalIncl), bold: true),
        line('Paid by', s.paymentType),
        if (s.fiscal) ...[
          pw.Divider(),
          center('RECEIPT VERIFICATION CODE'),
          center(s.rctvnum, size: 12, bold: true),
          pw.SizedBox(height: 4),
          pw.Center(child: pw.BarcodeWidget(barcode: pw.Barcode.qrCode(), data: s.verifyUrl, width: 90, height: 90)),
          center('verify.tra.go.tz'),
        ],
        if ((c['receipt_footer'] ?? '').isNotEmpty) center(c['receipt_footer']!),
      ]),
    ));
    return doc.save();
  }
}
