import 'package:intl/intl.dart';
import 'package:sqflite/sqflite.dart';

import 'db.dart';
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
  Future<void> receiveStock(Product p, {required double qty, required double unitCostExcl, required String supplier, required String supplierTin, required String invoiceNo, required String efdReceipt, required DateTime date}) async {
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
      });
    });
  }

  Future<void> addExpense({required DateTime date, required String category, required String description, required double gross, required double vat, String supplierTin = '', String ref = ''}) async {
    if (category == 'Depreciation') vat = 0;
    await (await _d).insert('expenses', {
      'date': dayFmt.format(date),
      'category': category,
      'description': description,
      'net': r2(gross - vat),
      'vat': vat,
      'gross': gross,
      'supplier_tin': supplierTin,
      'ref': ref,
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
  Future<int> createSale({required List<CartLine> lines, required String payment, required bool fiscal, String custName = '', String custId = '', String mobile = ''}) async {
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
        rctvnum = '$code$gc';
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
    final st = (await d.rawQuery('SELECT COALESCE(SUM(stock*cost),0) v, COUNT(*) c FROM products WHERE active=1')).first;
    final rows = await d.rawQuery('SELECT day, SUM(total_incl) s FROM sales WHERE day>=? GROUP BY day', [dayFmt.format(now.subtract(const Duration(days: 6)))]);
    final map = {for (final r in rows) r['day'] as String: (r['s'] as num).toDouble()};
    final week = [for (int i = 6; i >= 0; i--) map[dayFmt.format(now.subtract(Duration(days: i)))] ?? 0.0];
    final p = (await d.rawQuery("SELECT COUNT(*) c, COALESCE(SUM(total_incl),0) s FROM sales WHERE fiscal=1 AND upload_status IN ('queued','failed')")).first;
    return Dashboard(
      todayRevenue: (t['s'] as num).toDouble(),
      todayCount: t['c'] as int,
      monthNet: (m['n'] as num).toDouble(),
      monthCogs: (m['c'] as num).toDouble(),
      monthGross: (m['g'] as num).toDouble(),
      monthOutputVat: (m['v'] as num).toDouble(),
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
    final s = (await d.rawQuery('SELECT COALESCE(SUM(cogs),0) c, COUNT(*) n FROM sales WHERE day BETWEEN ? AND ?', [from, to])).first;
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
      cogs: (s['c'] as num).toDouble(),
      expensesByCat: ex,
      purchasesNet: (pu['n'] as num).toDouble(),
      purchasesVat: (pu['v'] as num).toDouble(),
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

  Future<Cum> cumAsAt(String upTo) async {
    final d = await _d;
    Future<Map<String, Object?>> one(String sql) async => (await d.rawQuery(sql, [upTo])).first;
    final s = await one('SELECT COALESCE(SUM(total_incl),0) g, COALESCE(SUM(total_excl),0) n, COALESCE(SUM(total_vat),0) v, COALESCE(SUM(cogs),0) c FROM sales WHERE day<=?');
    final p = await one('SELECT COALESCE(SUM(gross),0) g, COALESCE(SUM(net),0) n, COALESCE(SUM(vat),0) v FROM purchases WHERE date<=?');
    final e = await one("SELECT COALESCE(SUM(net),0) n, COALESCE(SUM(vat),0) v, COALESCE(SUM(CASE WHEN category='Depreciation' THEN net ELSE 0 END),0) dep, COALESCE(SUM(CASE WHEN category<>'Depreciation' THEN gross ELSE 0 END),0) cash FROM expenses WHERE date<=?");
    final m = await one("SELECT COALESCE(SUM(CASE WHEN kind='opening' THEN value ELSE 0 END),0) o, COALESCE(SUM(CASE WHEN kind='adjust' THEN value ELSE 0 END),0) a FROM stock_movements WHERE substr(created_at,1,10)<=?");
    final l = <String, double>{};
    for (final r in await d.rawQuery('SELECT type, SUM(amount) a FROM equity_ledger WHERE date<=? GROUP BY type', [upTo])) {
      l[r['type'] as String] = _g(r['a']);
    }
    return Cum(
      salesGross: _g(s['g']), salesNet: _g(s['n']), salesVat: _g(s['v']), cogs: _g(s['c']),
      purchGross: _g(p['g']), purchNet: _g(p['n']), purchVat: _g(p['v']),
      expNet: _g(e['n']), expVat: _g(e['v']), depreciation: _g(e['dep']), expCash: _g(e['cash']),
      openingStock: _g(m['o']), adjustments: _g(m['a']),
      capital: l['capital'] ?? 0, drawings: l['drawings'] ?? 0, loanIn: l['loan_in'] ?? 0, loanOut: l['loan_out'] ?? 0,
      vatPaid: l['vat_paid'] ?? 0, assetBuy: l['asset_purchase'] ?? 0,
    );
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
}
