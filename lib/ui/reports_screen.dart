import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../services/share_helper.dart';

import '../data/app_state.dart';
import '../data/fixed_assets.dart';
import '../data/models.dart';
import '../data/repo.dart';
import '../data/tax.dart';
import 'icons.dart';
import 'theme.dart';
import 'widgets.dart';

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});
  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  late DateTime from, to;
  String preset = 'This month';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _preset('This month');
  }

  void _preset(String p) {
    final n = DateTime.now();
    preset = p;
    if (p == 'This month') {
      from = DateTime(n.year, n.month, 1);
      to = n;
    } else if (p == 'Last month') {
      from = DateTime(n.year, n.month - 1, 1);
      to = DateTime(n.year, n.month, 0);
    } else if (p == 'This year') {
      from = DateTime(n.year, 1, 1);
      to = n;
    } else if (p == 'Last year') {
      from = DateTime(n.year - 1, 1, 1);
      to = DateTime(n.year - 1, 12, 31);
    }
  }

  Future<void> _custom() async {
    final r = await showDateRangePicker(context: context, firstDate: DateTime(2020), lastDate: DateTime.now(), initialDateRange: DateTimeRange(start: from, end: to));
    if (r != null) setState(() { preset = 'Custom'; from = r.start; to = r.end; });
  }

  Future<void> _export(Future<File> Function() make) async {
    setState(() => _busy = true);
    try {
      final f = await make();
      if (!mounted) return;
      await shareFile(context, f.path);
    } catch (e) {
      if (mounted) toast(context, 'Export failed: $e');
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final f = dayFmt.format(from), tt = dayFmt.format(to);
    return Scaffold(
      appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0, title: Text('Financial statements', style: t(18, w: FontWeight.w800))),
      body: ListView(padding: const EdgeInsets.fromLTRB(20, 0, 20, 40), children: [
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final p in ['This month', 'Last month', 'This year', 'Last year']) Chip2(p, selected: preset == p, onTap: () => setState(() => _preset(p))),
          Chip2('Custom', selected: preset == 'Custom', onTap: _custom),
        ]),
        const SizedBox(height: 8),
        Text('${DateFormat('d MMM yyyy').format(from)} - ${DateFormat('d MMM yyyy').format(to)}', style: t(11, w: FontWeight.w500, c: K.muted)),
        const SizedBox(height: 16),
        FutureBuilder<Period>(
          future: s.repo.period(from, to, s.taxRate),
          builder: (_, snap) {
            final per = snap.data;
            if (per == null) return const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator(color: K.lime)));
            final st = per.st, o = per.open, k = per.close;
            final dep = k.depreciation - o.depreciation;
            final fin = st.expensesByCat['Bank charges & interest'] ?? 0;
            final pbt = k.pbt - o.pbt, tax = k.tax - o.tax;
            return Column(children: [
              _Card('Income statement', [
                ('Revenue (net of VAT)', st.revenueNet, false),
                ('Direct costs', -st.cogs, false),
                ('Gross profit', st.grossProfit, true),
                ('Stock adjustments', st.adjustments, false),
                ('Administrative costs', -(st.expensesNet - fin), false),
                ('Depreciation', -dep, false),
                ('Finance costs', -fin, false),
                ('Profit before tax', pbt, true),
                ('Tax expense', -tax, false),
                ('Net profit for the period', pbt - tax, true),
              ]),
              const SizedBox(height: 12),
              _Card('Financial position (at period end)', [
                ('Cash', k.cash, false),
                ('Inventory', k.inventory, false),
                ('Receivables', k.receivables, false),
                ('Fixed assets (net)', k.fixedAssets, false),
                ('Payables and accruals', k.tradePayables + k.accrued, false),
                ('Total equity', k.equity, true),
              ]),
              if (k.imbalance.abs() > 0.5) Padding(padding: const EdgeInsets.only(top: 8), child: Text('Books do not balance by ${num0(k.imbalance)} - check the ledger entries.', style: t(11, w: FontWeight.w600, c: K.danger))),
              const SizedBox(height: 12),
              _Card('VAT summary', [
                ('Output VAT (sales)', st.outputVat, false),
                ('Input VAT (purchases + expenses)', -st.inputVat, false),
                (st.vatPayable >= 0 ? 'VAT payable' : 'VAT refundable', st.vatPayable.abs(), true),
              ]),
            ]);
          },
        ),
        const SizedBox(height: 20),
        Text('EXPORT FOR TRA', style: t(10, w: FontWeight.w800, c: K.muted, ls: 1.8)),
        const SizedBox(height: 10),
        LimeButton('Full financial statements pack (PDF)', icon: Ic.pdf, busy: _busy, onTap: () => _export(() => s.reports.financialStatementsPdf(from, to, s.cfg, s.taxRate))),
        const SizedBox(height: 10),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: LimeButton('Word (.docx)', icon: Ic.fileText, outline: true, onTap: _busy ? null : () => _export(() => s.reports.financialStatementsDocx(from, to, s.cfg, s.taxRate)))),
          const SizedBox(width: 10),
          Expanded(child: LimeButton('Excel (.xlsx)', icon: Ic.table, outline: true, onTap: _busy ? null : () => _export(() => s.reports.financialStatementsXlsx(from, to, s.cfg, s.taxRate)))),
        ]),
        const SizedBox(height: 10),
        LimeButton('VAT working paper (PDF)', icon: Ic.pdf, outline: true, onTap: _busy ? null : () => _export(() => s.reports.vatPdf(from, to, s.cfg))),
        const SizedBox(height: 10),
        LimeButton('Sales schedule - VAT output (CSV)', icon: Ic.table, outline: true, onTap: _busy ? null : () => _export(() => s.reports.salesCsv(from, to))),
        const SizedBox(height: 10),
        LimeButton('Purchases schedule - VAT input (CSV)', icon: Ic.table, outline: true, onTap: _busy ? null : () => _export(() => s.reports.purchasesCsv(from, to))),
        const SizedBox(height: 10),
        LimeButton('Z-reports as submitted (XML)', icon: Ic.code, outline: true, onTap: _busy ? null : () => _export(() => s.reports.zXml(from, to))),
        const SizedBox(height: 12),
        Text('Z-reports and receipts are uploaded to TRA automatically. The VAT return itself is filed in TRA Tax Online Services - use these schedules as the supporting figures and check them against TRA\'s current templates.', style: t(10, w: FontWeight.w500, c: K.dim, h: 1.5)),
        const SizedBox(height: 22),
        SectionTitle('Fixed assets (PPE)', action: '+ Add', onAction: () => showSheet(context, const _AssetForm()).then((_) => setState(() {}))),
        Text('Depreciation is calculated automatically (reducing balance): furniture 12.5%, computers 33.3%, equipment 12.5%, vehicles 25%.', style: t(10, w: FontWeight.w500, c: K.dim, h: 1.5)),
        const SizedBox(height: 10),
        FutureBuilder<List<Asset>>(
          future: s.repo.assets(),
          builder: (_, snap) {
            final list = snap.data ?? [];
            if (list.isEmpty) return const Glass(child: Empty('No fixed assets recorded.'));
            return Glass(
              padding: EdgeInsets.zero,
              child: Column(children: [
                for (final a in list)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
                    child: Row(children: [
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(a.description.isEmpty ? assetClasses[a.cls]! : a.description, style: t(12)), Text('${assetClasses[a.cls]}  -  ${dayFmt.format(a.date)}', style: t(10, w: FontWeight.w500, c: K.muted))])),
                      Column(crossAxisAlignment: CrossAxisAlignment.end, children: [Text(money(a.cost), style: t(12)), Text('NBV ${money(a.cost - a.accDepAt(DateTime.now()))}', style: t(10, w: FontWeight.w500, c: K.dim))]),
                      IconButton(
                        icon: const Icon(Ic.trash, size: 16, color: K.dim),
                        onPressed: () async {
                          await s.repo.deleteAsset(a.id!);
                          if (mounted) setState(() {});
                        },
                      ),
                    ]),
                  ),
              ]),
            );
          },
        ),
        const SizedBox(height: 22),
        SectionTitle('Capital & other entries', action: '+ Add', onAction: () => showSheet(context, const _LedgerForm())),
        Text('Record opening capital, loans, drawings, VAT and income tax paid to TRA, and payments of credit sales/purchases/accruals. The cash flow statement and balance sheet depend on these.', style: t(10, w: FontWeight.w500, c: K.dim, h: 1.5)),
        const SizedBox(height: 10),
        FutureBuilder<List<Map<String, Object?>>>(
          future: s.repo.ledger('2000-01-01', tt),
          builder: (_, snap) {
            final list = snap.data ?? [];
            if (list.isEmpty) return const Glass(child: Empty('No entries yet.'));
            return Glass(
              padding: EdgeInsets.zero,
              child: Column(children: [
                for (final e in list.take(15))
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
                    child: Row(children: [
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(_ledgerTypes[e['type']] ?? '${e['type']}', style: t(12)), Text('${e['date']}  ${e['note'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis, style: t(10, w: FontWeight.w500, c: K.muted))])),
                      Text(money((e['amount'] as num).toDouble()), style: t(12)),
                      IconButton(
                        icon: const Icon(Ic.trash, size: 16, color: K.dim),
                        onPressed: () async {
                          await s.repo.deleteLedger(e['id'] as int);
                          if (mounted) setState(() {});
                        },
                      ),
                    ]),
                  ),
              ]),
            );
          },
        ),
        const SizedBox(height: 22),
        SectionTitle('Expenses', action: '+ Add', onAction: () => showSheet(context, const _ExpenseForm())),
        FutureBuilder<List<Expense>>(
          future: s.repo.expenses(f, tt),
          builder: (_, snap) {
            final list = snap.data ?? [];
            if (list.isEmpty) return const Glass(child: Empty('No expenses in this period.\nRecord rent, wages, transport etc. so the income statement is complete.'));
            return Glass(
              padding: EdgeInsets.zero,
              child: Column(children: [
                for (final e in list.take(12))
                  Padding(
                    padding: const EdgeInsets.all(14),
                    child: Row(children: [
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(e.category, style: t(12)), Text('${e.date}  ${e.description}', maxLines: 1, overflow: TextOverflow.ellipsis, style: t(10, w: FontWeight.w500, c: K.muted))])),
                      Text(money(e.gross), style: t(12)),
                    ]),
                  ),
              ]),
            );
          },
        ),
      ]),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card(this.title, this.rows);
  final String title;
  final List<(String, double, bool)> rows;
  @override
  Widget build(BuildContext context) => Glass(
        radius: 22,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: t(13, w: FontWeight.w800)),
          const SizedBox(height: 10),
          for (final r in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Flexible(child: Text(r.$1, style: t(12, w: r.$3 ? FontWeight.w800 : FontWeight.w500, c: r.$3 ? Colors.white : K.muted))),
                Text(r.$2 < 0 ? '(${num0(-r.$2)})' : num0(r.$2), style: t(12, w: r.$3 ? FontWeight.w800 : FontWeight.w600, c: r.$3 ? K.lime : Colors.white)),
              ]),
            ),
        ]),
      );
}

