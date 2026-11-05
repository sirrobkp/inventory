import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/app_state.dart';
import '../data/models.dart';
import '../data/tax.dart';
import 'scanner_screen.dart';
import 'icons.dart';
import 'theme.dart';
import 'widgets.dart';

class InventoryScreen extends StatefulWidget {
  const InventoryScreen({super.key});
  @override
  State<InventoryScreen> createState() => _InventoryScreenState();
}

class _InventoryScreenState extends State<InventoryScreen> {
  String _q = '';
  bool _lowOnly = false;
  String? _cat;
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final s = context.read<AppState>();
    final code = await Navigator.push<String>(context, MaterialPageRoute(builder: (_) => ScannerScreen(title: 'Scan to find product', onCode: (c) async => null)));
    if (code == null || !mounted) return;
    final p = await s.repo.findByCode(code);
    if (!mounted) return;
    if (p != null) {
      _openProduct(p);
    } else {
      toast(context, 'No product with code $code - add it now');
      showSheet(context, ProductForm(barcode: code));
    }
  }

  void _openProduct(Product p) => showSheet(context, _ProductActions(p));

  Future<void> _pickCategory(AppState s) async {
    final c = await showSheet<String>(
      context,
      Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Category', style: t(16, w: FontWeight.w800)),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          Chip2('All', selected: _cat == null, onTap: () => Navigator.pop(context, '')),
          for (final c in s.categories) Chip2(c, selected: _cat == c, onTap: () => Navigator.pop(context, c)),
        ]),
      ]),
    );
    if (c != null) setState(() => _cat = c.isEmpty ? null : c);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final q = _q.toLowerCase();
    final list = s.products.where((p) {
      final m = p.name.toLowerCase().contains(q) || p.sku.toLowerCase().contains(q) || p.barcode.contains(q);
      return m && (!_lowOnly || p.low) && (_cat == null || p.category == _cat);
    }).toList();
    return ListView(padding: const EdgeInsets.only(bottom: 130), children: [
      Header(title: 'Inventory', subtitle: '${s.products.length} products'),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: TextField(
                controller: _search,
                onChanged: (v) => setState(() => _q = v),
                style: t(12, w: FontWeight.w500),
                decoration: dec(null, hint: 'Search product, SKU or barcode', prefix: const Icon(Ic.search, size: 18, color: Color(0xFF778780))),
              ),
            ),
            const SizedBox(width: 8),
            IconBtn(Ic.scan, filled: true, size: 50, onTap: _scan),
          ]),
          const SizedBox(height: 14),
          Wrap(spacing: 8, children: [
            Chip2('All', selected: !_lowOnly, onTap: () => setState(() => _lowOnly = false)),
            Chip2('Low stock', selected: _lowOnly, onTap: () => setState(() => _lowOnly = true)),
            Chip2(_cat ?? 'Category', selected: _cat != null, onTap: () => _pickCategory(s)),
          ]),
          const SizedBox(height: 16),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, crossAxisAlignment: CrossAxisAlignment.end, children: [
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('TOTAL STOCK VALUE (AT COST)', style: t(10, w: FontWeight.w800, c: const Color(0xFF718079), ls: 1.8)),
              const SizedBox(height: 4),
              Text(money(s.dash.stockValue), style: t(18, w: FontWeight.w800, ls: -0.5)),
            ]),
            Text('Updated now', style: t(10, c: K.lime)),
          ]),
          const SizedBox(height: 12),
          if (list.isEmpty) Empty(s.products.isEmpty ? 'No products yet.\nTap "Add new product" to start your catalogue.' : 'No products match your filters.'),
          for (final p in list)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Glass(
                radius: 22,
                padding: const EdgeInsets.all(14),
                onTap: () => _openProduct(p),
                child: Row(children: [
                  Avatar(p),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: t(13)),
                      const SizedBox(height: 4),
                      Text(p.sku, style: mono(9, c: const Color(0xFF66776F))),
                      const SizedBox(height: 6),
                      Text('${money(p.price)}  -  VAT ${p.taxCode}', style: t(11, c: const Color(0xFFB9C4BF))),
                    ]),
                  ),
                  Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Badge2('${fmtQty(p.stock)} ${p.unit}', color: p.low ? const Color(0xFFFF8066) : K.lime),
                    const SizedBox(height: 8),
                    Text(p.stock <= 0 ? 'Out of stock' : p.low ? 'Low stock' : 'In stock', style: t(9, w: FontWeight.w500, c: K.dim)),
                  ]),
                ]),
              ),
            ),
          const SizedBox(height: 6),
          GestureDetector(
            onTap: () => showSheet(context, const ProductForm()),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 15),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(20), border: Border.all(color: const Color(0x66C9FF55))),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [const Icon(Ic.plus, size: 18, color: K.lime), const SizedBox(width: 8), Text('Add new product', style: t(12, c: K.lime))]),
            ),
          ),
        ]),
      ),
    ]);
  }
}

