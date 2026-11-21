import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../data/app_state.dart';
import '../data/models.dart';
import '../data/tax.dart';
import 'icons.dart';
import 'theme.dart';
import 'widgets.dart';

Color statusColor(String s) => s == 'uploaded' ? K.lime : (s == 'failed' ? K.danger : (s == 'n/a' ? K.muted : K.amber));

// ============================================================ sales return (credit note)
class ReturnSheet extends StatefulWidget {
  const ReturnSheet({super.key, required this.sale});
  final Sale sale;
  @override
  State<ReturnSheet> createState() => _ReturnSheetState();
}

class _ReturnSheetState extends State<ReturnSheet> {
  List<ReturnableItem>? items;
  final qty = <int, double>{};
  final reason = TextEditingController();
  bool busy = false, canFiscal = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = context.read<AppState>();
    final l = await s.repo.returnableItems(widget.sale.id!);
    final cf = s.fiscalMode == 'supplier' && await s.vfd.hasCreditNote();
    if (mounted) setState(() { items = l; canFiscal = cf; });
  }

  double get refund => (items ?? []).fold(0.0, (a, r) => a + r.item.unitPrice * (qty[r.item.id] ?? 0));

  Future<void> _save() async {
    final s = context.read<AppState>();
    setState(() => busy = true);
    try {
      await s.createSaleReturn(widget.sale, {for (final e in qty.entries) if (e.value > 0) e.key: e.value}, reason.text.trim());
      if (mounted) {
        Navigator.pop(context);
        toast(context, 'Sales return recorded');
      }
    } on StateError catch (e) {
      if (mounted) toast(context, e.message);
      setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final credit = widget.sale.paymentType == 'INVOICE';
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Return items', style: t(18, w: FontWeight.w800)),
      Text('Receipt #${widget.sale.number}', style: t(11, w: FontWeight.w500, c: K.muted)),
      const SizedBox(height: 14),
      if (items == null) const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator(color: K.lime))),
      if (items != null && items!.every((r) => r.remaining <= 0)) const Empty('Everything on this receipt has already been returned.'),
      for (final r in items ?? <ReturnableItem>[])
        if (r.remaining > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Glass(
              radius: 16,
              padding: const EdgeInsets.all(12),
              child: Row(children: [
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(r.item.name, style: t(12)), Text('${money(r.item.unitPrice)}  -  can return ${fmtQty(r.remaining)}', style: t(10, w: FontWeight.w500, c: K.muted))])),
                IconBtn(Ic.minus, size: 34, onTap: () => setState(() => qty[r.item.id!] = ((qty[r.item.id] ?? 0) - 1).clamp(0, r.remaining).toDouble())),
                SizedBox(width: 34, child: Center(child: Text(fmtQty(qty[r.item.id] ?? 0), style: mono(12, w: FontWeight.w700)))),
                IconBtn(Ic.plus, size: 34, onTap: () => setState(() => qty[r.item.id!] = ((qty[r.item.id] ?? 0) + 1).clamp(0, r.remaining).toDouble())),
              ]),
            ),
          ),
      const SizedBox(height: 4),
      TextField(controller: reason, style: t(13, w: FontWeight.w500), decoration: dec('Reason (damaged, wrong item, customer changed mind...)')),
      const SizedBox(height: 12),
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(credit ? 'Reduces what the customer owes' : 'Refund to customer', style: t(12, w: FontWeight.w500, c: K.muted)), Text(money(refund), style: t(18, w: FontWeight.w800, c: K.lime))]),
      const SizedBox(height: 8),
      Text(!widget.sale.fiscal ? 'Non-fiscal sale: no credit note is needed.' : (canFiscal ? 'A credit note will be sent to your VFD supplier automatically.' : 'This was a fiscal sale. You must issue the credit note through your VFD supplier / TRA, then mark it issued here (Sales returns list).'), style: t(10, w: FontWeight.w600, c: canFiscal || !widget.sale.fiscal ? K.muted : K.amber, h: 1.4)),
      const SizedBox(height: 14),
      LimeButton('Create return', icon: Ic.check, busy: busy, onTap: refund <= 0 ? null : _save),
    ]);
  }
}

class SaleReturnDetail extends StatefulWidget {
  const SaleReturnDetail({super.key, required this.id});
  final int id;
  @override
  State<SaleReturnDetail> createState() => _SaleReturnDetailState();
}

