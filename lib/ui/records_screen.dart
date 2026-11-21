import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../data/app_state.dart';
import '../data/models.dart';
import '../data/repo.dart';
import '../data/tax.dart';
import 'icons.dart';
import 'receipt_detail.dart';
import 'responsive.dart';
import 'returns_ui.dart';
import 'theme.dart';
import 'widgets.dart';

/// One row of a records list.
class RecRow {
  const RecRow({required this.title, required this.subtitle, required this.amount, this.badge, this.badgeColor = K.lime, this.note, this.onTap, this.dim = false});
  final String title, subtitle;
  final double amount;
  final String? badge, note;
  final Color badgeColor;
  final bool dim;
  final Future<void> Function()? onTap;
}

/// Generic list page: period filter, search, totals and rows. Each screen below only supplies its loader.
class RecordPage extends StatefulWidget {
  const RecordPage({super.key, required this.title, required this.load, this.ranged = true, this.amountLabel = 'Total', this.emptyText = 'Nothing here yet.'});
  final String title, amountLabel, emptyText;
  final bool ranged;
  final Future<List<RecRow>> Function(BuildContext context, String from, String to) load;
  @override
  State<RecordPage> createState() => _RecordPageState();
}

class _RecordPageState extends State<RecordPage> {
  String preset = 'This month';
  late DateTime from, to;
  final _q = TextEditingController();
  late Future<List<RecRow>> _fut;

  @override
  void initState() {
    super.initState();
    _range('This month');
    _fut = _go();
  }

  void _range(String p) {
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
    } else {
      from = DateTime(2000);
      to = n;
    }
  }

  Future<List<RecRow>> _go() => widget.load(context, dayFmt.format(from), dayFmt.format(to));
  void _reload() => setState(() => _fut = _go());

  @override
  Widget build(BuildContext context) {
    context.watch<AppState>();
    final wide = isWide(context);
    return Scaffold(
      appBar: AppBar(title: Text(widget.title, style: t(18, w: FontWeight.w800))),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (widget.ranged) ...[
            Wrap(spacing: 8, runSpacing: 8, children: [for (final p in ['This month', 'Last month', 'This year', 'All time']) Chip2(p, selected: preset == p, onTap: () { _range(p); _reload(); })]),
            const SizedBox(height: 12),
          ],
          TextField(controller: _q, onChanged: (_) => setState(() {}), style: t(12, w: FontWeight.w500), decoration: dec(null, hint: 'Search', prefix: const Icon(Ic.search, size: 18, color: Color(0xFF778780)))),
          const SizedBox(height: 12),
          Expanded(
            child: FutureBuilder<List<RecRow>>(
              future: _fut,
              builder: (_, snap) {
                if (!snap.hasData) return const Center(child: CircularProgressIndicator(color: K.lime));
                final q = _q.text.toLowerCase();
                final rows = snap.data!.where((r) => q.isEmpty || r.title.toLowerCase().contains(q) || r.subtitle.toLowerCase().contains(q)).toList();
                final total = rows.fold<double>(0, (a, r) => a + r.amount);
                Widget tile(RecRow r) => Opacity(
                      opacity: r.dim ? .55 : 1,
                      child: Glass(
                        radius: 20,
                        padding: const EdgeInsets.all(14),
                        onTap: r.onTap == null ? null : () async { await r.onTap!(); if (mounted) _reload(); },
                        child: Row(children: [
                          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(r.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: t(13)),
                            const SizedBox(height: 4),
                            Text(r.subtitle, maxLines: 2, overflow: TextOverflow.ellipsis, style: t(10, w: FontWeight.w500, c: K.muted, h: 1.3)),
                            if (r.note != null) Padding(padding: const EdgeInsets.only(top: 3), child: Text(r.note!, style: t(10, w: FontWeight.w600, c: K.amber))),
                          ])),
                          const SizedBox(width: 10),
                          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                            Text(money(r.amount), style: t(13, w: FontWeight.w800)),
                            if (r.badge != null) Padding(padding: const EdgeInsets.only(top: 6), child: Badge2(r.badge!, color: r.badgeColor)),
                          ]),
                        ]),
                      ),
                    );
                return ListView(padding: const EdgeInsets.only(bottom: 28), children: [
                  Glass(
                    radius: 22,
                    padding: const EdgeInsets.all(16),
                    child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(widget.amountLabel.toUpperCase(), style: t(10, w: FontWeight.w800, c: K.muted, ls: 1.6)), const SizedBox(height: 4), Text(money(total), style: t(20, w: FontWeight.w800, ls: -0.6, c: K.lime))]),
                      Text('${rows.length} record${rows.length == 1 ? '' : 's'}', style: t(12, w: FontWeight.w600, c: K.muted)),
                    ]),
                  ),
                  const SizedBox(height: 12),
                  if (rows.isEmpty) Empty(widget.emptyText),
                  if (!wide) for (final r in rows) Padding(padding: const EdgeInsets.only(bottom: 10), child: tile(r)),
                  if (wide) GridView.builder(shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 520, mainAxisExtent: 96, crossAxisSpacing: 12, mainAxisSpacing: 10), itemCount: rows.length, itemBuilder: (_, i) => tile(rows[i])),
                ]);
              },
            ),
          ),
        ]),
      ),
    );
  }
}

