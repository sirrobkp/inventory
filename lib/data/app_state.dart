import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import '../services/printer_service.dart';
import '../services/report_service.dart';
import '../services/tra_service.dart';
import 'models.dart';
import 'repo.dart';

class AppState extends ChangeNotifier {
  final repo = Repo();
  late final TraService tra = TraService(repo);
  late final ReportService reports = ReportService(repo);
  final printer = PrinterService();

  int tab = 0;
  List<Product> products = [];
  List<Sale> recent = [];
  Dashboard dash = Dashboard();
  Map<String, String> cfg = {};
  final List<CartLine> cart = [];
  bool syncing = false;
  bool online = true;
  String? lastSyncMsg;

  Timer? _timer;
  StreamSubscription<List<ConnectivityResult>>? _conn;

  bool get registered => (cfg['regid'] ?? '').isNotEmpty;
  int get lowStockCount => products.where((p) => p.low).length;
  List<String> get categories => (products.map((p) => p.category).toSet().toList()..sort());

  // ------------------------------------------------------------------ lifecycle
  Future<void> init() async {
    await refresh();
    _timer = Timer.periodic(const Duration(seconds: 60), (_) => syncNow(silent: true));
    _conn = Connectivity().onConnectivityChanged.listen((r) {
      online = !r.contains(ConnectivityResult.none);
      notifyListeners();
      if (online) syncNow(silent: true);
    });
    unawaited(syncNow(silent: true));
  }

  @override
  void dispose() {
    _timer?.cancel();
    _conn?.cancel();
    super.dispose();
  }

  Future<void> refresh() async {
    cfg = await repo.allSettings();
    products = await repo.products();
    recent = await repo.recentSales();
    dash = await repo.dashboard();
    notifyListeners();
  }

  void setTab(int i) {
    tab = i;
    notifyListeners();
  }

  // ------------------------------------------------------------------- TRA sync
  /// Uploads queued receipts and any due Z-reports.
  Future<void> syncNow({bool silent = false}) async {
    if (syncing) return;
    syncing = true;
    if (!silent) notifyListeners();
    try {
      final n = await tra.uploadPending();
      await tra.submitDueZReports();
      lastSyncMsg = n > 0 ? '$n receipt(s) accepted by TRA' : null;
    } catch (e) {
      lastSyncMsg = '$e';
    }
    syncing = false;
    await refresh();
  }

  Future<int> retryFailed() async {
    final n = await repo.requeueFailed();
    await syncNow();
    return n;
  }

  // ----------------------------------------------------------------------- cart
  /// Returns an error message, or null on success.
  String? addToCart(Product p, [double qty = 1]) {
    final i = cart.indexWhere((l) => l.product.id == p.id);
    final have = i >= 0 ? cart[i].qty : 0;
    if (have + qty > p.stock) return 'Only ${p.stock.toStringAsFixed(p.stock % 1 == 0 ? 0 : 2)} ${p.unit} of ${p.name} in stock';
    if (i >= 0) {
      cart[i].qty += qty;
    } else {
      cart.add(CartLine(p, qty));
    }
    notifyListeners();
    return null;
  }

  String? changeQty(CartLine l, double delta) {
    if (delta > 0 && l.qty + delta > l.product.stock) return 'No more stock for ${l.product.name}';
    l.qty += delta;
    if (l.qty <= 0) cart.remove(l);
    notifyListeners();
    return null;
  }

  void clearCart() {
    cart.clear();
    notifyListeners();
  }

  double get cartTotal => cart.fold(0, (a, l) => a + l.amount);

  // ----------------------------------------------------------------------- sale
  /// Approves the current cart: fiscal counters + stock + queue in one DB transaction, then
  /// kicks off the automatic TRA upload (and auto-print if enabled). Throws StateError on stock errors.
  Future<Sale> approveSale({required String payment, String custName = '', String custTin = '', String mobile = ''}) async {
    final fiscal = registered;
    final id = await repo.createSale(lines: List.of(cart), payment: payment, fiscal: fiscal, custName: custName, custId: custTin, mobile: mobile);
    cart.clear();
    final sale = await repo.getSale(id);
    await refresh();
    if (fiscal) unawaited(syncNow(silent: true));
    if (cfg['auto_print'] == '1') unawaited(printReceipt(sale));
    return sale;
  }

  Sale live(Sale s) => recent.firstWhere((e) => e.id == s.id, orElse: () => s);

  Future<String> printReceipt(Sale s) => printer.printSale(s, cfg);

  // ------------------------------------------------------------------- products
  Future<void> saveProduct(Product p) async {
    await repo.saveProduct(p);
    await refresh();
  }

  Future<void> archiveProduct(Product p) async {
    await repo.archiveProduct(p.id!);
    await refresh();
  }

  Future<void> adjustStock(Product p, double delta, String reason) async {
    await repo.adjustStock(p.id!, delta, reason);
    await refresh();
  }

  Future<void> receiveStock(Product p, {required double qty, required double unitCost, String supplier = '', String supplierTin = '', String invoiceNo = '', String efdReceipt = '', DateTime? date}) async {
    await repo.receiveStock(p, qty: qty, unitCostExcl: unitCost, supplier: supplier, supplierTin: supplierTin, invoiceNo: invoiceNo, efdReceipt: efdReceipt, date: date ?? DateTime.now());
    await refresh();
  }

  // ------------------------------------------------------------------- settings
  Future<void> saveCfg(Map<String, String> values) async {
    for (final e in values.entries) {
      await repo.setSetting(e.key, e.value);
    }
    await refresh();
  }

  Future<void> addExpense({required DateTime date, required String category, required String description, required double gross, required double vat, String tin = '', String ref = ''}) async {
    await repo.addExpense(date: date, category: category, description: description, gross: gross, vat: vat, supplierTin: tin, ref: ref);
    await refresh();
  }
}