// ---------------------------------------------------------------- product form
class ProductForm extends StatefulWidget {
  const ProductForm({super.key, this.product, this.barcode});
  final Product? product;
  final String? barcode;
  @override
  State<ProductForm> createState() => _ProductFormState();
}

class _ProductFormState extends State<ProductForm> {
  late final name = TextEditingController(text: widget.product?.name);
  late final sku = TextEditingController(text: widget.product?.sku);
  late final barcode = TextEditingController(text: widget.product?.barcode ?? widget.barcode);
  late final category = TextEditingController(text: widget.product?.category ?? 'General');
  late final unit = TextEditingController(text: widget.product?.unit ?? 'pc');
  late final price = TextEditingController(text: widget.product == null ? '' : fmtQty(widget.product!.price));
  late final cost = TextEditingController(text: widget.product == null ? '' : fmtQty(widget.product!.cost));
  late final stock = TextEditingController();
  late final reorder = TextEditingController(text: fmtQty(widget.product?.reorderLevel ?? 5));
  late String tax = widget.product?.taxCode ?? 'A';
  bool get edit => widget.product != null;

  Future<void> _scan() async {
    final c = await Navigator.push<String>(context, MaterialPageRoute(builder: (_) => ScannerScreen(onCode: (c) async => null)));
    if (c != null) setState(() => barcode.text = c);
  }

  Future<void> _save() async {
    final s = context.read<AppState>();
    final pr = double.tryParse(price.text.replaceAll(',', ''));
    if (name.text.trim().isEmpty || pr == null || pr <= 0) return toast(context, 'Name and a valid selling price are required');
    final code = sku.text.trim().isEmpty ? 'SKU-${DateTime.now().millisecondsSinceEpoch % 100000000}' : sku.text.trim();
    final p = Product(
      id: widget.product?.id,
      name: name.text.trim(),
      sku: code,
      barcode: barcode.text.trim(),
      category: category.text.trim().isEmpty ? 'General' : category.text.trim(),
      unit: unit.text.trim().isEmpty ? 'pc' : unit.text.trim(),
      price: pr,
      cost: double.tryParse(cost.text.replaceAll(',', '')) ?? 0,
      stock: double.tryParse(stock.text) ?? 0,
      reorderLevel: double.tryParse(reorder.text) ?? 5,
      taxCode: tax,
    );
    try {
      await s.saveProduct(p);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) toast(context, e.toString().contains('UNIQUE') ? 'SKU already exists' : '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget f(TextEditingController c, String l, {TextInputType? k, String? hint, Widget? suffix}) => Padding(padding: const EdgeInsets.only(bottom: 12), child: TextField(controller: c, keyboardType: k, style: t(13, w: FontWeight.w500), decoration: dec(l, hint: hint, suffix: suffix)));
    const numKb = TextInputType.numberWithOptions(decimal: true);
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(edit ? 'Edit product' : 'New product', style: t(18, w: FontWeight.w800)),
      const SizedBox(height: 16),
      f(name, 'Product name'),
      Row(children: [Expanded(child: f(sku, 'SKU', hint: 'auto if empty')), const SizedBox(width: 10), Expanded(child: f(barcode, 'Barcode', suffix: IconButton(onPressed: _scan, icon: const Icon(Ic.scan, size: 18, color: K.lime))))]),
      Row(children: [Expanded(child: f(category, 'Category')), const SizedBox(width: 10), Expanded(child: f(unit, 'Unit'))]),
      Row(children: [Expanded(child: f(price, 'Selling price (incl. VAT)', k: numKb)), const SizedBox(width: 10), Expanded(child: f(cost, 'Cost (excl. VAT)', k: numKb))]),
      Row(children: [if (!edit) ...[Expanded(child: f(stock, 'Opening stock', k: numKb)), const SizedBox(width: 10)], Expanded(child: f(reorder, 'Reorder level', k: numKb))]),
      DropdownButtonFormField<String>(
        initialValue: tax,
        dropdownColor: K.sheet,
        decoration: dec('VAT class'),
        style: t(13, w: FontWeight.w500),
        items: [for (final e in taxNames.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
        onChanged: (v) => setState(() => tax = v ?? 'A'),
      ),
      const SizedBox(height: 18),
      LimeButton(edit ? 'Save changes' : 'Add product', icon: Ic.check, onTap: _save),
    ]);
  }
}

// ----------------------------------------------------------------- actions sheet
class _ProductActions extends StatelessWidget {
  const _ProductActions(this.p);
  final Product p;

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppState>();
    Widget action(IconData i, String l, VoidCallback f) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Glass(radius: 18, padding: const EdgeInsets.all(14), onTap: f, child: Row(children: [Icon(i, size: 18, color: K.lime), const SizedBox(width: 12), Expanded(child: Text(l, style: t(13))), const Icon(Ic.chevron, color: K.dim)])),
        );
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Avatar(p),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(p.name, style: t(16, w: FontWeight.w800)), const SizedBox(height: 4), Text('${p.sku}${p.barcode.isEmpty ? '' : '  -  ${p.barcode}'}', style: mono(10, c: K.dim))])),
      ]),
      const SizedBox(height: 14),
      Row(children: [
        Expanded(child: _Stat('In stock', '${fmtQty(p.stock)} ${p.unit}')),
        Expanded(child: _Stat('Price', money(p.price))),
        Expanded(child: _Stat('Avg cost', money(p.cost))),
      ]),
      const SizedBox(height: 16),
      action(Ic.packagePlus, 'Receive stock (purchase)', () {
        Navigator.pop(context);
        showSheet(context, _StockSheet(p, receive: true));
      }),
      action(Ic.tune, 'Adjust stock (count / damage)', () {
        Navigator.pop(context);
        showSheet(context, _StockSheet(p, receive: false));
      }),
      action(Ic.pencil, 'Edit product', () {
        Navigator.pop(context);
        showSheet(context, ProductForm(product: p));
      }),
      action(Ic.cart, 'Add to current sale', () {
        final err = s.addToCart(p);
        Navigator.pop(context);
        if (err != null) {
          toast(context, err);
        } else {
          s.setTab(2);
        }
      }),
      action(Ic.trash, 'Archive product', () async {
        await s.archiveProduct(p);
        if (context.mounted) Navigator.pop(context);
      }),
    ]);
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.l, this.v);
  final String l, v;
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(l.toUpperCase(), style: t(9, w: FontWeight.w800, c: K.muted, ls: 1.4)), const SizedBox(height: 4), Text(v, style: t(13))]);
}