String _payLabel(String code) => payTypes.entries.firstWhere((e) => e.value == code, orElse: () => MapEntry(code, code)).key;

// ------------------------------------------------------------------------------ hub
class RecordsHub extends StatelessWidget {
  const RecordsHub({super.key});
  @override
  Widget build(BuildContext context) {
    final items = <(IconData, String, String, Widget)>[
      (Ic.receipt, 'Sales', 'Every receipt issued, with return option', const SalesListScreen()),
      (Ic.bag, 'Purchases', 'Stock bought from suppliers, with return option', const PurchasesListScreen()),
      (Ic.refresh, 'Sales returns', 'Credit notes issued to customers', const SaleReturnsScreen()),
      (Ic.packagePlus, 'Purchase returns', 'Goods returned to suppliers (debit notes)', const PurchaseReturnsScreen()),
      (Ic.creditCard, 'Credit sales', 'Customers who owe you - receive payments', const CreditSalesScreen()),
      (Ic.clipboardCheck, 'Credit purchases', 'Suppliers you owe - record payments', const CreditPurchasesScreen()),
    ];
    final wide = isWide(context);
    Widget card((IconData, String, String, Widget) i) => Glass(
          radius: 22,
          padding: const EdgeInsets.all(18),
          onTap: () => Navigator.push(context, pageRoute(i.$4)),
          child: Row(children: [
            Container(width: 44, height: 44, decoration: BoxDecoration(color: const Color(0x1AC9FF55), borderRadius: BorderRadius.circular(14)), child: Icon(i.$1, size: 19, color: K.lime)),
            const SizedBox(width: 14),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(i.$2, style: t(14)), const SizedBox(height: 3), Text(i.$3, style: t(10, w: FontWeight.w500, c: K.muted, h: 1.3))])),
            const Icon(Ic.chevron, color: K.dim),
          ]),
        );
    return Scaffold(
      appBar: AppBar(title: Text('Sales & purchases records', style: t(18, w: FontWeight.w800))),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: wide
            ? GridView.count(crossAxisCount: 2, mainAxisSpacing: 12, crossAxisSpacing: 12, childAspectRatio: 3.2, children: [for (final i in items) card(i)])
            : ListView(children: [for (final i in items) Padding(padding: const EdgeInsets.only(bottom: 12), child: card(i))]),
      ),
    );
  }
}

// ------------------------------------------------------------------------------ pages
class SalesListScreen extends StatelessWidget {
  const SalesListScreen({super.key});
  @override
  Widget build(BuildContext context) => RecordPage(
        title: 'Sales',
        amountLabel: 'Total sales (before returns)',
        load: (c, f, t) async {
          final s = c.read<AppState>();
          final list = await s.repo.salesList(f, t);
          return [
            for (final x in list)
              RecRow(
                title: '#${x.number}${x.customerName.isEmpty ? '' : '  -  ${x.customerName}'}',
                subtitle: '${DateFormat('d MMM yyyy h:mm a').format(x.createdAt)}  -  ${_payLabel(x.paymentType)}',
                amount: x.totalIncl,
                badge: !x.fiscal ? 'Non-fiscal' : (x.uploaded ? 'TRA' : (x.uploadStatus == 'failed' ? 'Rejected' : 'Queued')),
                badgeColor: !x.fiscal ? K.muted : statusColor(x.uploaded ? 'uploaded' : x.uploadStatus),
                onTap: () async {
                  final full = await s.repo.getSale(x.id!);
                  if (c.mounted) await showSheet(c, ReceiptDetail(full));
                },
              ),
          ];
        },
      );
}

class PurchasesListScreen extends StatelessWidget {
  const PurchasesListScreen({super.key});
  @override
  Widget build(BuildContext context) => RecordPage(
        title: 'Purchases',
        amountLabel: 'Total purchases (before returns)',
        load: (c, f, t) async {
          final s = c.read<AppState>();
          final list = await s.repo.purchasesList(f, t);
          return [
            for (final p in list)
              RecRow(
                title: '${p.product}  x${fmtQty(p.qty)}',
                subtitle: '${p.date}  -  ${p.supplier.isEmpty ? 'No supplier' : p.supplier}${p.invoiceNo.isEmpty ? '' : '  -  inv ${p.invoiceNo}'}',
                amount: p.gross,
                badge: p.paid ? 'Paid' : 'On credit',
                badgeColor: p.paid ? K.lime : K.amber,
                note: p.returned > 0 ? 'Returned ${fmtQty(p.returned)} of ${fmtQty(p.qty)}' : null,
                onTap: () async {
                  await showSheet(c, PurchaseDetail(p: p));
                },
              ),
          ];
        },
      );
}

