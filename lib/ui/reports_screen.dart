import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../data/app_state.dart';
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
      await Share.shareXFiles([XFile(f.path)]);
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
          for (final p in ['This month', 'Last month', 'This year']) Chip2(p, selected: preset == p, onTap: () => setState(() => _preset(p))),
          Chip2('Custom', selected: preset == 'Custom', onTap: _custom),
        ]),
        const SizedBox(height: 8),
        Text('${DateFormat('d MMM yyyy').format(from)} - ${DateFormat('d MMM yyyy').format(to)}', style: t(11, w: FontWeight.w500, c: K.muted)),
        const SizedBox(height: 16),
        FutureBuilder<Statement>(
          future: s.repo.statement(f, tt),
          builder: (_, snap) {
            final st = snap.data;
            if (st == null) return const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator(color: K.lime)));
            return Column(children: [
              _Card('Income statement', [
                ('Revenue (net of VAT)', st.revenueNet, false),
                ('Cost of goods sold', -st.cogs, false),
                ('Gross profit', st.grossProfit, true),
                ('Operating expenses', -st.expensesNet, false),
                ('Net profit before tax', st.netProfit, true),
              ]),
              const SizedBox(height: 12),
              _Card('VAT summary', [
                ('Output VAT (sales)', st.outputVat, false),
                ('Input VAT (purchases + expenses)', -st.inputVat, false),
                (st.vatPayable >= 0 ? 'VAT payable' : 'VAT refundable', st.vatPayable.abs(), true),
              ]),
              const SizedBox(height: 12),
              _Card('Sales by VAT class', [
                for (final c in taxLetters)
                  if (st.salesByClass[c] != null) (taxNames[c]!, st.salesByClass[c]!.gross, false),
                ('Receipts issued: ${st.receiptCount}', st.revenueGross, true),
              ]),
            ]);
          },
        ),
        const SizedBox(height: 20),
        Text('EXPORT FOR TRA', style: t(10, w: FontWeight.w800, c: K.muted, ls: 1.8)),
        const SizedBox(height: 10),
        LimeButton('Financial statements (PDF)', icon: Ic.pdf, busy: _busy, onTap: () => _export(() => s.reports.statementsPdf(from, to, s.cfg))),
        const SizedBox(height: 10),
        LimeButton('Sales schedule - VAT output (CSV)', icon: Ic.table, outline: true, onTap: _busy ? null : () => _export(() => s.reports.salesCsv(from, to))),
        const SizedBox(height: 10),
        LimeButton('Purchases schedule - VAT input (CSV)', icon: Ic.table, outline: true, onTap: _busy ? null : () => _export(() => s.reports.purchasesCsv(from, to))),
        const SizedBox(height: 10),
        LimeButton('Z-reports as submitted (XML)', icon: Ic.code, outline: true, onTap: _busy ? null : () => _export(() => s.reports.zXml(from, to))),
        const SizedBox(height: 12),
        Text('Z-reports and receipts are uploaded to TRA automatically. The VAT return itself is filed in TRA Tax Online Services - use these schedules as the supporting figures and check them against TRA\'s current templates.', style: t(10, w: FontWeight.w500, c: K.dim, h: 1.5)),
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
        items: [for (final c in ['Rent', 'Wages & salaries', 'Utilities', 'Transport', 'Marketing', 'Repairs', 'Licences & fees', 'Other']) DropdownMenuItem(value: c, child: Text(c))],
        onChanged: (v) => setState(() => cat = v ?? cat),
      ),
      const SizedBox(height: 12),
      f(desc, 'Description'),
      Row(children: [Expanded(child: f(amount, 'Total paid (incl. VAT)', n: true)), const SizedBox(width: 10), Expanded(child: f(vat, 'of which VAT', n: true))]),
      Row(children: [Expanded(child: f(tin, 'Supplier TIN')), const SizedBox(width: 10), Expanded(child: f(ref, 'Invoice / EFD no.'))]),
      const SizedBox(height: 6),
      LimeButton('Save expense', icon: Ic.check, onTap: () async {
        final g = double.tryParse(amount.text.replaceAll(',', ''));
        if (g == null || g <= 0) return toast(context, 'Enter the amount');
        await context.read<AppState>().addExpense(date: DateTime.now(), category: cat, description: desc.text.trim(), gross: g, vat: double.tryParse(vat.text) ?? 0, tin: tin.text.trim(), ref: ref.text.trim());
        if (context.mounted) Navigator.pop(context);
      }),
    ]);
  }
}
