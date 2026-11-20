import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../data/app_state.dart';
import '../data/models.dart';
import '../data/tax.dart';
import '../data/platform_info.dart';
import 'responsive.dart';
import 'scanner_listener.dart';
import 'scanner_screen.dart';
import 'icons.dart';
import 'theme.dart';
import 'widgets.dart';

class PosScreen extends StatelessWidget {
  const PosScreen({super.key});

  Future<void> _scan(BuildContext context) async {
    if (!hasCamera) return toast(context, 'Just scan with your USB / Bluetooth barcode scanner on this screen, or use the search icon');
    final s = context.read<AppState>();
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ScannerScreen(
          continuous: true,
          title: 'Scan items',
          onCode: (code) async {
            final p = await s.repo.findByCode(code);
            if (p == null) return 'Unknown code $code';
            final err = s.addToCart(p);
            return err ?? 'Added: ${p.name}  (${s.cart.fold<double>(0, (a, l) => a + l.qty).toStringAsFixed(0)} items)';
          },
        ),
      ),
    );
  }

  /// External scanner: add the scanned product straight to the cart.
  Future<void> _onExternalScan(BuildContext context, String code) async {
    final s = context.read<AppState>();
    final p = await s.repo.findByCode(code);
    if (!context.mounted) return;
    if (p == null) {
      HapticFeedback.heavyImpact();
      return toast(context, 'Unknown barcode $code');
    }
    final err = s.addToCart(p);
    HapticFeedback.lightImpact();
    SystemSound.play(SystemSoundType.click);
    toast(context, err ?? 'Added: ${p.name}');
  }

  void _catalogue(BuildContext context) => showSheet(context, const _Catalogue());

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    // VAT breakdown per class
    final byClass = <String, double>{};
    for (final l in s.cart) {
      byClass[l.product.taxCode] = (byClass[l.product.taxCode] ?? 0) + l.amount;
    }
    var net = 0.0, vat = 0.0;
    final vatRows = <MapEntry<String, double>>[];
    byClass.forEach((c, g) {
      final x = splitGross(r2(g), c);
      net += x.net;
      vat += x.vat;
      if ((taxRates[c] ?? 0) > 0) vatRows.add(MapEntry(c, x.vat));
    });
    final total = s.cartTotal;

    final scanCard = <Widget>[
          GestureDetector(
            onTap: () => _scan(context),
            child: Container(
              height: 58,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(color: const Color(0x12C9FF55), borderRadius: BorderRadius.circular(20), border: Border.all(color: const Color(0x40C9FF55))),
              child: Row(children: [
                Container(width: 36, height: 36, decoration: BoxDecoration(color: K.lime, borderRadius: BorderRadius.circular(12)), child: const Icon(Ic.scan, color: Colors.black, size: 20)),
                const SizedBox(width: 12),
                Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [Text(hasCamera ? 'Scan item barcode' : 'Scan with your barcode scanner', style: t(12)), Text(hasCamera ? 'or tap the magnifier to search catalogue' : 'or tap the magnifier to search the catalogue', style: t(10, w: FontWeight.w500, c: const Color(0xFF71827A)))])),
                GestureDetector(onTap: () => _catalogue(context), child: const Padding(padding: EdgeInsets.all(8), child: Icon(Ic.search, size: 20, color: K.lime))),
              ]),
            ),
          ),
    ];
    final cartList = <Widget>[
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text('Current order', style: t(14, w: FontWeight.w800)),
            Row(children: [
              if (s.cart.isNotEmpty) GestureDetector(onTap: s.clearCart, child: Padding(padding: const EdgeInsets.only(right: 10), child: Text('Clear', style: t(11, c: K.danger)))),
              Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5), decoration: BoxDecoration(color: const Color(0x12FFFFFF), borderRadius: BorderRadius.circular(30)), child: Text('${s.cart.length} items', style: t(10, c: const Color(0xFFA5B2AC)))),
            ]),
          ]),
          const SizedBox(height: 12),
          if (s.cart.isEmpty) const Empty('Cart is empty. Scan an item or search the catalogue.'),
          for (final l in s.cart)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Glass(
                radius: 22,
                padding: const EdgeInsets.all(12),
                child: Row(children: [
                  Avatar(l.product),
                  const SizedBox(width: 12),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(l.product.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: t(12)), const SizedBox(height: 6), Text(money(l.product.price), style: t(11, w: FontWeight.w800, c: K.lime))])),
                  _Step(Ic.minus, () => s.changeQty(l, -1)),
                  SizedBox(width: 30, child: Center(child: Text(fmtQty(l.qty), style: mono(12, w: FontWeight.w700)))),
                  _Step(Ic.plus, () {
                    final e = s.changeQty(l, 1);
                    if (e != null) toast(context, e);
                  }),
                ]),
              ),
            ),
          const SizedBox(height: 6),
          Glass(
            radius: 26,
            padding: const EdgeInsets.all(20),
            color: K.sheet,
            child: Column(children: [
              _Row('Subtotal (excl. VAT)', money(net)),
              const SizedBox(height: 10),
              for (final v in vatRows) ...[_Row('VAT ${(taxRates[v.key]! * 100).toStringAsFixed(0)}%  [${v.key}]', money(v.value)), const SizedBox(height: 10)],
              if (vatRows.isEmpty && s.cart.isNotEmpty) ...[_Row('VAT', money(vat)), const SizedBox(height: 10)],
              const Divider(color: Color(0x1AFFFFFF), height: 22),
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, crossAxisAlignment: CrossAxisAlignment.end, children: [Text('Total', style: t(12, c: const Color(0xFF8C9B94))), Text(money(total), style: t(24, w: FontWeight.w800, ls: -1))]),
              const SizedBox(height: 18),
              LimeButton('Charge customer', icon: Ic.creditCard, onTap: s.cart.isEmpty ? null : () => showSheet(context, _PaymentSheet(total: total, host: context))),
            ]),
          ),
    ];
    final header = Header(title: 'Point of Sale', subtitle: s.registered ? 'VFD ${s.cfg['serial'] ?? ''} - ${s.online ? 'Online' : 'Offline'}' : 'Non-fiscal mode - VFD not registered');
    if (!isWide(context)) {
      return ScannerListener(
        onScan: (code) => _onExternalScan(context, code),
        child: ListView(padding: EdgeInsets.only(bottom: bottomPad(context)), children: [
          header,
          Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [...scanCard, const SizedBox(height: 18), ...cartList])),
        ]),
      );
    }
    // Desktop / tablet: product catalogue on the left, the order on the right
    return ScannerListener(
      onScan: (code) => _onExternalScan(context, code),
      child: Column(children: [
        header,
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(28, 0, 28, 24),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Expanded(child: _CatalogPane()),
              const SizedBox(width: 24),
              SizedBox(width: 430, child: ListView(padding: EdgeInsets.zero, children: cartList)),
            ]),
          ),
        ),
      ]),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.l, this.v);
  final String l, v;
  @override
  Widget build(BuildContext context) => Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(l, style: t(12, w: FontWeight.w500, c: const Color(0xFF809087))), Text(v, style: t(12, w: FontWeight.w600))]);
}

