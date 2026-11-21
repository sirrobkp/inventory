import 'package:intl/intl.dart';
import 'package:sqflite/sqflite.dart';

import 'db.dart';
import 'fixed_assets.dart';
import 'models.dart';
import 'tax.dart';

final dayFmt = DateFormat('yyyy-MM-dd');

class DayTotals {
  DayTotals(this.count, this.gross, this.vat, this.payments, this.cumulativeGross);
  final int count;
  final double gross, cumulativeGross;
  final Map<String, VatLine> vat;
  final Map<String, double> payments;
}

class Repo {
  Future<Database> get _d => Db.instance;

  // ---------------------------------------------------------------- settings
  Future<String?> getSetting(String k) async {
    final r = await (await _d).query('settings', where: 'key=?', whereArgs: [k]);
    return r.isEmpty ? null : r.first['value'] as String?;
  }

  Future<void> setSetting(String k, String v) async {
    await (await _d).insert('settings', {'key': k, 'value': v}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, String>> allSettings() async {
    final r = await (await _d).query('settings');
    return {for (final e in r) e['key'] as String: (e['value'] as String?) ?? ''};
  }

  // ---------------------------------------------------------------- products
  Future<List<Product>> products() async {
    final r = await (await _d).query('products', where: 'active=1', orderBy: 'name COLLATE NOCASE');
    return r.map(Product.fromMap).toList();
  }

  Future<Product?> findByCode(String code) async {
    final r = await (await _d).query('products', where: 'active=1 AND (barcode=? OR sku=?)', whereArgs: [code, code], limit: 1);
    return r.isEmpty ? null : Product.fromMap(r.first);
  }

  Future<void> saveProduct(Product p) async {
    final d = await _d;
    await d.transaction((t) async {
      if (p.id == null) {
        final id = await t.insert('products', p.toMap());
        if (p.stock != 0) {
          await t.insert('stock_movements', {'product_id': id, 'delta': p.stock, 'reason': 'Opening stock', 'ref': '', 'created_at': DateTime.now().toIso8601String(), 'kind': 'opening', 'value': r2(p.stock * p.cost)});
        }
      } else {
        final m = p.toMap()..remove('stock'); // stock only changes through movements
        await t.update('products', m, where: 'id=?', whereArgs: [p.id]);
      }
    });
  }

  Future<void> archiveProduct(int id) async {
    await (await _d).update('products', {'active': 0}, where: 'id=?', whereArgs: [id]);
  }

  Future<void> adjustStock(int id, double delta, String reason) async {
    final d = await _d;
    await d.transaction((t) async {
      final cost = ((await t.query('products', columns: ['cost'], where: 'id=?', whereArgs: [id])).first['cost'] as num?)?.toDouble() ?? 0;
      await t.rawUpdate('UPDATE products SET stock = stock + ?, updated_at=? WHERE id=?', [delta, DateTime.now().toIso8601String(), id]);
      await t.insert('stock_movements', {'product_id': id, 'delta': delta, 'reason': reason, 'ref': '', 'created_at': DateTime.now().toIso8601String(), 'kind': 'adjust', 'value': r2(delta * cost)});
    });
  }

  /// Receive stock from a supplier; records the purchase (input VAT) and updates weighted-average cost.
  Future<void> receiveStock(Product p, {required double qty, required double unitCostExcl, required String supplier, required String supplierTin, required String invoiceNo, required String efdReceipt, required DateTime date, bool paid = true}) async {
    final d = await _d;
    await d.transaction((t) async {
      final cur = Product.fromMap((await t.query('products', where: 'id=?', whereArgs: [p.id])).first);
      final net = r2(qty * unitCostExcl);
      final vat = r2(net * (taxRates[cur.taxCode] ?? 0));
      final newCost = cur.stock <= 0 ? unitCostExcl : r2((cur.stock * cur.cost + qty * unitCostExcl) / (cur.stock + qty));
      await t.rawUpdate('UPDATE products SET stock = stock + ?, cost = ?, updated_at=? WHERE id=?', [qty, newCost, DateTime.now().toIso8601String(), p.id]);
      await t.insert('stock_movements', {'product_id': p.id, 'delta': qty, 'reason': 'Purchase $invoiceNo', 'ref': supplier, 'created_at': DateTime.now().toIso8601String(), 'kind': 'purchase', 'value': net});
      await t.insert('purchases', {
        'date': dayFmt.format(date),
        'product_id': p.id,
        'product_name': cur.name,
        'qty': qty,
        'unit_cost': unitCostExcl,
        'net': net,
        'vat': vat,
        'gross': r2(net + vat),
        'tax_code': cur.taxCode,
        'supplier': supplier,
        'supplier_tin': supplierTin,
        'invoice_no': invoiceNo,
        'efd_receipt': efdReceipt,
        'paid': paid ? 1 : 0,
      });
    });
  }

  Future<void> addExpense({required DateTime date, required String category, required String description, required double gross, required double vat, String supplierTin = '', String ref = '', bool paid = true}) async {
    await (await _d).insert('expenses', {
      'date': dayFmt.format(date),
      'category': category,
      'description': description,
      'net': r2(gross - vat),
      'vat': vat,
      'gross': gross,
      'supplier_tin': supplierTin,
      'ref': ref,
      'paid': paid ? 1 : 0,
    });
  }

  Future<List<Expense>> expenses(String from, String to) async {
    final r = await (await _d).query('expenses', where: 'date BETWEEN ? AND ?', whereArgs: [from, to], orderBy: 'date DESC');
    return r.map(Expense.fromMap).toList();
  }

  Future<List<Purchase>> purchases(String from, String to) async {
    final r = await (await _d).query('purchases', where: 'date BETWEEN ? AND ?', whereArgs: [from, to], orderBy: 'date');
    return r.map(Purchase.fromMap).toList();
  }

  // ------------------------------------------------------------------- sales
  Future<int> _next(Transaction t, String key) async {
    final r = await t.query('settings', where: 'key=?', whereArgs: [key]);
    final v = (r.isEmpty ? 0 : int.tryParse((r.first['value'] as String?) ?? '0') ?? 0) + 1;
    await t.insert('settings', {'key': key, 'value': '$v'}, conflictAlgorithm: ConflictAlgorithm.replace);
    return v;
  }

  /// Atomically: validates stock, assigns fiscal counters (GC/DC), writes sale + items + VAT lines,
  /// decrements stock and queues the receipt for TRA upload. Returns the new sale id.
  Future<int> createSale({required List<CartLine> lines, required String payment, required bool fiscal, bool supplierMode = false, String custName = '', String custId = '', String mobile = ''}) async {
    final d = await _d;
    return d.transaction<int>((t) async {
      final now = DateTime.now();
      final day = dayFmt.format(now);
      final classGross = <String, double>{};
      final products = <int, Product>{};
      double cogs = 0, total = 0;

      for (final l in lines) {
        final r = await t.query('products', where: 'id=?', whereArgs: [l.product.id]);
        if (r.isEmpty) throw StateError('${l.product.name} no longer exists');
        final p = Product.fromMap(r.first);
        if (p.stock < l.qty) throw StateError('Only ${fmtQty(p.stock)} ${p.unit} of ${p.name} in stock');
        products[p.id!] = p;
        final amount = r2(p.price * l.qty);
        classGross[p.taxCode] = (classGross[p.taxCode] ?? 0) + amount;
        total += amount;
        cogs += p.cost * l.qty;
      }

      double net = 0, vat = 0;
      final vatRows = <Map<String, Object?>>[];
      classGross.forEach((code, gross) {
        final s = splitGross(r2(gross), code);
        net += s.net;
        vat += s.vat;
        vatRows.add({'tax_code': code, 'net': s.net, 'vat': s.vat, 'gross': r2(gross)});
      });

      int gc = 0, dc = 0;
      String rctvnum = '';
      if (fiscal) {
        gc = await _next(t, 'gc');
        dc = await _next(t, 'dc_$day');
        final code = (await t.query('settings', where: 'key=?', whereArgs: ['receiptcode'])).firstOrNull?['value'] as String? ?? '';
        rctvnum = supplierMode ? '' : '$code$gc'; // supplier API returns the verification code
      }

      final saleId = await t.insert('sales', {
        'created_at': now.toIso8601String(),
        'day': day,
        'gc': gc,
        'dc': dc,
        'znum': day.replaceAll('-', ''),
        'rctvnum': rctvnum,
        'fiscal': fiscal ? 1 : 0,
        'customer_name': custName,
        'customer_id_type': custId.isEmpty ? 6 : 1,
        'customer_id': custId,
        'mobile': mobile,
        'payment_type': payment,
        'total_excl': r2(net),
        'total_vat': r2(vat),
        'total_incl': r2(total),
        'cogs': r2(cogs),
        'upload_status': fiscal ? 'queued' : 'n/a',
      });

      for (final v in vatRows) {
        await t.insert('sale_vat', {...v, 'sale_id': saleId});
      }
      for (final l in lines) {
        final p = products[l.product.id]!;
        await t.insert('sale_items', {
          'sale_id': saleId,
          'product_id': p.id,
          'name': p.name,
          'sku': p.sku,
          'qty': l.qty,
          'unit_price': p.price,
          'amount': r2(p.price * l.qty),
          'cost': p.cost,
          'tax_code': p.taxCode,
        });
        await t.rawUpdate('UPDATE products SET stock = stock - ?, updated_at=? WHERE id=?', [l.qty, now.toIso8601String(), p.id]);
        await t.insert('stock_movements', {'product_id': p.id, 'delta': -l.qty, 'reason': 'Sale', 'ref': fiscal ? '$gc' : 'NF-$saleId', 'created_at': now.toIso8601String(), 'kind': 'sale', 'value': -r2(l.qty * p.cost)});
      }
      return saleId;
    });
  }

  Future<Sale> _hydrate(DatabaseExecutor d, Map<String, Object?> row) async {
    final id = row['id'] as int;
    final items = (await d.query('sale_items', where: 'sale_id=?', whereArgs: [id], orderBy: 'id')).map(SaleItem.fromMap).toList();
    final vat = (await d.query('sale_vat', where: 'sale_id=?', whereArgs: [id]))
        .map((e) => VatLine(e['tax_code'] as String, (e['net'] as num).toDouble(), (e['vat'] as num).toDouble(), (e['gross'] as num).toDouble()))
        .toList();
    return Sale.fromMap(row, items: items, vat: vat);
  }

  Future<Sale> getSale(int id) async {
    final d = await _d;
    return _hydrate(d, (await d.query('sales', where: 'id=?', whereArgs: [id])).first);
  }

  Future<List<Sale>> recentSales({int limit = 40}) async {
    final d = await _d;
    final r = await d.query('sales', orderBy: 'id DESC', limit: limit);
    return r.map((e) => Sale.fromMap(e)).toList();
  }

  Future<List<Sale>> queuedSales() async {
    final d = await _d;
    final r = await d.query('sales', where: "fiscal=1 AND upload_status='queued'", orderBy: 'gc');
    return [for (final e in r) await _hydrate(d, e)];
  }

  Future<void> markUploaded(int id, String code, String msg) async {
    await (await _d).update('sales', {'upload_status': 'uploaded', 'ack_code': code, 'ack_msg': msg, 'last_error': null, 'uploaded_at': DateTime.now().toIso8601String()}, where: 'id=?', whereArgs: [id]);
  }

  Future<void> markFiscalised(int id, {String fiscalNo = '', String verifyCode = '', String verifyUrl = '', String ackCode = '', String ackMsg = ''}) async {
    await (await _d).update(
      'sales',
      {
        'upload_status': 'uploaded',
        'fiscal_no': fiscalNo,
        'verify_url': verifyUrl,
        if (verifyCode.isNotEmpty) 'rctvnum': verifyCode,
        'ack_code': ackCode,
        'ack_msg': ackMsg,
        'last_error': null,
        'uploaded_at': DateTime.now().toIso8601String(),
      },
      where: 'id=?',
      whereArgs: [id],
    );
  }

  Future<void> markFailed(int id, String err) async {
    await (await _d).rawUpdate("UPDATE sales SET upload_status='failed', attempts=attempts+1, last_error=? WHERE id=?", [err, id]);
  }

  Future<void> noteAttempt(int id, String err) async {
    await (await _d).rawUpdate('UPDATE sales SET attempts=attempts+1, last_error=? WHERE id=?', [err, id]);
  }

  Future<int> requeueFailed() async => (await _d).update('sales', {'upload_status': 'queued'}, where: "upload_status='failed'");

  // --------------------------------------------------------------- dashboard
  Future<Dashboard> dashboard() async {
    final d = await _d;
    final now = DateTime.now();
    final today = dayFmt.format(now);
    final monthStart = dayFmt.format(DateTime(now.year, now.month, 1));
    final t = (await d.rawQuery('SELECT COALESCE(SUM(total_incl),0) s, COUNT(*) c FROM sales WHERE day=?', [today])).first;
    final m = (await d.rawQuery('SELECT COALESCE(SUM(total_excl),0) n, COALESCE(SUM(cogs),0) c, COALESCE(SUM(total_incl),0) g, COALESCE(SUM(total_vat),0) v FROM sales WHERE day>=?', [monthStart])).first;
    final tr = (await d.rawQuery('SELECT COALESCE(SUM(total_incl),0) s FROM sale_returns WHERE day=?', [today])).first;
    final mr = (await d.rawQuery('SELECT COALESCE(SUM(total_excl),0) n, COALESCE(SUM(cogs),0) c, COALESCE(SUM(total_incl),0) g, COALESCE(SUM(total_vat),0) v FROM sale_returns WHERE day>=?', [monthStart])).first;
    final st = (await d.rawQuery('SELECT COALESCE(SUM(stock*cost),0) v, COUNT(*) c FROM products WHERE active=1')).first;
    final rows = await d.rawQuery('SELECT day, SUM(total_incl) s FROM sales WHERE day>=? GROUP BY day', [dayFmt.format(now.subtract(const Duration(days: 6)))]);
    final map = {for (final r in rows) r['day'] as String: (r['s'] as num).toDouble()};
    final week = [for (int i = 6; i >= 0; i--) map[dayFmt.format(now.subtract(Duration(days: i)))] ?? 0.0];
    final p = (await d.rawQuery("SELECT COUNT(*) c, COALESCE(SUM(total_incl),0) s FROM sales WHERE fiscal=1 AND upload_status IN ('queued','failed')")).first;
    return Dashboard(
      todayRevenue: (t['s'] as num).toDouble() - _g(tr['s']),
      todayCount: t['c'] as int,
      monthNet: (m['n'] as num).toDouble() - _g(mr['n']),
      monthCogs: (m['c'] as num).toDouble() - _g(mr['c']),
      monthGross: (m['g'] as num).toDouble() - _g(mr['g']),
      monthOutputVat: (m['v'] as num).toDouble() - _g(mr['v']),
      stockValue: (st['v'] as num).toDouble(),
      productCount: st['c'] as int,
      week: week,
      pendingCount: p['c'] as int,
      pendingTotal: (p['s'] as num).toDouble(),
    );
  }

  // ----------------------------------------------------------------- reports
  Future<Statement> statement(String from, String to) async {
    final d = await _d;
    final byClass = <String, VatLine>{};
    for (final r in await d.rawQuery('SELECT v.tax_code c, SUM(v.net) n, SUM(v.vat) t, SUM(v.gross) g FROM sale_vat v JOIN sales s ON s.id=v.sale_id WHERE s.day BETWEEN ? AND ? GROUP BY v.tax_code', [from, to])) {
      byClass[r['c'] as String] = VatLine(r['c'] as String, (r['n'] as num).toDouble(), (r['t'] as num).toDouble(), (r['g'] as num).toDouble());
    }
    for (final r in await d.rawQuery('SELECT v.tax_code c, SUM(v.net) n, SUM(v.vat) t, SUM(v.gross) g FROM return_vat v JOIN sale_returns s ON s.id=v.return_id WHERE s.day BETWEEN ? AND ? GROUP BY v.tax_code', [from, to])) {
      final code = r['c'] as String;
      final cur = byClass[code];
      byClass[code] = VatLine(code, (cur?.net ?? 0) - _g(r['n']), (cur?.vat ?? 0) - _g(r['t']), (cur?.gross ?? 0) - _g(r['g']));
    }
    final s = (await d.rawQuery('SELECT COALESCE(SUM(cogs),0) c, COUNT(*) n FROM sales WHERE day BETWEEN ? AND ?', [from, to])).first;
    final rc = (await d.rawQuery('SELECT COALESCE(SUM(cogs),0) c FROM sale_returns WHERE day BETWEEN ? AND ?', [from, to])).first;
    final prr = (await d.rawQuery('SELECT COALESCE(SUM(net),0) n, COALESCE(SUM(vat),0) v FROM purchase_returns WHERE day BETWEEN ? AND ?', [from, to])).first;
    final pay = <String, double>{};
    for (final r in await d.rawQuery('SELECT payment_type p, SUM(total_incl) s FROM sales WHERE day BETWEEN ? AND ? GROUP BY payment_type', [from, to])) {
      pay[r['p'] as String] = (r['s'] as num).toDouble();
    }
    final ex = <String, double>{};
    for (final r in await d.rawQuery('SELECT category c, SUM(net) n FROM expenses WHERE date BETWEEN ? AND ? GROUP BY category', [from, to])) {
      ex[r['c'] as String] = (r['n'] as num).toDouble();
    }
    final e = (await d.rawQuery('SELECT COALESCE(SUM(net),0) n, COALESCE(SUM(vat),0) v FROM expenses WHERE date BETWEEN ? AND ?', [from, to])).first;
    final pu = (await d.rawQuery('SELECT COALESCE(SUM(net),0) n, COALESCE(SUM(vat),0) v FROM purchases WHERE date BETWEEN ? AND ?', [from, to])).first;
    final sv = (await d.rawQuery('SELECT COALESCE(SUM(stock*cost),0) v FROM products WHERE active=1')).first;
    final adj = (((await d.rawQuery("SELECT COALESCE(SUM(value),0) a FROM stock_movements WHERE kind='adjust' AND substr(created_at,1,10) BETWEEN ? AND ?", [from, to])).first['a']) as num).toDouble();
    return Statement(
      salesByClass: byClass,
      cogs: (s['c'] as num).toDouble() - _g(rc['c']),
      expensesByCat: ex,
      purchasesNet: (pu['n'] as num).toDouble() - _g(prr['n']),
      purchasesVat: (pu['v'] as num).toDouble() - _g(prr['v']),
      expensesNet: (e['n'] as num).toDouble(),
      expensesVat: (e['v'] as num).toDouble(),
      paymentTotals: pay,
      receiptCount: s['n'] as int,
      stockValue: (sv['v'] as num).toDouble(),
      adjustments: adj,
    );
  }

  Future<List<Sale>> salesBetween(String from, String to) async {
    final r = await (await _d).query('sales', where: 'day BETWEEN ? AND ?', whereArgs: [from, to], orderBy: 'id');
    return r.map((e) => Sale.fromMap(e)).toList();
  }

  // ---------------------------------------------------------------- Z reports
  Future<DayTotals> dayTotals(String day) async {
    final d = await _d;
    final vat = <String, VatLine>{};
    for (final r in await d.rawQuery('SELECT v.tax_code c, SUM(v.net) n, SUM(v.vat) t, SUM(v.gross) g FROM sale_vat v JOIN sales s ON s.id=v.sale_id WHERE s.day=? AND s.fiscal=1 GROUP BY v.tax_code', [day])) {
      vat[r['c'] as String] = VatLine(r['c'] as String, (r['n'] as num).toDouble(), (r['t'] as num).toDouble(), (r['g'] as num).toDouble());
    }
    final pay = <String, double>{};
    for (final r in await d.rawQuery('SELECT payment_type p, SUM(total_incl) s FROM sales WHERE day=? AND fiscal=1 GROUP BY payment_type', [day])) {
      pay[r['p'] as String] = (r['s'] as num).toDouble();
    }
    final t = (await d.rawQuery('SELECT COUNT(*) c, COALESCE(SUM(total_incl),0) g FROM sales WHERE day=? AND fiscal=1', [day])).first;
    final cum = (await d.rawQuery('SELECT COALESCE(SUM(total_incl),0) g FROM sales WHERE day<=? AND fiscal=1', [day])).first;
    return DayTotals(t['c'] as int, (t['g'] as num).toDouble(), vat, pay, (cum['g'] as num).toDouble());
  }

  Future<List<String>> daysNeedingZ() async {
    final today = dayFmt.format(DateTime.now());
    final r = await (await _d).rawQuery(
        "SELECT DISTINCT day FROM sales WHERE fiscal=1 AND day < ? "
        "AND day NOT IN (SELECT day FROM z_reports WHERE status IN ('submitted','failed')) "
        "AND day NOT IN (SELECT day FROM sales WHERE fiscal=1 AND upload_status!='uploaded') ORDER BY day",
        [today]);
    return r.map((e) => e['day'] as String).toList();
  }

  Future<void> saveZ(String day, String znum, String xml, String status, String msg) async {
    await (await _d).insert('z_reports', {'day': day, 'znum': znum, 'xml': xml, 'status': status, 'ack_msg': msg, 'submitted_at': DateTime.now().toIso8601String()}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Map<String, Object?>>> zReports(String from, String to) async => (await _d).query('z_reports', where: 'day BETWEEN ? AND ?', whereArgs: [from, to], orderBy: 'day');

  Future<Map<String, Object?>?> zFor(String day) async {
    final r = await (await _d).query('z_reports', where: 'day=?', whereArgs: [day]);
    return r.isEmpty ? null : r.first;
  }

  // ------------------------------------------------------------- books / ledger
  double _g(Object? v) => (v as num?)?.toDouble() ?? 0;

  Future<Cum> cumAsAt(String upTo, {double taxRate = 0.30}) async {
    final d = await _d;
    Future<Map<String, Object?>> one(String sql) async => (await d.rawQuery(sql, [upTo])).first;
    final s = await one("SELECT COALESCE(SUM(total_incl),0) g, COALESCE(SUM(CASE WHEN payment_type='INVOICE' THEN total_incl ELSE 0 END),0) cr, COALESCE(SUM(total_excl),0) n, COALESCE(SUM(total_vat),0) v, COALESCE(SUM(cogs),0) c FROM sales WHERE day<=?");
    final p = await one('SELECT COALESCE(SUM(gross),0) g, COALESCE(SUM(net),0) n, COALESCE(SUM(vat),0) v, COALESCE(SUM(CASE WHEN paid=0 THEN gross ELSE 0 END),0) u FROM purchases WHERE date<=?');
    final rs = await one('SELECT COALESCE(SUM(total_incl),0) g, COALESCE(SUM(CASE WHEN credit=1 THEN total_incl ELSE 0 END),0) cr, COALESCE(SUM(total_excl),0) n, COALESCE(SUM(total_vat),0) v, COALESCE(SUM(cogs),0) c FROM sale_returns WHERE day<=?');
    final pr = await one('SELECT COALESCE(SUM(gross),0) g, COALESCE(SUM(net),0) n, COALESCE(SUM(vat),0) v, COALESCE(SUM(CASE WHEN unpaid=1 THEN gross ELSE 0 END),0) u FROM purchase_returns WHERE day<=?');
    final e = await one("SELECT COALESCE(SUM(net),0) n, COALESCE(SUM(vat),0) v, COALESCE(SUM(gross),0) g, COALESCE(SUM(CASE WHEN paid=0 THEN gross ELSE 0 END),0) u, COALESCE(SUM(CASE WHEN paid=0 AND category='Audit & other professional fees' THEN gross ELSE 0 END),0) au FROM expenses WHERE date<=?");
    final m = await one("SELECT COALESCE(SUM(CASE WHEN kind='opening' THEN value ELSE 0 END),0) o, COALESCE(SUM(CASE WHEN kind='adjust' THEN value ELSE 0 END),0) a FROM stock_movements WHERE substr(created_at,1,10)<=?");
    final l = <String, double>{};
    for (final r in await d.rawQuery('SELECT type, SUM(amount) a FROM equity_ledger WHERE date<=? GROUP BY type', [upTo])) {
      l[r['type'] as String] = _g(r['a']);
    }
    final on = DateTime.parse(upTo);
    final cost = <String, double>{}, dep = <String, double>{};
    var costT = 0.0, depT = 0.0;
    for (final r in await d.query('assets', where: 'date<=?', whereArgs: [upTo])) {
      final a = Asset.fromMap(r);
      final ad = a.accDepAt(on);
      cost[a.cls] = (cost[a.cls] ?? 0) + a.cost;
      dep[a.cls] = (dep[a.cls] ?? 0) + ad;
      costT += a.cost;
      depT += ad;
    }
    return Cum(
      salesGross: _g(s['g']) - _g(rs['g']), salesCredit: _g(s['cr']) - _g(rs['cr']), salesNet: _g(s['n']) - _g(rs['n']), salesVat: _g(s['v']) - _g(rs['v']), cogs: _g(s['c']) - _g(rs['c']),
      purchGross: _g(p['g']) - _g(pr['g']), purchNet: _g(p['n']) - _g(pr['n']), purchVat: _g(p['v']) - _g(pr['v']), purchUnpaid: _g(p['u']) - _g(pr['u']),
      expNet: _g(e['n']), expVat: _g(e['v']), expGross: _g(e['g']), expUnpaid: _g(e['u']), auditUnpaid: _g(e['au']),
      openingStock: _g(m['o']), adjustments: _g(m['a']),
      capital: l['capital'] ?? 0, drawings: l['drawings'] ?? 0, loanIn: l['loan_in'] ?? 0, loanOut: l['loan_out'] ?? 0,
      vatPaid: l['vat_paid'] ?? 0, taxPaid: (l['provisional_tax'] ?? 0) + (l['tax_paid'] ?? 0),
      recCollected: l['receivable_collected'] ?? 0, supPaid: l['supplier_paid'] ?? 0, accPaid: l['accrued_paid'] ?? 0,
      assetCost: costT, depreciation: depT, taxRate: taxRate, costByClass: cost, depByClass: dep,
    );
  }

  /// Statement + opening (day before [from]) and closing ([to]) books for one reporting period.
  Future<Period> period(DateTime from, DateTime to, double taxRate) async {
    final st = await statement(dayFmt.format(from), dayFmt.format(to));
    final open = await cumAsAt(dayFmt.format(from.subtract(const Duration(days: 1))), taxRate: taxRate);
    final close = await cumAsAt(dayFmt.format(to), taxRate: taxRate);
    return Period(st, open, close);
  }

  // ----------------------------------------------------------- fixed assets
  Future<List<Asset>> assets() async => (await (await _d).query('assets', orderBy: 'date DESC, id DESC')).map(Asset.fromMap).toList();

  Future<void> addAsset(DateTime date, String cls, String description, double cost) async {
    await (await _d).insert('assets', {'date': dayFmt.format(date), 'cls': cls, 'description': description, 'cost': cost});
  }

  Future<void> deleteAsset(int id) async {
    await (await _d).delete('assets', where: 'id=?', whereArgs: [id]);
  }

  Future<void> addLedger(DateTime date, String type, double amount, String note) async {
    await (await _d).insert('equity_ledger', {'date': dayFmt.format(date), 'type': type, 'amount': amount, 'note': note});
  }

  Future<List<Map<String, Object?>>> ledger(String from, String to) async => (await _d).query('equity_ledger', where: 'date BETWEEN ? AND ?', whereArgs: [from, to], orderBy: 'date DESC, id DESC');

  Future<void> deleteLedger(int id) async {
    await (await _d).delete('equity_ledger', where: 'id=?', whereArgs: [id]);
  }

  // ------------------------------------------------------------ employees / SDL
  Future<List<Employee>> employees() async => ((await (await _d).query('employees', where: 'active=1', orderBy: 'name COLLATE NOCASE')).map(Employee.fromMap)).toList();

  Future<void> saveEmployee(Employee e) async {
    final d = await _d;
    if (e.id == null) {
      await d.insert('employees', e.toMap());
    } else {
      await d.update('employees', e.toMap(), where: 'id=?', whereArgs: [e.id]);
    }
  }

  Future<void> archiveEmployee(int id) async {
    await (await _d).update('employees', {'active': 0}, where: 'id=?', whereArgs: [id]);
  }

  /// One line per active employee for [period] (yyyy-MM); defaults to the employee's standing pay.
  Future<List<PayLine>> payrollFor(String period) async {
    final d = await _d;
    final rows = await d.query('payroll', where: 'period=?', whereArgs: [period]);
    final by = {for (final r in rows) r['employee_id'] as int: r};
    final out = <PayLine>[];
    for (final e in await employees()) {
      final r = by[e.id];
      out.add(r == null ? PayLine(e, e.basic, e.allowances, 0) : PayLine(e, _g(r['basic']), _g(r['allowances']), _g(r['other'])));
    }
    return out;
  }

  Future<void> savePayroll(String period, int employeeId, double basic, double allowances, double other) async {
    await (await _d).insert('payroll', {'period': period, 'employee_id': employeeId, 'basic': basic, 'allowances': allowances, 'other': other}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // ================================================================= record lists
  Future<List<Sale>> salesList(String from, String to) async {
    final r = await (await _d).query('sales', where: 'day BETWEEN ? AND ?', whereArgs: [from, to], orderBy: 'id DESC');
    return r.map((e) => Sale.fromMap(e)).toList();
  }

  Future<List<Purchase>> purchasesList(String from, String to) async {
    final r = await (await _d).rawQuery('SELECT p.*, COALESCE((SELECT SUM(qty) FROM purchase_returns WHERE purchase_id=p.id),0) returned FROM purchases p WHERE p.date BETWEEN ? AND ? ORDER BY p.id DESC', [from, to]);
    return r.map(Purchase.fromMap).toList();
  }

  Future<List<SaleReturn>> saleReturns(String from, String to) async {
    final r = await (await _d).rawQuery('SELECT r.*, s.gc, s.fiscal_no sale_fiscal_no FROM sale_returns r JOIN sales s ON s.id=r.sale_id WHERE r.day BETWEEN ? AND ? ORDER BY r.id DESC', [from, to]);
    return r.map((e) => SaleReturn.fromMap(e)).toList();
  }

  Future<SaleReturn> saleReturn(int id) async {
    final d = await _d;
    final row = (await d.rawQuery('SELECT r.*, s.gc, s.fiscal_no sale_fiscal_no FROM sale_returns r JOIN sales s ON s.id=r.sale_id WHERE r.id=?', [id])).first;
    final items = (await d.query('sale_return_items', where: 'return_id=?', whereArgs: [id], orderBy: 'id')).map(SaleItem.fromMap).toList();
    final vat = (await d.query('return_vat', where: 'return_id=?', whereArgs: [id])).map((e) => VatLine(e['tax_code'] as String, _g(e['net']), _g(e['vat']), _g(e['gross']))).toList();
    return SaleReturn.fromMap(row, items: items, vat: vat);
  }

  Future<List<PurchaseReturn>> purchaseReturns(String from, String to) async {
    final r = await (await _d).rawQuery('SELECT r.*, p.supplier, p.invoice_no FROM purchase_returns r JOIN purchases p ON p.id=r.purchase_id WHERE r.day BETWEEN ? AND ? ORDER BY r.id DESC', [from, to]);
    return r.map(PurchaseReturn.fromMap).toList();
  }

  // ------------------------------------------------------------ credit documents
  Future<List<CreditDoc>> creditSales() async {
    final r = await (await _d).rawQuery(
        "SELECT s.id, s.gc, s.fiscal_no, s.fiscal, s.day, s.customer_name, s.total_incl, "
        "COALESCE((SELECT SUM(amount) FROM equity_ledger WHERE type='receivable_collected' AND ref_type='sale' AND ref_id=s.id),0) paid, "
        "COALESCE((SELECT SUM(total_incl) FROM sale_returns WHERE sale_id=s.id),0) returned "
        "FROM sales s WHERE s.payment_type='INVOICE' ORDER BY s.id DESC");
    return [
      for (final e in r)
        CreditDoc(
          id: e['id'] as int,
          number: ((e['fiscal'] as int?) ?? 1) == 1 ? (((e['fiscal_no'] as String?) ?? '').isNotEmpty ? e['fiscal_no'] as String : ((e['gc'] as int?) ?? 0).toString().padLeft(6, '0')) : 'NF-${e['id']}',
          party: ((e['customer_name'] as String?) ?? '').isEmpty ? 'Customer' : e['customer_name'] as String,
          date: e['day'] as String,
          total: _g(e['total_incl']),
          returned: _g(e['returned']),
          paid: _g(e['paid']),
        ),
    ];
  }

  Future<List<CreditDoc>> creditPurchases() async {
    final r = await (await _d).rawQuery(
        "SELECT p.id, p.date, p.supplier, p.invoice_no, p.product_name, p.gross, "
        "COALESCE((SELECT SUM(amount) FROM equity_ledger WHERE type='supplier_paid' AND ref_type='purchase' AND ref_id=p.id),0) paid, "
        "COALESCE((SELECT SUM(gross) FROM purchase_returns WHERE purchase_id=p.id),0) returned "
        "FROM purchases p WHERE p.paid=0 ORDER BY p.id DESC");
    return [
      for (final e in r)
        CreditDoc(
          id: e['id'] as int,
          number: ((e['invoice_no'] as String?) ?? '').isEmpty ? 'PUR-${e['id']}' : e['invoice_no'] as String,
          party: ((e['supplier'] as String?) ?? '').isEmpty ? 'Supplier' : e['supplier'] as String,
          date: e['date'] as String,
          total: _g(e['gross']),
          returned: _g(e['returned']),
          paid: _g(e['paid']),
          detail: (e['product_name'] as String?) ?? '',
        ),
    ];
  }

  /// kind: 'sale' (customer pays a credit sale) or 'purchase' (you pay a credit purchase).
  Future<void> addPayment({required String kind, required int refId, required double amount, required DateTime date, String note = ''}) async {
    await (await _d).insert('equity_ledger', {
      'date': dayFmt.format(date),
      'type': kind == 'sale' ? 'receivable_collected' : 'supplier_paid',
      'amount': amount,
      'note': note,
      'ref_type': kind,
      'ref_id': refId,
    });
  }

  Future<List<Map<String, Object?>>> payments(String kind, int refId) async =>
      (await _d).query('equity_ledger', where: 'ref_type=? AND ref_id=?', whereArgs: [kind, refId], orderBy: 'date DESC, id DESC');

  // ----------------------------------------------------------------- returns
  Future<List<ReturnableItem>> returnableItems(int saleId) async {
    final d = await _d;
    final items = (await d.query('sale_items', where: 'sale_id=?', whereArgs: [saleId], orderBy: 'id')).map(SaleItem.fromMap).toList();
    final out = <ReturnableItem>[];
    for (final it in items) {
      final done = _g((await d.rawQuery('SELECT COALESCE(SUM(qty),0) q FROM sale_return_items WHERE sale_item_id=?', [it.id])).first['q']);
      out.add(ReturnableItem(it, it.qty - done));
    }
    return out;
  }

  /// Creates a credit note: validates quantities, books the reversal (revenue, VAT, COGS), restocks the items.
  /// [status]: 'queued' (will be sent to the supplier API), 'manual' (issue it yourself) or 'n/a' (non-fiscal sale).
  Future<int> createSaleReturn({required int saleId, required Map<int, double> qtyByItemId, String reason = '', required String status}) async {
    final d = await _d;
    return d.transaction<int>((t) async {
      final sale = Sale.fromMap((await t.query('sales', where: 'id=?', whereArgs: [saleId])).first);
      final items = (await t.query('sale_items', where: 'sale_id=?', whereArgs: [saleId])).map(SaleItem.fromMap).toList();
      final now = DateTime.now();
      final classGross = <String, double>{};
      var cogs = 0.0, total = 0.0;
      final rows = <Map<String, Object?>>[];
      for (final it in items) {
        final q = qtyByItemId[it.id] ?? 0;
        if (q <= 0) continue;
        final done = _g((await t.rawQuery('SELECT COALESCE(SUM(qty),0) q FROM sale_return_items WHERE sale_item_id=?', [it.id])).first['q']);
        if (q > it.qty - done + 1e-9) throw StateError('Only ${fmtQty(it.qty - done)} of ${it.name} can still be returned');
        final amount = r2(it.unitPrice * q);
        classGross[it.taxCode] = (classGross[it.taxCode] ?? 0) + amount;
        total += amount;
        cogs += it.cost * q;
        rows.add({'sale_item_id': it.id, 'product_id': it.productId, 'name': it.name, 'sku': it.sku, 'qty': q, 'unit_price': it.unitPrice, 'amount': amount, 'cost': it.cost, 'tax_code': it.taxCode});
      }
      if (rows.isEmpty) throw StateError('Select at least one item to return');
      var net = 0.0, vat = 0.0;
      final vatRows = <Map<String, Object?>>[];
      classGross.forEach((code, gross) {
        final sp = splitGross(r2(gross), code);
        net += sp.net;
        vat += sp.vat;
        vatRows.add({'tax_code': code, 'net': sp.net, 'vat': sp.vat, 'gross': r2(gross)});
      });
      final id = await t.insert('sale_returns', {
        'created_at': now.toIso8601String(),
        'day': dayFmt.format(now),
        'sale_id': saleId,
        'reason': reason,
        'total_excl': r2(net),
        'total_vat': r2(vat),
        'total_incl': r2(total),
        'cogs': r2(cogs),
        'credit': sale.paymentType == 'INVOICE' ? 1 : 0,
        'upload_status': sale.fiscal ? status : 'n/a',
      });
      for (final v in vatRows) {
        await t.insert('return_vat', {...v, 'return_id': id});
      }
      for (final r in rows) {
        await t.insert('sale_return_items', {...r, 'return_id': id});
        if (r['product_id'] != null) {
          await t.rawUpdate('UPDATE products SET stock = stock + ?, updated_at=? WHERE id=?', [r['qty'], now.toIso8601String(), r['product_id']]);
          await t.insert('stock_movements', {'product_id': r['product_id'], 'delta': r['qty'], 'reason': 'Sales return', 'ref': 'CN-$id', 'created_at': now.toIso8601String(), 'kind': 'sale_return', 'value': 0});
        }
      }
      return id;
    });
  }

  Future<int> createPurchaseReturn({required int purchaseId, required double qty, String note = ''}) async {
    final d = await _d;
    return d.transaction<int>((t) async {
      final p = (await t.query('purchases', where: 'id=?', whereArgs: [purchaseId])).first;
      final pq = _g(p['qty']);
      final done = _g((await t.rawQuery('SELECT COALESCE(SUM(qty),0) q FROM purchase_returns WHERE purchase_id=?', [purchaseId])).first['q']);
      if (qty <= 0) throw StateError('Enter a quantity');
      if (qty > pq - done + 1e-9) throw StateError('Only ${fmtQty(pq - done)} can still be returned');
      final pid = p['product_id'] as int?;
      if (pid != null) {
        final stock = _g((await t.query('products', columns: ['stock'], where: 'id=?', whereArgs: [pid])).first['stock']);
        if (stock < qty) throw StateError('Only ${fmtQty(stock)} in stock - cannot return more than you hold');
      }
      final ratio = qty / pq;
      final net = r2(_g(p['net']) * ratio), vat = r2(_g(p['vat']) * ratio);
      final now = DateTime.now();
      final id = await t.insert('purchase_returns', {
        'created_at': now.toIso8601String(),
        'day': dayFmt.format(now),
        'purchase_id': purchaseId,
        'product_id': pid,
        'product_name': p['product_name'],
        'qty': qty,
        'net': net,
        'vat': vat,
        'gross': r2(net + vat),
        'note': note,
        'unpaid': (p['paid'] as int? ?? 1) == 0 ? 1 : 0,
      });
      if (pid != null) {
        await t.rawUpdate('UPDATE products SET stock = stock - ?, updated_at=? WHERE id=?', [qty, now.toIso8601String(), pid]);
        await t.insert('stock_movements', {'product_id': pid, 'delta': -qty, 'reason': 'Purchase return', 'ref': 'DN-$id', 'created_at': now.toIso8601String(), 'kind': 'purchase_return', 'value': 0});
      }
      return id;
    });
  }

  // --------------------------------------------------------- credit-note upload queue
  Future<List<SaleReturn>> queuedReturns() async {
    final d = await _d;
    final ids = await d.query('sale_returns', columns: ['id'], where: "upload_status='queued'", orderBy: 'id');
    return [for (final r in ids) await saleReturn(r['id'] as int)];
  }

  Future<void> markReturnFiscalised(int id, {String fiscalNo = '', String verifyCode = '', String verifyUrl = '', String ackCode = '', String ackMsg = ''}) async {
    await (await _d).update('sale_returns', {'upload_status': 'uploaded', 'fiscal_no': fiscalNo, 'verify_code': verifyCode, 'verify_url': verifyUrl, 'ack_code': ackCode, 'ack_msg': ackMsg, 'last_error': null}, where: 'id=?', whereArgs: [id]);
  }

  Future<void> markReturnFailed(int id, String err) async {
    await (await _d).rawUpdate("UPDATE sale_returns SET upload_status='failed', attempts=attempts+1, last_error=? WHERE id=?", [err, id]);
  }

  Future<void> noteReturnAttempt(int id, String err) async {
    await (await _d).rawUpdate('UPDATE sale_returns SET attempts=attempts+1, last_error=? WHERE id=?', [err, id]);
  }

  Future<void> requeueReturn(int id) async {
    await (await _d).update('sale_returns', {'upload_status': 'queued'}, where: "id=? AND upload_status IN ('failed','manual')", whereArgs: [id]);
  }
}