class _StockSheet extends StatefulWidget {
  const _StockSheet(this.p, {required this.receive});
  final Product p;
  final bool receive;
  @override
  State<_StockSheet> createState() => _StockSheetState();
}

class _StockSheetState extends State<_StockSheet> {
  final qty = TextEditingController();
  final cost = TextEditingController();
  final supplier = TextEditingController();
  final tin = TextEditingController();
  final invoice = TextEditingController();
  final efd = TextEditingController();
  String reason = 'Stock count correction';

  Future<void> _save() async {
    final s = context.read<AppState>();
    final q = double.tryParse(qty.text);
    if (q == null || q == 0) return toast(context, 'Enter a quantity');
    if (widget.receive) {
      final c = double.tryParse(cost.text.replaceAll(',', ''));
      if (q < 0 || c == null || c < 0) return toast(context, 'Enter quantity and unit cost (excl. VAT)');
      await s.receiveStock(widget.p, qty: q, unitCost: c, supplier: supplier.text.trim(), supplierTin: tin.text.trim(), invoiceNo: invoice.text.trim(), efdReceipt: efd.text.trim());
    } else {
      await s.adjustStock(widget.p, q, reason);
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    Widget f(TextEditingController c, String l, {bool n = false, String? hint}) => Padding(padding: const EdgeInsets.only(bottom: 12), child: TextField(controller: c, keyboardType: n ? const TextInputType.numberWithOptions(decimal: true, signed: true) : null, style: t(13, w: FontWeight.w500), decoration: dec(l, hint: hint)));
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(widget.receive ? 'Receive stock' : 'Adjust stock', style: t(18, w: FontWeight.w800)),
      Text(widget.p.name, style: t(12, w: FontWeight.w500, c: K.muted)),
      const SizedBox(height: 16),
      f(qty, widget.receive ? 'Quantity received' : 'Change (+ add / - remove)', n: true),
      if (widget.receive) ...[
        f(cost, 'Unit cost (excl. VAT)', n: true),
        f(supplier, 'Supplier'),
        Row(children: [Expanded(child: f(tin, 'Supplier TIN')), const SizedBox(width: 10), Expanded(child: f(invoice, 'Invoice no.'))]),
        f(efd, 'Supplier EFD receipt no.', hint: 'needed to claim input VAT'),
        Text('Input VAT is computed from this product\'s VAT class and feeds the VAT return.', style: t(10, w: FontWeight.w500, c: K.dim)),
      ] else
        DropdownButtonFormField<String>(
          initialValue: reason,
          dropdownColor: K.sheet,
          decoration: dec('Reason'),
          style: t(13, w: FontWeight.w500),
          items: [for (final r in ['Stock count correction', 'Damaged / expired', 'Customer return', 'Internal use']) DropdownMenuItem(value: r, child: Text(r))],
          onChanged: (v) => setState(() => reason = v ?? reason),
        ),
      const SizedBox(height: 18),
      LimeButton('Save', icon: Ic.check, onTap: _save),
    ]);
  }
}
