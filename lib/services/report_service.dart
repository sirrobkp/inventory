import 'dart:io';

import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../data/models.dart';
import '../data/repo.dart';
import '../data/tax.dart';

String _n(num v) => NumberFormat('#,##0.00', 'en_US').format(v);

String csv(List<List<Object?>> rows) => rows
    .map((r) => r.map((v) {
          final s = '${v ?? ''}';
          return s.contains(RegExp(r'[",\n]')) ? '"${s.replaceAll('"', '""')}"' : s;
        }).join(','))
    .join('\r\n');

class ReportService {
  ReportService(this.repo);
  final Repo repo;

  Future<Directory> _dir() async {
    final d = Directory('${(await getApplicationDocumentsDirectory()).path}/exports');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<File> _write(String name, String content) async => File('${(await _dir()).path}/$name').writeAsString(content);

  String _tag(DateTime a, DateTime b) => '${dayFmt.format(a)}_${dayFmt.format(b)}';

  /// Receipt-level sales schedule (supports the output side of the VAT return).
  Future<File> salesCsv(DateTime from, DateTime to) async {
    final s = await repo.salesBetween(dayFmt.format(from), dayFmt.format(to));
    final rows = <List<Object?>>[
      ['Date', 'Time', 'Receipt No (GC)', 'Daily counter', 'Verification code', 'Z number', 'Customer name', 'Customer TIN', 'Payment', 'Net (excl VAT)', 'VAT', 'Gross (incl VAT)', 'Fiscal', 'TRA status', 'TRA ack'],
      for (final e in s)
        [e.day, DateFormat('HH:mm:ss').format(e.createdAt), e.fiscal ? e.gc : '', e.fiscal ? e.dc : '', e.rctvnum, e.znum, e.customerName, e.customerId, e.paymentType, _n(e.totalExcl), _n(e.totalVat), _n(e.totalIncl), e.fiscal ? 'Y' : 'N', e.uploadStatus, e.ackMsg ?? ''],
    ];
    return _write('sales_schedule_${_tag(from, to)}.csv', csv(rows));
  }

  /// Purchases schedule (input VAT claim support).
  Future<File> purchasesCsv(DateTime from, DateTime to) async {
    final f = dayFmt.format(from), t = dayFmt.format(to);
    final p = await repo.purchases(f, t);
    final e = await repo.expenses(f, t);
    final rows = <List<Object?>>[
      ['Date', 'Type', 'Supplier', 'Supplier TIN', 'Invoice / ref', 'Supplier EFD receipt', 'Description', 'Net', 'VAT (input)', 'Gross'],
      for (final x in p) [x.date, 'Stock purchase', x.supplier, x.supplierTin, x.invoiceNo, x.efdReceipt, x.product, _n(x.net), _n(x.vat), _n(x.gross)],
      for (final x in e) [x.date, 'Expense: ${x.category}', '', x.supplierTin, x.ref, '', x.description, _n(x.net), _n(x.vat), _n(x.gross)],
    ];
    return _write('purchases_schedule_${_tag(from, to)}.csv', csv(rows));
  }

  /// Z-reports exactly as built/submitted (XML), concatenated per day.
  Future<File> zXml(DateTime from, DateTime to) async {
    final z = await repo.zReports(dayFmt.format(from), dayFmt.format(to));
    final b = StringBuffer('<?xml version="1.0" encoding="UTF-8"?>\n<ZREPORTS>\n');
    for (final r in z) {
      b.writeln('<!-- ${r['day']} status=${r['status']} ${r['ack_msg']} -->');
      b.writeln(r['xml']);
    }
    b.write('</ZREPORTS>');
    return _write('z_reports_${_tag(from, to)}.xml', b.toString());
  }

  /// Income statement + VAT return working paper + stock valuation, one PDF.
  Future<File> statementsPdf(DateTime from, DateTime to, Map<String, String> c) async {
    final st = await repo.statement(dayFmt.format(from), dayFmt.format(to));
    final products = await repo.products();
    final doc = pw.Document();
    final bizName = (c['biz_name'] ?? '').isNotEmpty ? c['biz_name']! : (c['name'] ?? 'Business');
    final period = '${DateFormat('dd MMM yyyy').format(from)} - ${DateFormat('dd MMM yyyy').format(to)}';

    pw.Widget h(String t) => pw.Padding(padding: const pw.EdgeInsets.only(top: 16, bottom: 6), child: pw.Text(t, style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold)));
    pw.Widget row(String l, String r, {bool bold = false, bool indent = false}) => pw.Padding(
          padding: pw.EdgeInsets.only(top: 3, bottom: 3, left: indent ? 14 : 0),
          child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
            pw.Text(l, style: pw.TextStyle(fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal)),
            pw.Text(r, style: pw.TextStyle(fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal)),
          ]),
        );
    pw.Widget head(String title) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Text(bizName, style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
          pw.Text('TIN ${c['tin'] ?? '-'}   VRN ${c['vrn'] ?? '-'}   Tax office: ${c['taxoffice'] ?? '-'}', style: const pw.TextStyle(fontSize: 9)),
          pw.SizedBox(height: 6),
          pw.Text(title, style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
          pw.Text('Period: $period     Currency: TZS', style: const pw.TextStyle(fontSize: 9)),
          pw.Divider(),
        ]);

    // 1. Income statement
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(36),
      build: (_) => [
        head('Income Statement (Profit & Loss)'),
        h('Revenue (net of VAT)'),
        for (final code in taxLetters)
          if (st.salesByClass[code] != null) row(taxNames[code]!, _n(st.salesByClass[code]!.net), indent: true),
        row('Total revenue', _n(st.revenueNet), bold: true),
        h('Cost of sales'),
        row('Cost of goods sold (weighted average cost)', _n(st.cogs), indent: true),
        row('GROSS PROFIT', _n(st.grossProfit), bold: true),
        h('Operating expenses (net of VAT)'),
        if (st.expensesByCat.isEmpty) row('No expenses recorded', _n(0), indent: true),
        for (final e in st.expensesByCat.entries) row(e.key, _n(e.value), indent: true),
        row('Total operating expenses', _n(st.expensesNet), bold: true),
        pw.Divider(),
        row('NET PROFIT BEFORE INCOME TAX', _n(st.netProfit), bold: true),
        pw.SizedBox(height: 12),
        pw.Text('Receipts issued: ${st.receiptCount}', style: const pw.TextStyle(fontSize: 9)),
        h('Receipts by payment method'),
        for (final e in st.paymentTotals.entries) row(e.key, _n(e.value), indent: true),
      ],
    ));

    // 2. VAT working paper
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(36),
      build: (_) => [
        head('VAT Return - Working Paper'),
        h('Output VAT (sales)'),
        for (final code in taxLetters)
          if (st.salesByClass[code] != null) ...[
            row('${taxNames[code]}  - net', _n(st.salesByClass[code]!.net), indent: true),
            row('${taxNames[code]}  - VAT', _n(st.salesByClass[code]!.vat), indent: true),
          ],
        row('Total output VAT', _n(st.outputVat), bold: true),
        h('Input VAT (purchases and expenses)'),
        row('Stock purchases - net', _n(st.purchasesNet), indent: true),
        row('Stock purchases - VAT', _n(st.purchasesVat), indent: true),
        row('Expenses - net', _n(st.expensesNet), indent: true),
        row('Expenses - VAT', _n(st.expensesVat), indent: true),
        row('Total input VAT', _n(st.inputVat), bold: true),
        pw.Divider(),
        row(st.vatPayable >= 0 ? 'NET VAT PAYABLE' : 'NET VAT REFUNDABLE / CARRY FORWARD', _n(st.vatPayable.abs()), bold: true),
        pw.SizedBox(height: 14),
        pw.Text('Prepared from fiscal receipts issued by VFD serial ${c['serial'] ?? '-'}. Input VAT is claimable only with valid supplier tax invoices / EFD receipts. '
            'Transcribe into the TRA Tax Online Services VAT return and attach the sales and purchases schedules (CSV).', style: const pw.TextStyle(fontSize: 8)),
      ],
    ));

    // 3. Stock valuation
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(36),
      build: (_) => [
        head('Stock Valuation (as at ${DateFormat('dd MMM yyyy').format(DateTime.now())})'),
        pw.TableHelper.fromTextArray(
          headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9),
          cellStyle: const pw.TextStyle(fontSize: 9),
          headers: ['SKU', 'Product', 'Qty', 'Unit cost', 'Value'],
          data: [for (final p in products) [p.sku, p.name, fmtQty(p.stock), _n(p.cost), _n(p.stock * p.cost)]],
        ),
        pw.SizedBox(height: 8),
        row('TOTAL STOCK AT COST', _n(st.stockValue), bold: true),
      ],
    ));

    final f = File('${(await _dir()).path}/financial_statements_${_tag(from, to)}.pdf');
    return f.writeAsBytes(await doc.save());
  }
}