class _ExpenseForm extends StatefulWidget {
  const _ExpenseForm();
  @override
  State<_ExpenseForm> createState() => _ExpenseFormState();
}

class _ExpenseFormState extends State<_ExpenseForm> {
  String cat = 'Rent';
  final desc = TextEditingController();
  final amount = TextEditingController();
  final vat = TextEditingController(text: '0');
  final tin = TextEditingController();
  final ref = TextEditingController();
  bool paid = true;

  @override
  Widget build(BuildContext context) {
    Widget f(TextEditingController c, String l, {bool n = false}) => Padding(padding: const EdgeInsets.only(bottom: 12), child: TextField(controller: c, keyboardType: n ? const TextInputType.numberWithOptions(decimal: true) : null, style: t(13, w: FontWeight.w500), decoration: dec(l)));
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Add expense', style: t(18, w: FontWeight.w800)),
      const SizedBox(height: 14),
      DropdownButtonFormField<String>(
        initialValue: cat,
        dropdownColor: K.sheet,
        decoration: dec('Category'),
        style: t(13, w: FontWeight.w500),
        isExpanded: true,
        items: [for (final c in ['Audit & other professional fees', 'Travelling', 'Cleaning', 'Communication', 'Rent', 'Legal & other professional fees', 'Tender expenses', 'Office meals', 'Printing & stationery', 'Repair & maintenance', 'Salary & wages', 'Security', 'Water & electricity', 'Marketing', 'Licences & fees', 'Bank charges & interest', 'Other']) DropdownMenuItem(value: c, child: Text(c))],
        onChanged: (v) => setState(() => cat = v ?? cat),
      ),
      const SizedBox(height: 12),
      f(desc, 'Description'),
      Row(children: [Expanded(child: f(amount, 'Total paid (incl. VAT)', n: true)), const SizedBox(width: 10), Expanded(child: f(vat, 'of which VAT', n: true))]),
      Row(children: [Expanded(child: f(tin, 'Supplier TIN')), const SizedBox(width: 10), Expanded(child: f(ref, 'Invoice / EFD no.'))]),
      SwitchListTile(contentPadding: EdgeInsets.zero, title: Text('Already paid', style: t(13)), subtitle: Text(paid ? 'Cash goes out now' : 'Recorded as a payable until you add a payment entry', style: t(10, w: FontWeight.w500, c: K.muted)), value: paid, onChanged: (v) => setState(() => paid = v)),
      const SizedBox(height: 6),
      LimeButton('Save expense', icon: Ic.check, onTap: () async {
        final g = double.tryParse(amount.text.replaceAll(',', ''));
        if (g == null || g <= 0) return toast(context, 'Enter the amount');
        await context.read<AppState>().addExpense(date: DateTime.now(), category: cat, description: desc.text.trim(), gross: g, vat: double.tryParse(vat.text) ?? 0, tin: tin.text.trim(), ref: ref.text.trim(), paid: paid);
        if (context.mounted) Navigator.pop(context);
      }),
    ]);
  }
}