class _SaleReturnDetailState extends State<SaleReturnDetail> {
  SaleReturn? r;
  final no = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final x = await context.read<AppState>().repo.saleReturn(widget.id);
    if (mounted) setState(() => r = x);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppState>();
    final x = r;
    if (x == null) return const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator(color: K.lime)));
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text('Credit note ${x.number}', style: t(17, w: FontWeight.w800)), Badge2(x.statusLabel, color: statusColor(x.uploadStatus))]),
      Text('For receipt #${x.saleNumber}  -  ${DateFormat('d MMM yyyy HH:mm').format(x.createdAt)}', style: t(11, w: FontWeight.w500, c: K.muted)),
      if (x.reason.isNotEmpty) Text('Reason: ${x.reason}', style: t(11, w: FontWeight.w500, c: K.muted)),
      const SizedBox(height: 12),
      for (final i in x.items) Padding(padding: const EdgeInsets.only(bottom: 6), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Expanded(child: Text('${fmtQty(i.qty)} x ${i.name}', style: t(12, w: FontWeight.w500))), Text(num0(i.amount), style: t(12))])),
      const Divider(color: Color(0x1AFFFFFF)),
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text('Net ${num0(x.totalExcl)}  -  VAT ${num0(x.totalVat)}', style: t(11, w: FontWeight.w500, c: K.muted)), Text(money(x.totalIncl), style: t(15, w: FontWeight.w800))]),
      Text(x.credit ? 'Credit sale: reduced the customer\'s balance.' : 'Cash sale: refund due to the customer.', style: t(10, w: FontWeight.w500, c: K.dim)),
      if (x.verifyCode.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text('Verification: ${x.verifyCode}', style: mono(10, c: K.muted))),
      if (x.lastError != null && x.uploadStatus != 'uploaded') Padding(padding: const EdgeInsets.only(top: 6), child: Text('Last error: ${x.lastError}', style: t(11, w: FontWeight.w600, c: K.danger))),
      if (x.uploadStatus == 'manual' || x.uploadStatus == 'failed') ...[
        const SizedBox(height: 14),
        TextField(controller: no, style: t(13, w: FontWeight.w500), decoration: dec('Credit note number / verification code (after issuing it)')),
        const SizedBox(height: 10),
        LimeButton('Mark as issued', icon: Ic.check, outline: true, onTap: () async {
          if (no.text.trim().isEmpty) return toast(context, 'Enter the credit note number');
          await s.repo.markReturnFiscalised(x.id, fiscalNo: no.text.trim(), verifyCode: no.text.trim());
          await s.refresh();
          await _load();
        }),
        FutureBuilder<bool>(
          future: s.fiscalMode == 'supplier' ? s.vfd.hasCreditNote() : Future.value(false),
          builder: (_, snap) => snap.data == true
              ? Padding(padding: const EdgeInsets.only(top: 8), child: LimeButton('Retry sending to supplier', icon: Ic.refresh, onTap: () async {
                  await s.repo.requeueReturn(x.id);
                  await s.syncNow();
                  await _load();
                }))
              : const SizedBox(),
        ),
      ],
    ]);
  }
}

// ======================================================================== purchase side
class PurchaseDetail extends StatelessWidget {
  const PurchaseDetail({super.key, required this.p});
  final Purchase p;
  @override
  Widget build(BuildContext context) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Expanded(child: Text(p.product, style: t(17, w: FontWeight.w800))), Badge2(p.paid ? 'Paid' : 'On credit', color: p.paid ? K.lime : K.amber)]),
        const SizedBox(height: 4),
        Text('${p.date}  -  ${p.supplier.isEmpty ? 'No supplier' : p.supplier}${p.supplierTin.isEmpty ? '' : '  -  TIN ${p.supplierTin}'}', style: t(11, w: FontWeight.w500, c: K.muted)),
        if (p.invoiceNo.isNotEmpty) Text('Invoice ${p.invoiceNo}', style: t(11, w: FontWeight.w500, c: K.muted)),
        if (p.efdReceipt.isNotEmpty) Text('EFD verification code ${p.efdReceipt}', style: mono(10, c: K.muted)),
        const SizedBox(height: 14),
        _kv('Quantity', fmtQty(p.qty)),
        _kv('Net (excl. VAT)', money(p.net)),
        _kv('Input VAT', money(p.vat)),
        _kv('Gross', money(p.gross)),
        if (p.returned > 0) _kv('Returned to supplier', fmtQty(p.returned)),
        const SizedBox(height: 16),
        LimeButton('Return to supplier', icon: Ic.refresh, outline: true, onTap: p.returnable <= 0 ? null : () => showSheet(context, PurchaseReturnSheet(p: p))),
      ]);

  Widget _kv(String k, String v) => Padding(padding: const EdgeInsets.only(bottom: 6), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(k, style: t(12, w: FontWeight.w500, c: K.muted)), Text(v, style: t(12))]));
}

class PurchaseReturnSheet extends StatefulWidget {
  const PurchaseReturnSheet({super.key, required this.p});
  final Purchase p;
  @override
  State<PurchaseReturnSheet> createState() => _PurchaseReturnSheetState();
}