class _Step extends StatelessWidget {
  const _Step(this.icon, this.onTap);
  final IconData icon;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => GestureDetector(onTap: onTap, child: Container(width: 34, height: 34, decoration: BoxDecoration(color: const Color(0x12FFFFFF), borderRadius: BorderRadius.circular(12)), child: Icon(icon, size: 16)));
}

// -------------------------------------------------------------------- catalogue
class _Catalogue extends StatefulWidget {
  const _Catalogue();
  @override
  State<_Catalogue> createState() => _CatalogueState();
}

class _CatalogueState extends State<_Catalogue> {
  String q = '';
  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final l = q.toLowerCase();
    final list = s.products.where((p) => p.name.toLowerCase().contains(l) || p.sku.toLowerCase().contains(l) || p.barcode.contains(q)).take(30).toList();
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Search catalogue', style: t(16, w: FontWeight.w800)),
      const SizedBox(height: 12),
      TextField(
        autofocus: true,
        style: t(13, w: FontWeight.w500),
        decoration: dec(null, hint: 'Name, SKU or barcode (USB/Bluetooth scanner works here)', prefix: const Icon(Ic.search, size: 18)),
        onChanged: (v) => setState(() => q = v),
        onSubmitted: (v) async {
          // a hardware barcode scanner "types" the code then presses Enter
          final p = await s.repo.findByCode(v.trim());
          if (p != null) {
            final e = s.addToCart(p);
            if (e != null && context.mounted) toast(context, e);
            setState(() => q = '');
          }
        },
      ),
      const SizedBox(height: 12),
      for (final p in list)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Glass(
            radius: 18,
            padding: const EdgeInsets.all(10),
            onTap: p.stock <= 0
                ? null
                : () {
                    final e = s.addToCart(p);
                    if (e != null) toast(context, e);
                  },
            child: Row(children: [
              Avatar(p, size: 40),
              const SizedBox(width: 10),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: t(12)), Text('${money(p.price)}  -  ${fmtQty(p.stock)} ${p.unit}', style: t(10, w: FontWeight.w500, c: K.muted))])),
              Icon(p.stock <= 0 ? Ic.ban : Ic.circlePlus, color: p.stock <= 0 ? K.dim : K.lime, size: 20),
            ]),
          ),
        ),
    ]);
  }
}