const _ledgerTypes = {
  'capital': 'Capital introduced (cash)',
  'drawings': 'Owner drawings / dividends paid',
  'loan_in': 'Loan received',
  'loan_out': 'Loan repaid',
  'vat_paid': 'VAT paid to TRA (negative = refund)',
  'provisional_tax': 'Provisional income tax paid to TRA',
  'tax_paid': 'Income tax paid to TRA (final / balance)',
  'receivable_collected': 'Customer payment received (credit sale)',
  'supplier_paid': 'Supplier paid (credit purchase)',
  'accrued_paid': 'Accrued expense paid (e.g. audit fee)',
};

class _LedgerForm extends StatefulWidget {
  const _LedgerForm();
  @override
  State<_LedgerForm> createState() => _LedgerFormState();
}

class _LedgerFormState extends State<_LedgerForm> {
  String type = 'capital';
  final amount = TextEditingController();
  final note = TextEditingController();

  @override
  Widget build(BuildContext context) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Capital & other entry', style: t(18, w: FontWeight.w800)),
        const SizedBox(height: 14),
        DropdownButtonFormField<String>(
          initialValue: type,
          dropdownColor: K.sheet,
          isExpanded: true,
          decoration: dec('Type'),
          style: t(13, w: FontWeight.w500),
          items: [for (final e in _ledgerTypes.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
          onChanged: (v) => setState(() => type = v ?? type),
        ),
        const SizedBox(height: 12),
        TextField(controller: amount, keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true), style: t(13, w: FontWeight.w500), decoration: dec('Amount (TZS)')),
        const SizedBox(height: 12),
        TextField(controller: note, style: t(13, w: FontWeight.w500), decoration: dec('Note (optional)')),
        const SizedBox(height: 18),
        LimeButton('Save entry', icon: Ic.check, onTap: () async {
          final a = double.tryParse(amount.text.replaceAll(',', ''));
          if (a == null || a == 0) return toast(context, 'Enter the amount');
          await context.read<AppState>().repo.addLedger(DateTime.now(), type, a, note.text.trim());
          if (context.mounted) Navigator.pop(context);
        }),
      ]);
}

