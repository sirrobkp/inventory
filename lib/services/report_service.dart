import 'dart:io';

import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../data/models.dart';
import '../data/repo.dart';
import '../data/tax.dart';

String _n(num v) => NumberFormat('#,##0.00', 'en_US').format(v);
String _p(num v) => v < -0.004 ? '(${_n(-v)})' : _n(v); // accounting style negatives

String csv(List<List<Object?>> rows) => rows
    .map((r) => r.map((v) {
          final s = '${v ?? ''}';
          return s.contains(RegExp(r'[",\n]')) ? '"${s.replaceAll('"', '""')}"' : s;
        }).join(','))
    .join('\r\n');

class ReportService {
  ReportService(this.repo);
  final Repo repo;

  Future<Directory> exportsDir() async {
    final d = Directory('${(await getApplicationDocumentsDirectory()).path}/exports');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<File> _write(String name, String content) async => File('${(await exportsDir()).path}/$name').writeAsString(content);
  String _tag(DateTime a, DateTime b) => '${dayFmt.format(a)}_${dayFmt.format(b)}';

  // ------------------------------------------------------------------ CSV / XML
  Future<File> salesCsv(DateTime from, DateTime to) async {
    final s = await repo.salesBetween(dayFmt.format(from), dayFmt.format(to));
    final rows = <List<Object?>>[
      ['Date', 'Time', 'Receipt No (GC)', 'Daily counter', 'Verification code', 'Z number', 'Customer name', 'Customer TIN', 'Payment', 'Net (excl VAT)', 'VAT', 'Gross (incl VAT)', 'Fiscal', 'TRA status', 'TRA ack'],
      for (final e in s)
        [e.day, DateFormat('HH:mm:ss').format(e.createdAt), e.fiscal ? e.gc : '', e.fiscal ? e.dc : '', e.rctvnum, e.znum, e.customerName, e.customerId, e.paymentType, _n(e.totalExcl), _n(e.totalVat), _n(e.totalIncl), e.fiscal ? 'Y' : 'N', e.uploadStatus, e.ackMsg ?? ''],
    ];
    return _write('sales_schedule_${_tag(from, to)}.csv', csv(rows));
  }

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

  // ------------------------------------------------------------------ PDF helpers
  pw.Widget _h(String t) => pw.Padding(padding: const pw.EdgeInsets.only(top: 14, bottom: 5), child: pw.Text(t, style: pw.TextStyle(fontSize: 11.5, fontWeight: pw.FontWeight.bold)));

  pw.Widget _row(String l, String r, {bool bold = false, int indent = 0, bool topLine = false}) => pw.Container(
        decoration: topLine ? const pw.BoxDecoration(border: pw.Border(top: pw.BorderSide(width: 0.6))) : null,
        padding: pw.EdgeInsets.only(top: 3, bottom: 3, left: indent * 14.0),
        child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
          pw.Expanded(child: pw.Text(l, style: pw.TextStyle(fontSize: 10, fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal))),
          pw.Text(r, style: pw.TextStyle(fontSize: 10, fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal)),
        ]),
      );

  pw.Widget _head(Map<String, String> c, String title, String periodLine) {
    final name = (c['biz_name'] ?? '').isNotEmpty ? c['biz_name']! : (c['name'] ?? 'Business');
    return pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
      pw.Text(name, style: pw.TextStyle(fontSize: 17, fontWeight: pw.FontWeight.bold)),
      pw.Text('TIN: ${c['tin'] ?? '-'}    VRN: ${c['vrn'] ?? '-'}    Tax office: ${c['taxoffice'] ?? '-'}', style: const pw.TextStyle(fontSize: 8.5)),
      pw.SizedBox(height: 8),
      pw.Text(title, style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
      pw.Text('$periodLine    (Amounts in Tanzanian Shillings, TZS)', style: const pw.TextStyle(fontSize: 9)),
      pw.Divider(),
    ]);
  }

  // ------------------------------------------------- Financial statements (3 statements)
  /// Statement of Profit or Loss, Statement of Cash Flows and Statement of Financial Position (balance sheet) + notes.
  Future<File> financialStatementsPdf(DateTime from, DateTime to, Map<String, String> c) async {
    final f = dayFmt.format(from), t = dayFmt.format(to);
    final st = await repo.statement(f, t);
    final open = await repo.cumAsAt(dayFmt.format(from.subtract(const Duration(days: 1))));
    final close = await repo.cumAsAt(t);
    final products = await repo.products();
    final period = 'For the period ${DateFormat('d MMMM yyyy').format(from)} to ${DateFormat('d MMMM yyyy').format(to)}';
    final asAt = 'As at ${DateFormat('d MMMM yyyy').format(to)}';
    const margin = pw.EdgeInsets.fromLTRB(40, 36, 40, 36);
    final doc = pw.Document();

    // ---- 1. Income statement
    final revenue = close.salesNet - open.salesNet;
    final cogs = close.cogs - open.cogs;
    final grossProfit = revenue - cogs;
    final adj = close.adjustments - open.adjustments;
    final expenses = close.expNet - open.expNet;
    final netProfit = grossProfit + adj - expenses;
    doc.addPage(pw.MultiPage(pageFormat: PdfPageFormat.a4, margin: margin, build: (_) => [
          _head(c, 'STATEMENT OF PROFIT OR LOSS', period),
          _h('Revenue (excluding VAT)'),
          for (final code in taxLetters)
            if (st.salesByClass[code] != null) _row(taxNames[code]!, _p(st.salesByClass[code]!.net), indent: 1),
          _row('Total revenue', _p(revenue), bold: true, topLine: true),
          _h('Cost of sales'),
          _row('Cost of goods sold', _p(-cogs), indent: 1),
          _row('GROSS PROFIT', _p(grossProfit), bold: true, topLine: true),
          _h('Other items'),
          _row('Stock adjustments - gains / (losses)', _p(adj), indent: 1),
          _h('Operating expenses (excluding VAT)'),
          if (st.expensesByCat.isEmpty) _row('None recorded', _p(0), indent: 1),
          for (final e in st.expensesByCat.entries) _row(e.key, _p(-e.value), indent: 1),
          _row('Total operating expenses', _p(-expenses), bold: true, topLine: true),
          pw.SizedBox(height: 6),
          _row('NET PROFIT / (LOSS) BEFORE INCOME TAX', _p(netProfit), bold: true, topLine: true),
          pw.SizedBox(height: 10),
          pw.Text('No provision for income tax has been made in this statement.', style: const pw.TextStyle(fontSize: 8)),
        ]));

    // ---- 2. Statement of cash flows (direct method)
    final receipts = close.salesGross - open.salesGross;
    final toSuppliers = close.purchGross - open.purchGross;
    final forExpenses = close.expCash - open.expCash;
    final vatPaid = close.vatPaid - open.vatPaid;
    final opCash = receipts - toSuppliers - forExpenses - vatPaid;
    final assets = close.assetBuy - open.assetBuy;
    final capital = close.capital - open.capital;
    final loanIn = close.loanIn - open.loanIn;
    final loanOut = close.loanOut - open.loanOut;
    final drawings = close.drawings - open.drawings;
    final finCash = capital + loanIn - loanOut - drawings;
    final net = opCash - assets + finCash;
    doc.addPage(pw.MultiPage(pageFormat: PdfPageFormat.a4, margin: margin, build: (_) => [
          _head(c, 'STATEMENT OF CASH FLOWS', period),
          _h('Cash flows from operating activities'),
          _row('Cash received from customers (including VAT)', _p(receipts), indent: 1),
          _row('Cash paid to suppliers for stock (including VAT)', _p(-toSuppliers), indent: 1),
          _row('Cash paid for operating expenses (including VAT)', _p(-forExpenses), indent: 1),
          _row('VAT paid to TRA (net of refunds)', _p(-vatPaid), indent: 1),
          _row('Net cash from / (used in) operating activities', _p(opCash), bold: true, topLine: true),
          _h('Cash flows from investing activities'),
          _row('Purchase of equipment and fixed assets', _p(-assets), indent: 1),
          _row('Net cash used in investing activities', _p(-assets), bold: true, topLine: true),
          _h('Cash flows from financing activities'),
          _row('Capital introduced by owner(s)', _p(capital), indent: 1),
          _row('Loans received', _p(loanIn), indent: 1),
          _row('Loans repaid', _p(-loanOut), indent: 1),
          _row('Owner drawings', _p(-drawings), indent: 1),
          _row('Net cash from / (used in) financing activities', _p(finCash), bold: true, topLine: true),
          pw.SizedBox(height: 8),
          _row('NET INCREASE / (DECREASE) IN CASH', _p(net), bold: true, topLine: true),
          _row('Cash and cash equivalents at beginning of period', _p(open.cash), indent: 1),
          _row('CASH AND CASH EQUIVALENTS AT END OF PERIOD', _p(close.cash), bold: true, topLine: true),
          pw.SizedBox(height: 10),
          pw.Text('Prepared using the direct method. Cash and cash equivalents include cash, mobile money and card receipts held.', style: const pw.TextStyle(fontSize: 8)),
        ]));

    // ---- 3. Statement of financial position
    final vat = close.vatNet;
    final totalAssets = close.fixedAssets + close.inventory + (vat < 0 ? -vat : 0) + close.cash;
    final totalLiab = close.loans + (vat > 0 ? vat : 0);
    doc.addPage(pw.MultiPage(pageFormat: PdfPageFormat.a4, margin: margin, build: (_) => [
          _head(c, 'STATEMENT OF FINANCIAL POSITION (BALANCE SHEET)', asAt),
          _h('ASSETS'),
          pw.Text('Non-current assets', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
          _row('Equipment and fixed assets at cost', _p(close.assetBuy), indent: 1),
          _row('Less: accumulated depreciation', _p(-close.depreciation), indent: 1),
          _row('Net book value', _p(close.fixedAssets), bold: true, topLine: true),
          pw.SizedBox(height: 6),
          pw.Text('Current assets', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
          _row('Inventory (stock at cost)', _p(close.inventory), indent: 1),
          if (vat < 0) _row('VAT recoverable', _p(-vat), indent: 1),
          _row('Cash and cash equivalents', _p(close.cash), indent: 1),
          _row('Total current assets', _p(close.inventory + (vat < 0 ? -vat : 0) + close.cash), bold: true, topLine: true),
          pw.SizedBox(height: 4),
          _row('TOTAL ASSETS', _p(totalAssets), bold: true, topLine: true),
          _h('EQUITY AND LIABILITIES'),
          pw.Text("Owner's equity", style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
          _row('Capital introduced', _p(close.capital), indent: 1),
          _row('Opening stock introduced (at cost)', _p(close.openingStock), indent: 1),
          _row('Retained earnings / (accumulated loss) before tax', _p(close.profit), indent: 1),
          _row('Less: owner drawings', _p(-close.drawings), indent: 1),
          _row("Total owner's equity", _p(close.equity), bold: true, topLine: true),
          pw.SizedBox(height: 6),
          pw.Text('Liabilities', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
          _row('Loans outstanding', _p(close.loans), indent: 1),
          if (vat > 0) _row('VAT payable to TRA', _p(vat), indent: 1),
          _row('Total liabilities', _p(totalLiab), bold: true, topLine: true),
          pw.SizedBox(height: 4),
          _row('TOTAL EQUITY AND LIABILITIES', _p(close.equity + totalLiab), bold: true, topLine: true),
          if (close.imbalance.abs() > 0.5) ...[pw.SizedBox(height: 6), _row('Unreconciled difference (check ledger entries)', _p(close.imbalance))],
          pw.SizedBox(height: 28),
          pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
            pw.Text('Prepared by: ______________________', style: const pw.TextStyle(fontSize: 9)),
            pw.Text('Approved by: ______________________', style: const pw.TextStyle(fontSize: 9)),
            pw.Text('Date: ____________', style: const pw.TextStyle(fontSize: 9)),
          ]),
        ]));

    // ---- Notes
    doc.addPage(pw.MultiPage(pageFormat: PdfPageFormat.a4, margin: margin, build: (_) => [
          _head(c, 'NOTES TO THE FINANCIAL STATEMENTS', asAt),
          pw.Text(
              '1. Basis of preparation. These statements were prepared by management from the business records kept in Kibo Trade (fiscal sales receipts, stock purchases, expenses and capital entries). They are unaudited.\n'
              '2. Revenue is recognised when the fiscal receipt is issued and is shown excluding VAT. All sales are treated as settled at the point of sale.\n'
              '3. Inventory is valued at weighted-average cost. Stock adjustments (damage, counts, returns) are recognised in profit or loss.\n'
              '4. Purchases and expenses are treated as paid when recorded. Input VAT on purchases and expenses is offset against output VAT; the balance is shown as VAT payable or recoverable after VAT paid to TRA.\n'
              '5. Equipment is shown at cost less accumulated depreciation recorded under the expense category "Depreciation".\n'
              '6. No provision for income tax, accruals or receivables has been made.',
              style: const pw.TextStyle(fontSize: 9, lineSpacing: 3)),
          _h('Schedule: inventory on hand (current records)'),
          pw.TableHelper.fromTextArray(
            headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 8.5),
            cellStyle: const pw.TextStyle(fontSize: 8.5),
            headers: ['SKU', 'Product', 'Qty', 'Unit cost', 'Value'],
            data: [for (final p in products) [p.sku, p.name, fmtQty(p.stock), _n(p.cost), _n(p.stock * p.cost)]],
          ),
          pw.SizedBox(height: 6),
          _row('Total stock valuation (qty x cost)', _p(st.stockValue), bold: true),
        ]));

    final file = File('${(await exportsDir()).path}/financial_statements_${_tag(from, to)}.pdf');
    return file.writeAsBytes(await doc.save());
  }

  // ------------------------------------------------------------ VAT working paper
  Future<File> vatPdf(DateTime from, DateTime to, Map<String, String> c) async {
    final st = await repo.statement(dayFmt.format(from), dayFmt.format(to));
    final doc = pw.Document();
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(40),
      build: (_) => [
        _head(c, 'VAT RETURN - WORKING PAPER', 'For the period ${DateFormat('d MMM yyyy').format(from)} to ${DateFormat('d MMM yyyy').format(to)}'),
        _h('Output VAT (sales)'),
        for (final code in taxLetters)
          if (st.salesByClass[code] != null) ...[
            _row('${taxNames[code]} - net', _p(st.salesByClass[code]!.net), indent: 1),
            _row('${taxNames[code]} - VAT', _p(st.salesByClass[code]!.vat), indent: 1),
          ],
        _row('Total output VAT', _p(st.outputVat), bold: true, topLine: true),
        _h('Input VAT (purchases and expenses)'),
        _row('Stock purchases - net', _p(st.purchasesNet), indent: 1),
        _row('Stock purchases - VAT', _p(st.purchasesVat), indent: 1),
        _row('Expenses - net', _p(st.expensesNet), indent: 1),
        _row('Expenses - VAT', _p(st.expensesVat), indent: 1),
        _row('Total input VAT', _p(st.inputVat), bold: true, topLine: true),
        pw.SizedBox(height: 6),
        _row(st.vatPayable >= 0 ? 'NET VAT PAYABLE' : 'NET VAT REFUNDABLE / CARRY FORWARD', _p(st.vatPayable.abs()), bold: true, topLine: true),
        pw.SizedBox(height: 14),
        pw.Text('Input VAT is claimable only with valid supplier tax invoices / EFD receipts. Transcribe into the TRA Tax Online Services VAT return and attach the sales and purchases schedules (CSV).', style: const pw.TextStyle(fontSize: 8)),
      ],
    ));
    final file = File('${(await exportsDir()).path}/vat_working_paper_${_tag(from, to)}.pdf');
    return file.writeAsBytes(await doc.save());
  }
}