// ---------------------------------------------------------------------- payment
class _PaymentSheet extends StatefulWidget {
  const _PaymentSheet({required this.total, required this.host});
  final double total;
  final BuildContext host; // POS screen context - stays mounted after this sheet closes
  @override
  State<_PaymentSheet> createState() => _PaymentSheetState();
}

class _PaymentSheetState extends State<_PaymentSheet> {
  String method = 'Cash';
  final tendered = TextEditingController();
  final name = TextEditingController();
  final tin = TextEditingController();
  final mobile = TextEditingController();
  bool busy = false;

  Future<void> _approve() async {
    final s = context.read<AppState>();
    final nav = Navigator.of(context);
    final host = widget.host;
    if (payTypes[method] == 'INVOICE' && name.text.trim().isEmpty) return toast(context, 'Enter the customer name for a credit sale');
    setState(() => busy = true);
    try {
      final sale = await s.approveSale(payment: payTypes[method]!, custName: name.text.trim(), custTin: tin.text.trim(), mobile: mobile.text.trim());
      nav.pop();
      if (host.mounted) showSheet(host, _SuccessSheet(sale));
    } on StateError catch (e) {
      if (mounted) toast(context, e.message);
      setState(() => busy = false);
    } catch (e) {
      if (mounted) toast(context, 'Could not complete sale: $e');
      setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final paid = double.tryParse(tendered.text.replaceAll(',', ''));
    final change = paid == null ? null : paid - widget.total;
    final s = context.read<AppState>();
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Payment', style: t(18, w: FontWeight.w800)),
      const SizedBox(height: 4),
      Text(money(widget.total), style: t(28, w: FontWeight.w800, ls: -1.2, c: K.lime)),
      const SizedBox(height: 16),
      Wrap(spacing: 8, runSpacing: 8, children: [for (final m in payTypes.keys) Chip2(m, selected: method == m, onTap: () => setState(() => method = m))]),
      if (method == 'Cash') ...[
        const SizedBox(height: 14),
        TextField(controller: tendered, keyboardType: TextInputType.number, onChanged: (_) => setState(() {}), style: t(14, w: FontWeight.w600), decoration: dec('Cash received (TZS)')),
        if (change != null) Padding(padding: const EdgeInsets.only(top: 8, left: 4), child: Text(change >= 0 ? 'Change: ${money(change)}' : 'Short by ${money(-change)}', style: t(12, c: change >= 0 ? K.lime : K.danger))),
      ],
      const SizedBox(height: 14),
      Text('CUSTOMER (OPTIONAL)', style: t(10, w: FontWeight.w800, c: K.muted, ls: 1.6)),
      const SizedBox(height: 8),
      TextField(controller: name, style: t(13, w: FontWeight.w500), decoration: dec('Customer name')),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(child: TextField(controller: tin, style: t(13, w: FontWeight.w500), decoration: dec('Customer TIN'))),
        const SizedBox(width: 10),
        Expanded(child: TextField(controller: mobile, keyboardType: TextInputType.phone, style: t(13, w: FontWeight.w500), decoration: dec('Mobile'))),
      ]),
      const SizedBox(height: 18),
      if (!s.registered) Padding(padding: const EdgeInsets.only(bottom: 10), child: Text('VFD not registered: this sale will be recorded as NON-FISCAL and will not be sent to TRA.', style: t(11, w: FontWeight.w600, c: K.amber))),
      LimeButton(s.registered ? 'Approve & fiscalise' : 'Approve sale', icon: Ic.verified, busy: busy, onTap: (method == 'Cash' && change != null && change < 0) ? null : _approve),
    ]);
  }
}

// ---------------------------------------------------------------------- success
class _SuccessSheet extends StatefulWidget {
  const _SuccessSheet(this.sale);
  final Sale sale;
  @override
  State<_SuccessSheet> createState() => _SuccessSheetState();
}

