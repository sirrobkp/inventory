import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// Local-only SQLite storage. Everything lives on the device.
class Db {
  static Database? _db;
  static Future<Database> get instance async => _db ??= await _open();

  static Future<String> get path async => p.join(await getDatabasesPath(), 'kibo_trade.db');

  static Future<Database> _open() async {
    return openDatabase(
      await path,
      version: 5,
      onUpgrade: (d, oldV, newV) async {
        // Every step is safe to run twice (columns are only added when missing, tables use IF NOT EXISTS).
        if (oldV < 2) {
          await _addCol(d, 'stock_movements', 'kind', "TEXT DEFAULT ''");
          await _addCol(d, 'stock_movements', 'value', 'REAL DEFAULT 0');
          await _v2(d);
          await d.execute("UPDATE stock_movements SET kind = CASE WHEN reason='Opening stock' THEN 'opening' WHEN reason='Sale' THEN 'sale' WHEN reason LIKE 'Purchase%' THEN 'purchase' ELSE 'adjust' END");
          await d.execute('UPDATE stock_movements SET value = delta * COALESCE((SELECT cost FROM products p WHERE p.id = stock_movements.product_id), 0)');
        }
        if (oldV < 3) {
          await _addCol(d, 'purchases', 'paid', 'INTEGER DEFAULT 1');
          await _addCol(d, 'expenses', 'paid', 'INTEGER DEFAULT 1');
          await d.execute("DELETE FROM equity_ledger WHERE type='asset_purchase'");
          await _v3(d);
        }
        if (oldV < 4) {
          await _addCol(d, 'sales', 'fiscal_no', "TEXT DEFAULT ''");
          await _addCol(d, 'sales', 'verify_url', "TEXT DEFAULT ''");
        }
        if (oldV < 5) {
          await _addCol(d, 'equity_ledger', 'ref_type', "TEXT DEFAULT ''");
          await _addCol(d, 'equity_ledger', 'ref_id', 'INTEGER DEFAULT 0');
          await _v5(d);
        }
      },
      onConfigure: (d) async => d.execute('PRAGMA foreign_keys = ON'),
      onCreate: (d, v) async {
        await d.execute('CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT)');
        await d.execute('''CREATE TABLE products(
          id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, sku TEXT NOT NULL UNIQUE,
          barcode TEXT DEFAULT '', category TEXT DEFAULT 'General', unit TEXT DEFAULT 'pc',
          cost REAL DEFAULT 0, price REAL NOT NULL, stock REAL DEFAULT 0, reorder_level REAL DEFAULT 5,
          tax_code TEXT DEFAULT 'A', active INTEGER DEFAULT 1, updated_at TEXT)''');
        await d.execute('CREATE INDEX idx_products_barcode ON products(barcode)');
        await d.execute('''CREATE TABLE sales(
          id INTEGER PRIMARY KEY AUTOINCREMENT, created_at TEXT NOT NULL, day TEXT NOT NULL,
          gc INTEGER, dc INTEGER, znum TEXT, rctvnum TEXT, fiscal INTEGER DEFAULT 1,
          customer_name TEXT DEFAULT '', customer_id_type INTEGER DEFAULT 6, customer_id TEXT DEFAULT '', mobile TEXT DEFAULT '',
          payment_type TEXT, total_excl REAL, total_vat REAL, total_incl REAL, cogs REAL DEFAULT 0,
          upload_status TEXT DEFAULT 'queued', attempts INTEGER DEFAULT 0, last_error TEXT,
          ack_code TEXT, ack_msg TEXT, uploaded_at TEXT,
          fiscal_no TEXT DEFAULT '', verify_url TEXT DEFAULT '')''');
        await d.execute('CREATE INDEX idx_sales_day ON sales(day)');
        await d.execute('CREATE INDEX idx_sales_status ON sales(upload_status)');
        await d.execute('''CREATE TABLE sale_items(
          id INTEGER PRIMARY KEY AUTOINCREMENT, sale_id INTEGER NOT NULL REFERENCES sales(id) ON DELETE CASCADE,
          product_id INTEGER, name TEXT, sku TEXT, qty REAL, unit_price REAL, amount REAL, cost REAL, tax_code TEXT)''');
        await d.execute('''CREATE TABLE sale_vat(
          id INTEGER PRIMARY KEY AUTOINCREMENT, sale_id INTEGER NOT NULL REFERENCES sales(id) ON DELETE CASCADE,
          tax_code TEXT, net REAL, vat REAL, gross REAL)''');
        await d.execute('''CREATE TABLE stock_movements(
          id INTEGER PRIMARY KEY AUTOINCREMENT, product_id INTEGER, delta REAL, reason TEXT, ref TEXT, created_at TEXT,
          kind TEXT DEFAULT '', value REAL DEFAULT 0)''');
        await d.execute('''CREATE TABLE purchases(
          id INTEGER PRIMARY KEY AUTOINCREMENT, date TEXT, product_id INTEGER, product_name TEXT, qty REAL, unit_cost REAL,
          net REAL, vat REAL, gross REAL, tax_code TEXT, supplier TEXT, supplier_tin TEXT, invoice_no TEXT, efd_receipt TEXT, paid INTEGER DEFAULT 1)''');
        await d.execute('''CREATE TABLE expenses(
          id INTEGER PRIMARY KEY AUTOINCREMENT, date TEXT, category TEXT, description TEXT,
          net REAL, vat REAL, gross REAL, supplier_tin TEXT, ref TEXT, paid INTEGER DEFAULT 1)''');
        await d.execute('''CREATE TABLE z_reports(
          day TEXT PRIMARY KEY, znum TEXT, xml TEXT, status TEXT, ack_msg TEXT, submitted_at TEXT)''');
        await _v2(d);
        await _v3(d);
        await _v5(d);
      },
    );
  }