class _AssetForm extends StatefulWidget {
  const _AssetForm();
  @override
  State<_AssetForm> createState() => _AssetFormState();
}

class _AssetFormState extends State<_AssetForm> {
  String cls = 'equipment';
  final desc = TextEditingController();
  final cost = TextEditingController();
  DateTime date = DateTime.now();

  @override
  Widget build(BuildContext context) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Add fixed asset', style: t(18, w: FontWeight.w800)),
        const SizedBox(height: 14),
        DropdownButtonFormField<String>(
          initialValue: cls,
          dropdownColor: K.sheet,
          isExpanded: true,
          decoration: dec('Asset class'),
          style: t(13, w: FontWeight.w500),
          items: [for (final e in assetClasses.entries) DropdownMenuItem(value: e.key, child: Text('${e.value} (${((assetRates[e.key] ?? 0) * 100).toStringAsFixed(1)}%)'))],
          onChanged: (v) => setState(() => cls = v ?? cls),
        ),
        const SizedBox(height: 12),
        TextField(controller: desc, style: t(13, w: FontWeight.w500), decoration: dec('Description')),
        const SizedBox(height: 12),
        TextField(controller: cost, keyboardType: const TextInputType.numberWithOptions(decimal: true), style: t(13, w: FontWeight.w500), decoration: dec('Cost (TZS, paid in cash)')),
        const SizedBox(height: 12),
        GestureDetector(
          onTap: () async {
            final d = await showDatePicker(context: context, initialDate: date, firstDate: DateTime(2000), lastDate: DateTime.now());
            if (d != null) setState(() => date = d);
          },
          child: Glass(radius: 16, padding: const EdgeInsets.all(14), child: Row(children: [const Icon(Ic.calendarCheck, size: 16, color: K.lime), const SizedBox(width: 10), Text('Purchase date: ${dayFmt.format(date)}', style: t(12))])),
        ),
        const SizedBox(height: 18),
        LimeButton('Save asset', icon: Ic.check, onTap: () async {
          final c = double.tryParse(cost.text.replaceAll(',', ''));
          if (c == null || c <= 0) return toast(context, 'Enter the cost');
          await context.read<AppState>().repo.addAsset(date, cls, desc.text.trim(), c);
          if (context.mounted) Navigator.pop(context);
        }),
      ]);
}
