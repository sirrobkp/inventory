import 'dart:io';
import 'dart:math' as math;

import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../data/fixed_assets.dart';
import '../data/models.dart';
import '../data/repo.dart';
import '../data/tax.dart';

String _n(num v) => NumberFormat('#,##0.00', 'en_US').format(v);
final _wf = NumberFormat('#,##0', 'en_US');
String _p(num v) { final r = v.round(); return r < 0 ? '(${_wf.format(-r)})' : _wf.format(r); } // whole shillings, accounting negatives
String _pd(num v) => v < -0.004 ? '(${_n(-v)})' : _n(v); // 2 decimals

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

  // ------------------------------------------------- Financial statements pack
  static const _financeCat = 'Bank charges & interest';
  static const _adminOrder = ['Audit & other professional fees', 'Travelling', 'Cleaning', 'Communication', 'Rent', 'Legal & other professional fees', 'Tender expenses', 'Office meals', 'Printing & stationery', 'Repair & maintenance', 'Salary & wages', 'Security', 'Water & electricity'];

  pw.Widget _para(String t, {double size = 9.5, bool bold = false}) => pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 7),
      child: pw.Text(t, textAlign: pw.TextAlign.justify, style: pw.TextStyle(fontSize: size, lineSpacing: 2.5, fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal)));

  pw.Widget _title(String t) => pw.Padding(padding: const pw.EdgeInsets.only(bottom: 10), child: pw.Text(t, style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold)));

  pw.Widget _table(List<String> headers, List<List<String>> data) => pw.TableHelper.fromTextArray(
        headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 8),
        cellStyle: const pw.TextStyle(fontSize: 8),
        headers: headers,
        data: data,
        cellAlignments: {for (var i = 1; i < headers.length; i++) i: pw.Alignment.centerRight},
        headerAlignments: {for (var i = 1; i < headers.length; i++) i: pw.Alignment.centerRight},
      );

  /// Full set following the structure of a Tanzanian IFRS-for-SMEs audited pack:
  /// company information, directors' report, responsibilities, head-of-finance declaration, auditor's report (placeholder),
  /// statements of financial position, profit or loss, changes in equity, cash flows (indirect) and notes 1-16.
  Future<File> financialStatementsPdf(DateTime from, DateTime to, Map<String, String> c, double taxRate) async {
    final per = await repo.period(from, to, taxRate);
    final st = per.st, o = per.open, k = per.close;
    final products = await repo.products();
    final staff = (await repo.employees()).length;

    final company = (c['biz_name'] ?? '').isNotEmpty ? c['biz_name']! : ((c['name'] ?? '').isNotEmpty ? c['name']! : 'THE ENTITY');
    final isCo = (c['entity_type'] ?? 'company') == 'company';
    final owners = isCo ? 'directors' : 'proprietor';
    final fullYear = from.month == 1 && from.day == 1 && to.month == 12 && to.day == 31;
    final endTxt = DateFormat('d MMMM yyyy').format(to).toUpperCase();
    final periodTitle = fullYear ? 'FOR THE YEAR ENDED $endTxt' : 'FOR THE PERIOD ${DateFormat('d MMMM yyyy').format(from).toUpperCase()} TO $endTxt';
    final unit = fullYear ? 'year' : 'period';
    final dirLines = (c['directors'] ?? '').split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    final firstDir = dirLines.isEmpty ? '' : dirLines.first.split(',').first.trim();

    // ---- figures
    final revenue = k.salesNet - o.salesNet;
    final cogs = k.cogs - o.cogs;
    final gross = revenue - cogs;
    final adj = k.adjustments - o.adjustments;
    final finance = st.expensesByCat[_financeCat] ?? 0;
    final admin = st.expensesNet - finance;
    final dep = k.depreciation - o.depreciation;
    final pbt = gross + adj - admin - finance - dep;
    final tax = k.tax - o.tax;
    final pat = pbt - tax;
    final capOpen = o.capital + o.openingStock, capClose = k.capital + k.openingStock;
    final reOpen = o.profitAfterTax - o.drawings;
    final drawYear = k.drawings - o.drawings;
    final reClose = reOpen + pat - drawYear;
    final vatRecv = k.vatNet < 0 ? -k.vatNet : 0.0;
    final vatPay = k.vatNet > 0 ? k.vatNet : 0.0;
    final prepaidTax = k.netTax < 0 ? -k.netTax : 0.0;
    final taxPayable = k.netTax > 0 ? k.netTax : 0.0;
    final recvTotal = k.receivables + vatRecv;
    final payTotal = k.tradePayables + k.accrued + vatPay;
    final currentAssets = k.inventory + recvTotal + prepaidTax + k.cash;
    final totalAssets = k.fixedAssets + currentAssets;
    final totalEquity = capClose + reClose;
    final currentLiab = k.loans + payTotal + taxPayable;
    // cash flow (indirect)
    final dInv = (k.inventory - o.inventory) - (k.openingStock - o.openingStock); // opening stock introduced is non-cash
    final dVat = k.vatNet - o.vatNet;
    final payChange = (k.tradePayables - o.tradePayables) + (k.accrued - o.accrued) + dVat;
    final recChange = k.receivables - o.receivables;
    final adjusted = pbt + dep;
    final generated = adjusted - dInv - recChange + payChange;
    final taxPaidYear = k.taxPaid - o.taxPaid;
    final opCash = generated - taxPaidYear;
    final capex = k.assetCost - o.assetCost;
    final finCash = (k.capital - o.capital) + (k.loanIn - o.loanIn) - (k.loanOut - o.loanOut) - drawYear;
    final netCash = opCash - capex + finCash;

    final doc = pw.Document();
    const margin = pw.EdgeInsets.fromLTRB(44, 40, 44, 40);

    // ---- cover
    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(50),
      build: (_) => pw.Center(
        child: pw.Column(mainAxisAlignment: pw.MainAxisAlignment.center, children: [
          pw.Text(company.toUpperCase(), textAlign: pw.TextAlign.center, style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 22),
          pw.Text('FINANCIAL STATEMENTS', style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 6),
          pw.Text(periodTitle, style: const pw.TextStyle(fontSize: 12)),
          pw.SizedBox(height: 40),
          pw.Text('Prepared by management - not yet audited', style: const pw.TextStyle(fontSize: 10)),
          pw.SizedBox(height: 4),
          pw.Text('TIN: ${c['tin'] ?? '-'}', style: const pw.TextStyle(fontSize: 10)),
          if ((c['auditor_name'] ?? '').isNotEmpty) ...[pw.SizedBox(height: 60), pw.Text(c['auditor_name']!, style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)), pw.Text(c['auditor_address'] ?? '', style: const pw.TextStyle(fontSize: 9))],
        ]),
      ),
    ));

    final w = <pw.Widget>[];
    void section(List<pw.Widget> children) {
      if (w.isNotEmpty) w.add(pw.NewPage());
      w.addAll(children);
    }

    // ---- contents
    section([
      _title('TABLE OF CONTENTS'),
      for (final t in ['Company information', isCo ? "Directors' report" : "Proprietor's report", isCo ? "Statement of directors' responsibilities" : "Statement of proprietor's responsibilities", 'Declaration of the head of finance', "Independent auditor's report", 'Statement of financial position', 'Statement of profit or loss', 'Statement of changes in equity', 'Statement of cash flows', 'Notes to the financial statements', 'Schedule of inventory on hand'])
        pw.Padding(padding: const pw.EdgeInsets.symmetric(vertical: 4), child: pw.Text(t, style: const pw.TextStyle(fontSize: 11))),
    ]);

    // ---- company information
    section([
      _title('COMPANY INFORMATION'),
      _h('REGISTRATION'),
      _para(isCo
          ? "$company is a company limited by shares registered under the Companies Act, 2002 of Tanzania.${(c['reg_no'] ?? '').isNotEmpty ? ' Certificate of incorporation no. ${c['reg_no']}.' : ''} The company is registered with the Tanzania Revenue Authority (TIN ${c['tin'] ?? '-'}${(c['vrn'] ?? '').isNotEmpty ? ', VRN ${c['vrn']}' : ''})."
          : "$company is a business registered with the Tanzania Revenue Authority (TIN ${c['tin'] ?? '-'}${(c['vrn'] ?? '').isNotEmpty ? ', VRN ${c['vrn']}' : ''})."),
      _h('CONTACT ADDRESS'),
      _para([company, c['biz_address'] ?? c['address'] ?? '', if ((c['po_box'] ?? '').isNotEmpty) 'P.O. Box ${c['po_box']}', 'Tanzania', if ((c['biz_phone'] ?? '').isNotEmpty) 'Tel: ${c['biz_phone']}'].where((e) => e.isNotEmpty).join('\n')),
      _h('AUDITORS'),
      _para((c['auditor_name'] ?? '').isNotEmpty ? '${c['auditor_name']}\nCertified Public Accountants\n${c['auditor_address'] ?? ''}' : 'To be appointed.'),
    ]);

    // ---- directors' report
    final dirTable = dirLines.isEmpty
        ? _para('Not recorded - add the names in Settings > Company profile.')
        : _table(['S/N', 'NAME', 'NATIONALITY'], [for (var i = 0; i < dirLines.length; i++) ['${i + 1}', dirLines[i].split(',').first.trim(), dirLines[i].contains(',') ? dirLines[i].split(',').sublist(1).join(',').trim() : '']]);
    section([
      _title(isCo ? "DIRECTORS' REPORT FOR THE ${unit.toUpperCase()} ${periodTitle.replaceFirst('FOR THE ${unit.toUpperCase()} ', '')}" : "PROPRIETOR'S REPORT $periodTitle"),
      _para('1. INTRODUCTION', bold: true),
      _para('The $owners present their report and the financial statements for the $unit ended ${DateFormat('d MMMM yyyy').format(to)}.'),
      _para('2. PRINCIPAL ACTIVITY', bold: true),
      _para((c['principal_activity'] ?? '').isNotEmpty ? c['principal_activity']! : 'Trading in goods.'),
      if (isCo) ...[_para('3. DIRECTORS', bold: true), dirTable, pw.SizedBox(height: 6)],
      _para('4. RESULTS', bold: true),
      _para('The results for the $unit are set out in the statement of profit or loss. The ${pat >= 0 ? 'profit' : 'loss'} after tax was TZS ${_p(pat.abs())}.'),
      _para('5. SOLVENCY', bold: true),
      _para('The ${isCo ? 'Board of Directors' : 'proprietor'} confirms that applicable accounting standards have been followed and that the financial statements have been prepared on a going concern basis, with a reasonable expectation that adequate resources exist to continue in operation for the foreseeable future.'),
      _para('6. DIVIDENDS', bold: true),
      _para(drawYear > 0.5 ? 'Distributions to the ${isCo ? 'shareholders' : 'owner'} of TZS ${_p(drawYear)} were made during the $unit.' : 'The $owners did not recommend the payment of dividends.'),
      _para('7. EMPLOYEES WELFARE', bold: true),
      _para(staff > 0 ? 'The ${isCo ? 'company' : 'business'} had $staff employee${staff == 1 ? '' : 's'} during the $unit. Management and employees maintain a cooperative working relationship.' : 'The ${isCo ? 'company' : 'business'} had no employees during the $unit.'),
      _para('8. RELATED PARTY TRANSACTIONS', bold: true),
      _para('Related party transactions and balances are disclosed in Note 15 to these financial statements.'),
      _para('9. PERSONS WITH DISABILITIES', bold: true),
      _para('Applications for employment by disabled persons are considered bearing in mind the aptitudes of the applicant. If employees become disabled, every effort is made to continue their employment.'),
      _para('10. GENDER PARITY', bold: true),
      _para('The ${isCo ? 'company' : 'business'} is an equal opportunity employer and does not discriminate on the basis of gender or religion.'),
      _para('11. CORPORATE SOCIAL RESPONSIBILITY', bold: true),
      _para('The ${isCo ? 'company' : 'business'} values responsible corporate citizenship and takes part in community activities.'),
      _para('12. AUDITORS', bold: true),
      _para((c['auditor_name'] ?? '').isNotEmpty ? '${c['auditor_name']} are eligible for appointment as auditors for the $unit ended ${DateFormat('d MMMM yyyy').format(to)}.' : 'Auditors will be appointed in accordance with the applicable law.'),
      pw.SizedBox(height: 18),
      _para('BY ORDER OF THE ${isCo ? 'BOARD' : 'PROPRIETOR'}', bold: true),
      pw.SizedBox(height: 16),
      _para('............................................\n$firstDir\n${isCo ? 'DIRECTOR' : 'PROPRIETOR'}\n\nDATE: ......................'),
    ]);

    // ---- responsibilities
    section([
      _title(isCo ? "STATEMENT OF DIRECTORS' RESPONSIBILITIES" : "STATEMENT OF PROPRIETOR'S RESPONSIBILITIES"),
      _para(isCo
          ? "The directors are required under the Companies Act, 2002 to prepare financial statements for each financial year that give a true and fair view of the state of affairs of the company at the end of the year, its operating results, cash flows and changes in equity."
          : "The proprietor is responsible for preparing financial statements that give a true and fair view of the state of affairs of the business at the end of the year, its operating results and cash flows."),
      _para('Suitable accounting policies have been used and applied consistently, and reasonable and prudent judgment has been exercised where estimates were used. The International Financial Reporting Standard for SMEs has been followed and the financial statements have been prepared on the going concern basis.'),
      _para('The $owners are responsible for keeping proper accounting records that disclose with reasonable accuracy, at any time, the financial position of the ${isCo ? 'company' : 'business'}, for safeguarding its assets, and for taking reasonable steps to prevent and detect fraud, error and other irregularities.'),
      pw.SizedBox(height: 24),
      _para('............................................\n$firstDir\n${isCo ? 'DIRECTOR' : 'PROPRIETOR'}\n\nDATE: ......................'),
    ]);

    // ---- head of finance declaration
    section([
      _title('DECLARATION OF THE HEAD OF FINANCE / ACCOUNTING'),
      _para('The National Board of Accountants and Auditors (NBAA), under the Auditors and Accountants (Registration) Act, requires financial statements to be accompanied by a declaration from the person responsible for the preparation of the financial statements of the entity.'),
      _para('I, ${(c['finance_head'] ?? '').isNotEmpty ? c['finance_head'] : '................................................'}, being the Head of Finance / Accounting of $company, acknowledge my responsibility for ensuring that the financial statements for the $unit ended ${DateFormat('d MMMM yyyy').format(to)} have been prepared in compliance with applicable accounting standards and statutory requirements.'),
      _para('I confirm that the financial statements comply with applicable accounting standards and statutory requirements as at that date and that they have been prepared from properly maintained financial records.'),
      pw.SizedBox(height: 18),
      _para('Signed by: ....................................\nPosition: ....................................\nNBAA Membership No.: ....................................\nDate: ....................................'),
    ]);

    // ---- auditor's report placeholder (never fabricate an opinion)
    section([
      _title("INDEPENDENT AUDITOR'S REPORT"),
      pw.SizedBox(height: 40),
      pw.Center(child: pw.Text("[ To be issued and signed by the company's registered auditor (CPA). ]\n\nThese financial statements have been prepared by management and have not been audited.\nInsert the signed auditor's report here before filing.", textAlign: pw.TextAlign.center, style: const pw.TextStyle(fontSize: 11, lineSpacing: 4))),
    ]);

    // ---- statement of financial position
    section([
      _title('STATEMENT OF FINANCIAL POSITION AS AT ${endTxt.replaceAll(',', '')}'),
      pw.Align(alignment: pw.Alignment.centerRight, child: pw.Text('NOTE        TZS', style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold))),
      _h('ASSETS'),
      pw.Text('Non-current assets', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
      _row('Property, plant and equipment (Note 3)', _p(k.fixedAssets), indent: 1),
      pw.SizedBox(height: 6),
      pw.Text('Current assets', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
      _row('Inventories (Note 5)', _p(k.inventory), indent: 1),
      _row('Receivables and prepayments (Note 6)', _p(recvTotal), indent: 1),
      _row('Provisional tax paid (Note 11)', _p(prepaidTax), indent: 1),
      _row('Cash balances (Note 7)', _p(k.cash), indent: 1),
      _row('Total current assets', _p(currentAssets), bold: true, topLine: true),
      pw.SizedBox(height: 4),
      _row('TOTAL ASSETS', _p(totalAssets), bold: true, topLine: true),
      _h('EQUITY AND LIABILITIES'),
      pw.Text('Equity', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
      _row(isCo ? 'Share capital' : "Owner's capital", _p(capClose), indent: 1),
      _row('Retained earnings brought forward', _p(reOpen), indent: 1),
      _row('Profit / (loss) for the $unit', _p(pat), indent: 1),
      if (drawYear.abs() > 0.5) _row(isCo ? 'Dividends paid' : 'Drawings', _p(-drawYear), indent: 1),
      _row('Total equity', _p(totalEquity), bold: true, topLine: true),
      pw.SizedBox(height: 6),
      pw.Text('Current liabilities', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
      if (k.loans.abs() > 0.5) _row('Loans', _p(k.loans), indent: 1),
      _row('Trade and other payables (Note 8)', _p(payTotal), indent: 1),
      _row('Income tax payable (Note 11)', _p(taxPayable), indent: 1),
      _row('Total current liabilities', _p(currentLiab), bold: true, topLine: true),
      pw.SizedBox(height: 4),
      _row('TOTAL EQUITY AND LIABILITIES', _p(totalEquity + currentLiab), bold: true, topLine: true),
      if (k.imbalance.abs() > 0.5) ...[pw.SizedBox(height: 6), _row('Unreconciled difference - check ledger entries', _p(k.imbalance))],
      pw.SizedBox(height: 16),
      _para("We, the undersigned, declare that the above statement of financial position and accompanying financial statements are correct and that the accounting records, information and explanations given for the purpose of the audit are true and correct to the best of our knowledge.", size: 8.5),
      _para('Name: $firstDir          Signature: ......................          Date: ......................', size: 8.5),
    ]);

    // ---- statement of profit or loss
    final adminCats = st.expensesByCat.keys.where((e) => e != _financeCat).toList();
    section([
      _title('STATEMENT OF PROFIT OR LOSS $periodTitle'),
      _row('Income (Note 4)', _p(revenue), bold: true),
      _row('Direct costs', _p(-cogs)),
      _row('GROSS PROFIT', _p(gross), bold: true, topLine: true),
      if (adj.abs() > 0.5) _row('Stock adjustments - gains / (losses)', _p(adj)),
      _h('Operating costs'),
      _row('Administrative costs (Note 10)', _p(-admin), indent: 1),
      _row('Depreciation (Note 3)', _p(-dep), indent: 1),
      _row('Finance costs (Note 9)', _p(-finance), indent: 1),
      _row('Total operating costs', _p(-(admin + dep + finance)), bold: true, topLine: true),
      pw.SizedBox(height: 4),
      _row('PROFIT / (LOSS) BEFORE TAX', _p(pbt), bold: true, topLine: true),
      _row('Tax expense (Note 11)', _p(-tax)),
      _row('NET PROFIT / (LOSS) FOR THE ${unit.toUpperCase()}', _p(pat), bold: true, topLine: true),
      if (adminCats.isEmpty && finance == 0) pw.SizedBox(height: 1),
    ]);

    // ---- statement of changes in equity
    section([
      _title('STATEMENT OF CHANGES IN EQUITY $periodTitle'),
      _table(['', isCo ? 'Share capital TZS' : "Owner's capital TZS", 'Retained earnings TZS', 'Total equity TZS'], [
        ['Balance at ${DateFormat('dd-MM-yyyy').format(from)}', _p(capOpen), _p(reOpen), _p(capOpen + reOpen)],
        ['Capital introduced (incl. opening stock)', _p(capClose - capOpen), _p(0), _p(capClose - capOpen)],
        ['Profit / (loss) for the $unit', _p(0), _p(pat), _p(pat)],
        [isCo ? 'Dividends paid' : 'Drawings', _p(0), _p(-drawYear), _p(-drawYear)],
        ['Balance at ${DateFormat('dd-MM-yyyy').format(to)}', _p(capClose), _p(reClose), _p(totalEquity)],
      ]),
    ]);

    // ---- statement of cash flows (indirect)
    section([
      _title('STATEMENT OF CASH FLOWS $periodTitle'),
      _h('Cash flows from operating activities'),
      _row('Profit / (loss) before tax', _p(pbt), indent: 1),
      _row('Adjustment for non-cash items:', '', indent: 1),
      _row('Add: depreciation', _p(dep), indent: 2),
      _row('Adjusted profit', _p(adjusted), bold: true, topLine: true),
      _row('Working capital adjustments:', '', indent: 1),
      _row('(Increase) / decrease in inventories', _p(-dInv), indent: 2),
      _row('(Increase) / decrease in receivables and prepayments', _p(-recChange), indent: 2),
      _row('Increase / (decrease) in trade and other payables (incl. VAT)', _p(payChange), indent: 2),
      _row('Cash generated from / (used in) operations', _p(generated), bold: true, topLine: true),
      _row('Income tax paid', _p(-taxPaidYear), indent: 1),
      _row('Net cash flows from operating activities (A)', _p(opCash), bold: true, topLine: true),
      _h('Cash flows from investing activities'),
      _row('Purchase of property, plant and equipment', _p(-capex), indent: 1),
      _row('Net cash flows used in investing activities (B)', _p(-capex), bold: true, topLine: true),
      _h('Cash flows from financing activities'),
      _row(isCo ? 'Share capital introduced' : 'Capital introduced', _p(k.capital - o.capital), indent: 1),
      _row('Loans received', _p(k.loanIn - o.loanIn), indent: 1),
      _row('Loans repaid', _p(-(k.loanOut - o.loanOut)), indent: 1),
      _row(isCo ? 'Dividends paid' : 'Drawings', _p(-drawYear), indent: 1),
      _row('Net cash flows from / (used in) financing activities (C)', _p(finCash), bold: true, topLine: true),
      pw.SizedBox(height: 6),
      _row('NET INCREASE / (DECREASE) IN CASH AND CASH EQUIVALENTS (A+B+C)', _p(netCash), bold: true, topLine: true),
      _row('Cash at the beginning of the $unit', _p(o.cash), indent: 1),
      _row('CASH AND CASH EQUIVALENTS AT THE END OF THE ${unit.toUpperCase()}', _p(k.cash), bold: true, topLine: true),
      if ((k.openingStock - o.openingStock).abs() > 0.5) ...[pw.SizedBox(height: 8), pw.Text('Non-cash: opening stock of TZS ${_p(k.openingStock - o.openingStock)} was introduced as capital in kind and is excluded above.', style: const pw.TextStyle(fontSize: 8))],
    ]);

    // ---- notes
    final auditFee = math.min(k.auditUnpaid, math.max(0.0, k.accrued));
    final classes = assetClasses.keys.toList();
    String cell(Map<String, double> m, String key) => _p(m[key] ?? 0);
    final adminSorted = [..._adminOrder.where(adminCats.contains), ...adminCats.where((e) => !_adminOrder.contains(e))];
    section([
      _title('NOTES TO THE FINANCIAL STATEMENTS'),
      _para('1. BASIS OF PREPARATION', bold: true),
      _para('The financial statements have been prepared on a historical cost basis and are presented in Tanzanian Shillings (TZS). Statement of compliance: they have been prepared in accordance with the International Financial Reporting Standard for Small and Medium-sized Entities (IFRS for SMEs). They were prepared from the records kept in Kibo Trade (fiscal sales receipts, purchases, expenses, fixed-asset register and capital/tax ledger).'),
      _para('2. SUMMARY OF SIGNIFICANT ACCOUNTING POLICIES', bold: true),
      _para('2.1 Revenue recognition. Revenue is recognised when a fiscal receipt or invoice is issued, to the extent that economic benefits will probably flow to the ${isCo ? 'company' : 'business'} and can be reliably measured. Revenue is stated net of VAT.'),
      _para('2.2 Trade and other receivables. Receivables (credit sales) are carried at the original invoice amount less an allowance for amounts that will not be collected. Bad debts are written off when identified.'),
      _para('2.3 Cash and cash equivalents. Cash and bank balances comprise cash in hand, mobile-money and bank balances.'),
      _para('2.4 Property, plant and equipment. Items are initially recorded at historical cost. Depreciation is calculated on the reducing balance method, pro-rated by months in service, so as to write off the cost over the expected useful lives. Annual rates: ${assetClasses.entries.map((e) => '${e.value} ${((assetRates[e.key] ?? 0) * 100).toStringAsFixed(1)}%').join('; ')}. Carrying values are reviewed for impairment when events indicate that the carrying value may not be recoverable.'),
      _para('2.5 Impairment of assets. At each reporting date the entity assesses whether there is an indication that an asset may be impaired. If so, the recoverable amount is estimated and the asset is written down to it where the carrying amount is higher.'),
      _para('2.6 Provisions. Provisions are recognised when there is a present obligation as a result of a past event, an outflow of resources is probable and a reliable estimate can be made.'),
      _para('2.7 Inventories. Inventories are stated at the lower of cost (weighted average) and net realisable value. Stock adjustments (damage, counts, returns) are recognised in profit or loss.'),
      _para('2.8 Loans and borrowings. Loans are initially recognised at the fair value of the consideration received less directly attributable transaction costs.'),
      _para('2.9 De-recognition of financial liabilities. A financial liability is derecognised when the obligation is discharged, cancelled or expires.'),
      _para('2.10 Taxes. Current tax is measured at the amount expected to be paid to the taxation authority using rates enacted at the reporting date. The income tax rate applied is ${(taxRate * 100).toStringAsFixed(taxRate * 100 == (taxRate * 100).roundToDouble() ? 0 : 1)}%. Tax is computed on the accounting profit; no adjustment is made for non-deductible items or capital allowances and no deferred tax is recognised. VAT is accounted for separately: output VAT less recoverable input VAT, net of amounts paid to TRA.'),
      _h('3. PROPERTY, PLANT AND EQUIPMENT'),
      _table(['', ...classes.map((e) => assetClasses[e]!), 'Total TZS'], [
        ['COST at start of $unit', ...classes.map((e) => cell(o.costByClass, e)), _p(o.assetCost)],
        ['Additions', ...classes.map((e) => _p((k.costByClass[e] ?? 0) - (o.costByClass[e] ?? 0))), _p(capex)],
        ['COST at end of $unit', ...classes.map((e) => cell(k.costByClass, e)), _p(k.assetCost)],
        ['DEPRECIATION at start', ...classes.map((e) => cell(o.depByClass, e)), _p(o.depreciation)],
        ['Charge for the $unit', ...classes.map((e) => _p((k.depByClass[e] ?? 0) - (o.depByClass[e] ?? 0))), _p(dep)],
        ['DEPRECIATION at end', ...classes.map((e) => cell(k.depByClass, e)), _p(k.depreciation)],
        ['CARRYING AMOUNT at end', ...classes.map((e) => _p((k.costByClass[e] ?? 0) - (k.depByClass[e] ?? 0))), _p(k.fixedAssets)],
      ]),
      pw.SizedBox(height: 8),
      _h('4. REVENUE'),
      for (final code in taxLetters)
        if (st.salesByClass[code] != null) _row(taxNames[code]!, _p(st.salesByClass[code]!.net), indent: 1),
      _row('Total revenue (net of VAT)', _p(revenue), bold: true, topLine: true),
      _h('5. INVENTORIES'),
      _row('Merchandise stock at weighted-average cost', _p(k.inventory), indent: 1),
      _row('Total', _p(k.inventory), bold: true, topLine: true),
      _h('6. RECEIVABLES AND PREPAYMENTS'),
      _row('Trade receivables (credit sales not yet collected)', _p(k.receivables), indent: 1),
      _row('VAT recoverable', _p(vatRecv), indent: 1),
      _row('Prepayments', _p(0), indent: 1),
      _row('Total', _p(recvTotal), bold: true, topLine: true),
      _h('7. CASH BALANCES'),
      _row('Cash and cash equivalents', _p(k.cash), indent: 1),
      _row('Total', _p(k.cash), bold: true, topLine: true),
      _h('8. TRADE AND OTHER PAYABLES'),
      _row('Audit fee payable', _p(auditFee), indent: 1),
      _row('Other accrued expenses', _p(k.accrued - auditFee), indent: 1),
      _row('Trade payables', _p(k.tradePayables), indent: 1),
      _row('VAT payable', _p(vatPay), indent: 1),
      _row('Total', _p(payTotal), bold: true, topLine: true),
      _h('9. FINANCE COSTS'),
      _row('Bank charges / interest', _p(finance), indent: 1),
      _row('Total', _p(finance), bold: true, topLine: true),
      _h('10. ADMINISTRATIVE COSTS'),
      if (adminSorted.isEmpty) _row('None recorded', _p(0), indent: 1),
      for (final e in adminSorted) _row(e, _p(st.expensesByCat[e] ?? 0), indent: 1),
      _row('Total administrative costs', _p(admin), bold: true, topLine: true),
      _h('11. TAXATION'),
      _row('Profit / (loss) before tax', _p(pbt), indent: 1),
      _row('Tax expense at ${(taxRate * 100).toStringAsFixed(taxRate * 100 == (taxRate * 100).roundToDouble() ? 0 : 1)}% (no tax on a loss)', _p(tax), indent: 1),
      _row('Income tax payable / (provisional tax paid) at start of $unit', _p(o.netTax), indent: 1),
      _row('Add: tax expense for the $unit', _p(tax), indent: 1),
      _row('Less: tax paid in the $unit (provisional and final)', _p(-taxPaidYear), indent: 1),
      _row('Income tax payable / (provisional tax paid) at end of $unit', _p(k.netTax), bold: true, topLine: true),
      _para('12. EVENTS AFTER THE REPORTING DATE', bold: true),
      _para('There were no events after the reporting date of such nature that would require additional disclosure or adjustment to the financial statements. (Management to confirm.)'),
      _para('13. CAPITAL COMMITMENTS', bold: true),
      _para('There were no capital commitments at ${DateFormat('d MMMM yyyy').format(to)}. (Management to confirm.)'),
      _para('14. CONTINGENT LIABILITIES', bold: true),
      _para('There were no contingent liabilities at ${DateFormat('d MMMM yyyy').format(to)}. (Management to confirm.)'),
      _para('15. RELATED PARTY TRANSACTIONS', bold: true),
      _para('${drawYear > 0.5 ? 'Distributions / drawings to the ${isCo ? 'shareholders' : 'owner'} during the $unit: TZS ${_p(drawYear)}. ' : ''}Management to disclose any other related party transactions and balances.'),
      _para('16. COMPARATIVE FIGURES', bold: true),
      _para('Comparative figures for the previous period are not presented in these statements.'),
    ]);

    // ---- inventory schedule
    section([
      _title('SCHEDULE OF INVENTORY ON HAND (CURRENT RECORDS)'),
      _table(['SKU', 'Product', 'Qty', 'Unit cost', 'Value'], [for (final p in products) [p.sku, p.name, fmtQty(p.stock), _pd(p.cost), _pd(p.stock * p.cost)]]),
      pw.SizedBox(height: 6),
      _row('Total stock valuation (qty x cost)', _p(st.stockValue), bold: true),
    ]);

    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: margin,
      header: (ctx) => pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 10),
        child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Text(company.toUpperCase(), style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
          pw.Text('FINANCIAL STATEMENTS $periodTitle', style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
          pw.Divider(thickness: 0.5),
        ]),
      ),
      footer: (ctx) => pw.Align(alignment: pw.Alignment.centerRight, child: pw.Text('${ctx.pageNumber}', style: const pw.TextStyle(fontSize: 9))),
      build: (_) => w,
    ));

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
            _row('${taxNames[code]} - net', _pd(st.salesByClass[code]!.net), indent: 1),
            _row('${taxNames[code]} - VAT', _pd(st.salesByClass[code]!.vat), indent: 1),
          ],
        _row('Total output VAT', _pd(st.outputVat), bold: true, topLine: true),
        _h('Input VAT (purchases and expenses)'),
        _row('Stock purchases - net', _pd(st.purchasesNet), indent: 1),
        _row('Stock purchases - VAT', _pd(st.purchasesVat), indent: 1),
        _row('Expenses - net', _pd(st.expensesNet), indent: 1),
        _row('Expenses - VAT', _pd(st.expensesVat), indent: 1),
        _row('Total input VAT', _pd(st.inputVat), bold: true, topLine: true),
        pw.SizedBox(height: 6),
        _row(st.vatPayable >= 0 ? 'NET VAT PAYABLE' : 'NET VAT REFUNDABLE / CARRY FORWARD', _pd(st.vatPayable.abs()), bold: true, topLine: true),
        pw.SizedBox(height: 14),
        pw.Text('Input VAT is claimable only with valid supplier tax invoices / EFD receipts. Transcribe into the TRA Tax Online Services VAT return and attach the sales and purchases schedules (CSV).', style: const pw.TextStyle(fontSize: 8)),
      ],
    ));
    final file = File('${(await exportsDir()).path}/vat_working_paper_${_tag(from, to)}.pdf');
    return file.writeAsBytes(await doc.save());
  }
}