class SaleReturnsScreen extends StatelessWidget {
  const SaleReturnsScreen({super.key});
  @override
  Widget build(BuildContext context) => RecordPage(
        title: 'Sales returns',
        amountLabel: 'Total returned',
        emptyText: 'No sales returns. Open a sale and choose "Return items".',
        load: (c, f, t) async {
          final list = await c.read<AppState>().repo.saleReturns(f, t);
          return [
            for (final r in list)
              RecRow(
                title: '${r.number}  for  #${r.saleNumber}',
                subtitle: '${DateFormat('d MMM yyyy h:mm a').format(r.createdAt)}${r.reason.isEmpty ? '' : '  -  ${r.reason}'}',
                amount: r.totalIncl,
                badge: r.statusLabel,
                badgeColor: statusColor(r.uploadStatus),
                note: r.credit ? 'Credit sale: reduced customer balance' : null,
                onTap: () async {
                  await showSheet(c, SaleReturnDetail(id: r.id));
                },
              ),
          ];
        },
      );
}

class PurchaseReturnsScreen extends StatelessWidget {
  const PurchaseReturnsScreen({super.key});
  @override
  Widget build(BuildContext context) => RecordPage(
        title: 'Purchase returns',
        amountLabel: 'Total returned to suppliers',
        emptyText: 'No purchase returns. Open a purchase and choose "Return to supplier".',
        load: (c, f, t) async {
          final list = await c.read<AppState>().repo.purchaseReturns(f, t);
          return [
            for (final r in list)
              RecRow(
                title: '${r.number}  ${r.product}  x${fmtQty(r.qty)}',
                subtitle: '${r.day}  -  ${r.supplier.isEmpty ? 'No supplier' : r.supplier}${r.note.isEmpty ? '' : '  -  ${r.note}'}',
                amount: r.gross,
                badge: r.unpaid ? 'Reduced payable' : 'Cash back',
                badgeColor: r.unpaid ? K.amber : K.lime,
                note: 'Input VAT reversed: ${money(r.vat)}',
              ),
          ];
        },
      );
}

class CreditSalesScreen extends StatelessWidget {
  const CreditSalesScreen({super.key});
  @override
  Widget build(BuildContext context) => RecordPage(
        title: 'Credit sales',
        ranged: false,
        amountLabel: 'Customers owe you',
        emptyText: 'No credit sales. Choose "Credit (pay later)" when charging a customer.',
        load: (c, f, t) async {
          final list = await c.read<AppState>().repo.creditSales();
          list.sort((a, b) => a.settled == b.settled ? 0 : (a.settled ? 1 : -1));
          return [
            for (final d in list)
              RecRow(
                title: '${d.party}  -  #${d.number}',
                subtitle: '${d.date}  -  total ${money(d.total)}${d.returned > 0 ? '  -  returned ${money(d.returned)}' : ''}  -  paid ${money(d.paid)}',
                amount: d.settled ? 0 : d.balance,
                badge: d.settled ? 'Settled' : 'Owing',
                badgeColor: d.settled ? K.muted : K.amber,
                dim: d.settled,
                onTap: () async {
                  await showSheet(c, PaymentForm(kind: 'sale', doc: d));
                },
              ),
          ];
        },
      );
}

class CreditPurchasesScreen extends StatelessWidget {
  const CreditPurchasesScreen({super.key});
  @override
  Widget build(BuildContext context) => RecordPage(
        title: 'Credit purchases',
        ranged: false,
        amountLabel: 'You owe suppliers',
        emptyText: 'No credit purchases. Turn off "Already paid to supplier" when receiving stock.',
        load: (c, f, t) async {
          final list = await c.read<AppState>().repo.creditPurchases();
          list.sort((a, b) => a.settled == b.settled ? 0 : (a.settled ? 1 : -1));
          return [
            for (final d in list)
              RecRow(
                title: '${d.party}  -  #${d.number}',
                subtitle: '${d.date}  -  ${d.detail}  -  total ${money(d.total)}${d.returned > 0 ? '  -  returned ${money(d.returned)}' : ''}  -  paid ${money(d.paid)}',
                amount: d.settled ? 0 : d.balance,
                badge: d.settled ? 'Settled' : 'Owed',
                badgeColor: d.settled ? K.muted : K.amber,
                dim: d.settled,
                onTap: () async {
                  await showSheet(c, PaymentForm(kind: 'purchase', doc: d));
                },
              ),
          ];
        },
      );
}