class _SuccessSheetState extends State<_SuccessSheet> {
  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final sale = s.live(widget.sale);
    final status = !sale.fiscal ? ('Non-fiscal receipt (VFD not registered)', K.amber) : sale.uploaded ? ('Accepted by TRA', K.lime) : sale.uploadStatus == 'failed' ? ('TRA rejected - see TRA tab', K.danger) : (s.online ? 'Sending to TRA...' : 'Queued - will upload when online', K.amber);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 64, height: 64, decoration: const BoxDecoration(color: K.lime, shape: BoxShape.circle), child: const Icon(Ic.check, size: 32, color: Colors.black)),
      const SizedBox(height: 16),
      Text('Payment complete', style: t(20, w: FontWeight.w800)),
      const SizedBox(height: 6),
      Text('${sale.fiscal ? 'Fiscal receipt' : 'Receipt'} #${sale.number}  -  ${money(sale.totalIncl)}', style: t(12, w: FontWeight.w500, c: const Color(0xFF86958E))),
      const SizedBox(height: 10),
      Badge2(status.$1, color: status.$2),
      if (sale.fiscal && sale.verifyUrl.isNotEmpty) ...[
        const SizedBox(height: 16),
        Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)), child: QrImageView(data: sale.verifyUrl, size: 112, padding: EdgeInsets.zero)),
        const SizedBox(height: 8),
        if (sale.rctvnum.isNotEmpty) Text('Verification code ${sale.rctvnum}', style: mono(11, c: K.muted)),
      ],
      const SizedBox(height: 18),
      Row(children: [
        Expanded(child: LimeButton('Print', icon: Ic.printer, onTap: () async => toast(context, await s.printReceipt(widget.sale)))),
        const SizedBox(width: 10),
        Expanded(child: LimeButton('PDF / Share', icon: Ic.pdf, outline: true, onTap: () => s.printer.sharePdf(context, widget.sale, s.cfg))),
      ]),
      const SizedBox(height: 8),
      GestureDetector(onTap: () => s.printer.printPdf(widget.sale, s.cfg), child: Padding(padding: const EdgeInsets.all(6), child: Text('Print via system / Wi-Fi printer', style: t(11, c: K.lime)))),
      const SizedBox(height: 4),
      GestureDetector(
        onTap: () => Navigator.pop(context),
        child: Container(width: double.infinity, padding: const EdgeInsets.symmetric(vertical: 15), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)), child: Center(child: Text('Done', style: t(12, w: FontWeight.w800, c: Colors.black)))),
      ),
      const SizedBox(height: 4),
      Text(DateFormat('dd MMM yyyy HH:mm').format(sale.createdAt), style: t(9, w: FontWeight.w500, c: K.dim)),
    ]);
  }
}


// ------------------------------------------------------------ desktop catalogue pane
class _CatalogPane extends StatefulWidget {
  const _CatalogPane();
  @override
  State<_CatalogPane> createState() => _CatalogPaneState();
}

class _CatalogPaneState extends State<_CatalogPane> {
  final _q = TextEditingController();
  final _focus = FocusNode();
  String _cat = '';

  @override
  void dispose() {
    _q.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Enter (typed or from a barcode scanner): exact barcode/SKU match goes straight into the cart.
  Future<void> _submit(AppState s, String v) async {
    final code = v.trim();
    if (code.isNotEmpty) {
      final p = await s.repo.findByCode(code);
      if (!mounted) return;
      if (p != null) {
        final e = s.addToCart(p);
        HapticFeedback.lightImpact();
        toast(context, e ?? 'Added: ${p.name}');
        _q.clear();
        setState(() {});
      }
    }
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final q = _q.text.toLowerCase();
    final list = s.products.where((p) => (_cat.isEmpty || p.category == _cat) && (p.name.toLowerCase().contains(q) || p.sku.toLowerCase().contains(q) || p.barcode.contains(_q.text))).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      TextField(
        controller: _q,
        focusNode: _focus,
        autofocus: true,
        onChanged: (_) => setState(() {}),
        onEditingComplete: () {},
        onSubmitted: (v) => _submit(s, v),
        style: t(13, w: FontWeight.w500),
        decoration: dec(null, hint: 'Scan a barcode or search products', prefix: const Icon(Ic.scan, size: 18, color: K.lime)),
      ),
      const SizedBox(height: 12),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          Chip2('All', selected: _cat.isEmpty, onTap: () => setState(() => _cat = '')),
          for (final c in s.categories) Padding(padding: const EdgeInsets.only(left: 8), child: Chip2(c, selected: _cat == c, onTap: () => setState(() => _cat = c))),
        ]),
      ),
      const SizedBox(height: 14),
      Expanded(
        child: list.isEmpty
            ? Empty(s.products.isEmpty ? 'No products yet. Add them in the Stock tab.' : 'No products match.')
            : GridView.builder(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 210, mainAxisExtent: 138, crossAxisSpacing: 12, mainAxisSpacing: 12),
                itemCount: list.length,
                itemBuilder: (_, i) {
                  final p = list[i];
                  final out = p.stock <= 0;
                  return Opacity(
                    opacity: out ? .45 : 1,
                    child: Glass(
                      radius: 20,
                      padding: const EdgeInsets.all(12),
                      onTap: () {
                        final e = out ? 'Out of stock' : s.addToCart(p);
                        if (e != null) toast(context, e);
                        _focus.requestFocus();
                      },
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Avatar(p, size: 36), Badge2('${fmtQty(p.stock)} ${p.unit}', color: p.low ? const Color(0xFFFF8066) : K.lime)]),
                        const SizedBox(height: 10),
                        Expanded(child: Text(p.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: t(12))),
                        Text(money(p.price), style: t(12, w: FontWeight.w800, c: K.lime)),
                      ]),
                    ),
                  );
                },
              ),
      ),
    ]);
  }
}
