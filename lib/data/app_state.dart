import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import '../services/cloud_service.dart';
import '../services/generic_vfd_service.dart';
import '../services/license_service.dart';
import '../services/printer_service.dart';
import '../services/report_service.dart';
import '../services/tra_service.dart';
import 'models.dart';
import 'platform_info.dart';
import 'repo.dart';

class AppState extends ChangeNotifier {
  final repo = Repo();
  late final GenericVfdService vfd = GenericVfdService(repo);
  late final TraService tra = TraService(repo, vfd);
  late final CloudService cloud = CloudService(repo);
  late final LicenseService licenseSvc = LicenseService(repo);
  LicenseInfo license = const LicenseInfo(LicenseState.disabled);
  DateTime _lastLicenseSync = DateTime(2000);
  String? licenseError;
  bool _backingUp = false;
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

  /// Income-tax rate for the books (company 30% by default; editable in Settings).
  double get taxRate => (double.tryParse(cfg['income_tax_rate'] ?? '') ?? 30) / 100;

  /// 'direct' = own TRA certificate (EFDMS); 'supplier' = any VFD supplier via an imported API profile.
  String get fiscalMode => isDesktop ? 'supplier' : (cfg['fiscal_mode'] ?? 'direct');
  bool get registered => fiscalMode == 'supplier' ? cfg['supplier_ready'] == '1' : (cfg['regid'] ?? '').isNotEmpty;
  int get lowStockCount => products.where((p) => p.low).length;
  List<String> get categories => (products.map((p) => p.category).toSet().toList()..sort());

  // ------------------------------------------------------------------ lifecycle
  Future<void> init() async {
    if (LicenseService.configured && (await repo.getSetting('lic_first_run')) == null) {
      await repo.setSetting('lic_first_run', DateTime.now().toUtc().toIso8601String());
    }
    await refresh();
    _timer = Timer.periodic(const Duration(seconds: 60), (_) {
      syncNow(silent: true);
      maybeAutoBackup();
      maybeLicenseSync();
    });
    _conn = Connectivity().onConnectivityChanged.listen((r) {
      online = !r.contains(ConnectivityResult.none);
      notifyListeners();
      if (online) syncNow(silent: true);
    });
    unawaited(syncNow(silent: true));
    unawaited(maybeAutoBackup());
    unawaited(maybeLicenseSync());
  }

  /// Registers/heartbeats with the subscription server at most every 30 minutes (or now when [force]).
  Future<void> maybeLicenseSync({bool force = false}) async {
    if (!LicenseService.configured || !online) return;
    if (!force && DateTime.now().difference(_lastLicenseSync) < const Duration(minutes: 30)) return;
    _lastLicenseSync = DateTime.now();
    licenseError = await licenseSvc.sync(cfg, {
      'statMonthRevenue': dash.monthGross,
      'statTodaySales': dash.todayCount,
      'statPending': dash.pendingCount,
      'statLowStock': lowStockCount,
      'statProducts': products.length,
    });
    await refresh();
  }

  /// Cloud backup at most every 6 hours, only when enabled, configured and online.
  Future<void> maybeAutoBackup() async {
    if (_backingUp || !online || cfg['cloud_auto'] != '1' || !await cloud.configured) return;
    final last = DateTime.tryParse(cfg['cloud_last_backup'] ?? '');
    if (last != null && DateTime.now().difference(last) < const Duration(hours: 6)) return;
    _backingUp = true;
    try {
      await cloud.backup();
      await refresh();
    } catch (_) {
      // stays quiet; the manual button shows the error
    }
    _backingUp = false;
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
    license = LicenseService.evaluate(cfg, DateTime.now());
    if (LicenseService.configured) {
      final c = DateTime.tryParse(cfg['lic_clock'] ?? '');
      if (c == null || DateTime.now().isAfter(c)) unawaited(repo.setSetting('lic_clock', DateTime.now().toUtc().toIso8601String()));
    }
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
    final supplier = fiscalMode == 'supplier';
    final id = await repo.createSale(lines: List.of(cart), payment: payment, fiscal: fiscal, supplierMode: supplier, custName: custName, custId: custTin, mobile: mobile);
    cart.clear();
    // Supplier APIs issue the receipt number / verification code, so wait (briefly) for it before showing/printing.
    if (fiscal && supplier) {
      try {
        await syncNow(silent: true).timeout(const Duration(seconds: 25));
      } catch (_) {}
    }
    final sale = await repo.getSale(id);
    await refresh();
    if (fiscal && !supplier) unawaited(syncNow(silent: true));
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

  Future<void> receiveStock(Product p, {required double qty, required double unitCost, String supplier = '', String supplierTin = '', String invoiceNo = '', String efdReceipt = '', DateTime? date, bool paid = true}) async {
    await repo.receiveStock(p, qty: qty, unitCostExcl: unitCost, supplier: supplier, supplierTin: supplierTin, invoiceNo: invoiceNo, efdReceipt: efdReceipt, date: date ?? DateTime.now(), paid: paid);
    await refresh();
  }

  // ------------------------------------------------------------ returns & credit payments
  /// Credit note. Sent to the supplier automatically when the imported profile has a "creditNote" section;
  /// otherwise it is recorded as 'manual' (issue it in your supplier portal, then mark it issued).
  Future<int> createSaleReturn(Sale sale, Map<int, double> qtys, String reason) async {
    var status = 'manual';
    if (fiscalMode == 'supplier' && await vfd.hasCreditNote()) status = 'queued';
    final id = await repo.createSaleReturn(saleId: sale.id!, qtyByItemId: qtys, reason: reason, status: status);
    await refresh();
    if (status == 'queued') unawaited(syncNow(silent: true));
    return id;
  }

  Future<void> createPurchaseReturn(int purchaseId, double qty, String note) async {
    await repo.createPurchaseReturn(purchaseId: purchaseId, qty: qty, note: note);
    await refresh();
  }

  Future<void> addPayment(String kind, int refId, double amount, String note) async {
    await repo.addPayment(kind: kind, refId: refId, amount: amount, date: DateTime.now(), note: note);
    await refresh();
  }

  // ------------------------------------------------------------------- settings
  Future<void> saveCfg(Map<String, String> values) async {
    for (final e in values.entries) {
      await repo.setSetting(e.key, e.value);
    }
    await refresh();
  }

  Future<void> addExpense({required DateTime date, required String category, required String description, required double gross, required double vat, String tin = '', String ref = '', bool paid = true}) async {
    await repo.addExpense(date: date, category: category, description: description, gross: gross, vat: vat, supplierTin: tin, ref: ref, paid: paid);
    await refresh();
  }
}