  /// v2: books (capital/loans/VAT paid/equipment ledger) and payroll for SDL.
  static Future<void> _v2(DatabaseExecutor d) async {
    await d.execute("CREATE TABLE IF NOT EXISTS equity_ledger(id INTEGER PRIMARY KEY AUTOINCREMENT, date TEXT, type TEXT, amount REAL, note TEXT, ref_type TEXT DEFAULT '', ref_id INTEGER DEFAULT 0)");
    await d.execute("CREATE TABLE IF NOT EXISTS employees(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, tin TEXT DEFAULT '', nida TEXT DEFAULT '', kind TEXT DEFAULT 'permanent', basic REAL DEFAULT 0, allowances REAL DEFAULT 0, active INTEGER DEFAULT 1)");
    await d.execute('CREATE TABLE IF NOT EXISTS payroll(id INTEGER PRIMARY KEY AUTOINCREMENT, period TEXT NOT NULL, employee_id INTEGER NOT NULL REFERENCES employees(id) ON DELETE CASCADE, basic REAL, allowances REAL, other REAL DEFAULT 0, UNIQUE(period, employee_id))');
  }

  /// v3: fixed-asset register (depreciation is computed from it, not typed in).
  static Future<void> _v3(DatabaseExecutor d) async {
    await d.execute("CREATE TABLE IF NOT EXISTS assets(id INTEGER PRIMARY KEY AUTOINCREMENT, date TEXT NOT NULL, cls TEXT NOT NULL, description TEXT DEFAULT '', cost REAL NOT NULL)");
  }

  /// v5: sales returns (credit notes) and purchase returns (debit notes).
  static Future<void> _v5(DatabaseExecutor d) async {
    await d.execute("""CREATE TABLE IF NOT EXISTS sale_returns(
      id INTEGER PRIMARY KEY AUTOINCREMENT, created_at TEXT NOT NULL, day TEXT NOT NULL,
      sale_id INTEGER NOT NULL REFERENCES sales(id), reason TEXT DEFAULT '',
      total_excl REAL, total_vat REAL, total_incl REAL, cogs REAL DEFAULT 0, credit INTEGER DEFAULT 0,
      upload_status TEXT DEFAULT 'manual', attempts INTEGER DEFAULT 0, last_error TEXT, ack_code TEXT, ack_msg TEXT,
      fiscal_no TEXT DEFAULT '', verify_code TEXT DEFAULT '', verify_url TEXT DEFAULT '')""");
    await d.execute('CREATE INDEX IF NOT EXISTS idx_sret_day ON sale_returns(day)');
    await d.execute("""CREATE TABLE IF NOT EXISTS sale_return_items(
      id INTEGER PRIMARY KEY AUTOINCREMENT, return_id INTEGER NOT NULL REFERENCES sale_returns(id) ON DELETE CASCADE,
      sale_item_id INTEGER, product_id INTEGER, name TEXT, sku TEXT, qty REAL, unit_price REAL, amount REAL, cost REAL, tax_code TEXT)""");
    await d.execute("""CREATE TABLE IF NOT EXISTS return_vat(
      id INTEGER PRIMARY KEY AUTOINCREMENT, return_id INTEGER NOT NULL REFERENCES sale_returns(id) ON DELETE CASCADE,
      tax_code TEXT, net REAL, vat REAL, gross REAL)""");
    await d.execute("""CREATE TABLE IF NOT EXISTS purchase_returns(
      id INTEGER PRIMARY KEY AUTOINCREMENT, created_at TEXT NOT NULL, day TEXT NOT NULL,
      purchase_id INTEGER NOT NULL REFERENCES purchases(id), product_id INTEGER, product_name TEXT,
      qty REAL, net REAL, vat REAL, gross REAL, note TEXT DEFAULT '', unpaid INTEGER DEFAULT 0)""");
    await d.execute('CREATE INDEX IF NOT EXISTS idx_pret_day ON purchase_returns(day)');
  }

  /// ALTER TABLE ADD COLUMN only when the column does not exist yet.
  static Future<void> _addCol(DatabaseExecutor d, String table, String col, String ddl) async {
    final cols = await d.rawQuery('PRAGMA table_info($table)');
    if (cols.any((c) => c['name'] == col)) return;
    await d.execute('ALTER TABLE $table ADD COLUMN $col $ddl');
  }
}