class _PurchaseReturnSheetState extends State<PurchaseReturnSheet> {
  late final qty = TextEditingController(text: fmtQty(widget.p.returnable));
  final note = TextEditingController();
  bool busy = false;

  @override
  Widget build(BuildContext context) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Return to supplier', style: t(18, w: FontWeight.w800)),
        Text('${widget.p.product}  -  can return ${fmtQty(widget.p.returnable)}', style: t(11, w: FontWeight.w500, c: K.muted)),
        const SizedBox(height: 14),
        TextField(controller: qty, keyboardType: const TextInputType.numberWithOptions(decimal: true), style: t(13, w: FontWeight.w500), decoration: dec('Quantity returned')),
        const SizedBox(height: 12),
        TextField(controller: note, style: t(13, w: FontWeight.w500), decoration: dec('Reason / debit note reference')),
        const SizedBox(height: 8),
        Text(widget.p.paid ? 'You already paid this purchase: the amount becomes cash back / supplier credit.' : 'This purchase is on credit: the amount reduces what you owe the supplier.', style: t(10, w: FontWeight.w600, c: K.muted, h: 1.4)),
        const SizedBox(height: 14),
        LimeButton('Record return', icon: Ic.check, busy: busy, onTap: () async {
          final q = double.tryParse(qty.text);
          if (q == null || q <= 0) return toast(context, 'Enter the quantity');
          setState(() => busy = true);
          try {
            await context.read<AppState>().createPurchaseReturn(widget.p.id!, q, note.text.trim());
            if (context.mounted) {
              Navigator.pop(context);
              toast(context, 'Purchase return recorded');
            }
          } on StateError catch (e) {
            if (context.mounted) toast(context, e.message);
            setState(() => busy = false);
          }
        }),
      ]);
}

// ============================================================== credit payments
class PaymentForm extends StatefulWidget {
  const PaymentForm({super.key, required this.kind, required this.doc});
  final String kind; // 'sale' or 'purchase'
  final CreditDoc doc;
  @override
  State<PaymentForm> createState() => _PaymentFormState();
}

class _PaymentFormState extends State<PaymentForm> {
  late final amount = TextEditingController(text: widget.doc.balance > 0 ? widget.doc.balance.toStringAsFixed(0) : '');
  final note = TextEditingController();
  List<Map<String, Object?>> history = [];

  @override
  void initState() {
    super.initState();
    context.read<AppState>().repo.payments(widget.kind, widget.doc.id).then((h) {
      if (mounted) setState(() => history = h);
    });
  }

  @override
  Widget build(BuildContext context) {
    final sale = widget.kind == 'sale';
    final d = widget.doc;
    Widget kv(String k, String v, {bool bold = false}) => Padding(padding: const EdgeInsets.only(bottom: 6), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(k, style: t(12, w: FontWeight.w500, c: K.muted)), Text(v, style: t(12, w: bold ? FontWeight.w800 : FontWeight.w700, c: bold ? K.lime : Colors.white))]));
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(sale ? 'Receive payment' : 'Pay supplier', style: t(18, w: FontWeight.w800)),
      Text('${d.party}  -  #${d.number}  -  ${d.date}', style: t(11, w: FontWeight.w500, c: K.muted)),
      const SizedBox(height: 14),
      kv('Total', money(d.total)),
      if (d.returned > 0) kv('Returned', '- ${money(d.returned)}'),
      kv('Paid so far', money(d.paid)),
      kv('Balance', money(d.balance), bold: true),
      if (history.isNotEmpty) ...[
        const SizedBox(height: 8),
        Text('PAYMENTS', style: t(10, w: FontWeight.w800, c: K.muted, ls: 1.6)),
        const SizedBox(height: 6),
        for (final h in history) Padding(padding: const EdgeInsets.only(bottom: 4), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text('${h['date']}  ${h['note'] ?? ''}', style: t(11, w: FontWeight.w500, c: K.muted)), Text(money((h['amount'] as num).toDouble()), style: t(11))])),
      ],
      if (!d.settled) ...[
        const SizedBox(height: 14),
        TextField(controller: amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), style: t(13, w: FontWeight.w500), decoration: dec('Amount (TZS)')),
        const SizedBox(height: 12),
        TextField(controller: note, style: t(13, w: FontWeight.w500), decoration: dec('Note (method, reference)')),
        const SizedBox(height: 16),
        LimeButton(sale ? 'Record payment received' : 'Record payment made', icon: Ic.check, onTap: () async {
          final a = double.tryParse(amount.text.replaceAll(',', ''));
          if (a == null || a <= 0) return toast(context, 'Enter the amount');
          if (a > d.balance + 0.5) return toast(context, 'That is more than the balance');
          await context.read<AppState>().addPayment(widget.kind, d.id, a, note.text.trim());
          if (context.mounted) Navigator.pop(context);
        }),
      ],
    ]);
  }
}
