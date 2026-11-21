import 'package:intl/intl.dart';

double _n(Object? v) => (v as num?)?.toDouble() ?? 0;

class Product {
  Product({
    this.id,
    required this.name,
    required this.sku,
    this.barcode = '',
    this.category = 'General',
    this.unit = 'pc',
    this.cost = 0,
    required this.price,
    this.stock = 0,
    this.reorderLevel = 5,
    this.taxCode = 'A',
  });
  int? id;
  String name, sku, barcode, category, unit, taxCode;
  double cost, price, stock, reorderLevel;

  factory Product.fromMap(Map<String, Object?> m) => Product(
        id: m['id'] as int?,
        name: m['name'] as String,
        sku: m['sku'] as String,
        barcode: (m['barcode'] as String?) ?? '',
        category: (m['category'] as String?) ?? 'General',
        unit: (m['unit'] as String?) ?? 'pc',
        cost: _n(m['cost']),
        price: _n(m['price']),
        stock: _n(m['stock']),
        reorderLevel: _n(m['reorder_level']),
        taxCode: (m['tax_code'] as String?) ?? 'A',
      );

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'name': name,
        'sku': sku,
        'barcode': barcode,
        'category': category,
        'unit': unit,
        'cost': cost,
        'price': price,
        'stock': stock,
        'reorder_level': reorderLevel,
        'tax_code': taxCode,
        'active': 1,
        'updated_at': DateTime.now().toIso8601String(),
      };

  bool get low => stock <= reorderLevel;

  String get initials {
    final w = name.trim().split(RegExp(r'\s+')).where((e) => e.isNotEmpty).toList();
    if (w.isEmpty) return '?';
    if (w.length == 1) return w.first.substring(0, w.first.length > 1 ? 2 : 1).toUpperCase();
    return (w[0][0] + w[1][0]).toUpperCase();
  }
}

class CartLine {
  CartLine(this.product, this.qty);
  final Product product;
  double qty;
  double get amount => (product.price * qty * 100).roundToDouble() / 100;
}

class SaleItem {
  SaleItem({this.id, required this.productId, required this.name, required this.sku, required this.qty, required this.unitPrice, required this.amount, required this.cost, required this.taxCode});
  final int? id, productId;
  final String name, sku, taxCode;
  final double qty, unitPrice, amount, cost;
  factory SaleItem.fromMap(Map<String, Object?> m) => SaleItem(
        id: m['id'] as int?,
        productId: m['product_id'] as int?,
        name: m['name'] as String,
        sku: (m['sku'] as String?) ?? '',
        qty: _n(m['qty']),
        unitPrice: _n(m['unit_price']),
        amount: _n(m['amount']),
        cost: _n(m['cost']),
        taxCode: (m['tax_code'] as String?) ?? 'A',
      );
}

class VatLine {
  VatLine(this.code, this.net, this.vat, this.gross);
  final String code;
  final double net, vat, gross;
}

class Sale {
  Sale({
    this.id,
    required this.createdAt,
    required this.day,
    required this.gc,
    required this.dc,
    required this.znum,
    required this.rctvnum,
    required this.fiscal,
    required this.customerName,
    required this.customerIdType,
    required this.customerId,
    required this.mobile,
    required this.paymentType,
    required this.totalExcl,
    required this.totalVat,
    required this.totalIncl,
    required this.cogs,
    required this.uploadStatus,
    required this.attempts,
    this.lastError,
    this.ackCode,
    this.ackMsg,
    this.fiscalNo = '',
    this.verifyLink = '',
    this.items = const [],
    this.vat = const [],
  });
  final int? id;
  final DateTime createdAt;
  final String day, znum, rctvnum, customerName, customerId, mobile, paymentType, uploadStatus, fiscalNo, verifyLink;
  final int gc, dc, customerIdType, attempts;
  final bool fiscal;
  final double totalExcl, totalVat, totalIncl, cogs;
  final String? lastError, ackCode, ackMsg;
  final List<SaleItem> items;
  final List<VatLine> vat;

  factory Sale.fromMap(Map<String, Object?> m, {List<SaleItem> items = const [], List<VatLine> vat = const []}) => Sale(
        id: m['id'] as int?,
        createdAt: DateTime.parse(m['created_at'] as String),
        day: m['day'] as String,
        gc: (m['gc'] as int?) ?? 0,
        dc: (m['dc'] as int?) ?? 0,
        znum: (m['znum'] as String?) ?? '',
        rctvnum: (m['rctvnum'] as String?) ?? '',
        fiscal: (m['fiscal'] as int? ?? 1) == 1,
        customerName: (m['customer_name'] as String?) ?? '',
        customerIdType: (m['customer_id_type'] as int?) ?? 6,
        customerId: (m['customer_id'] as String?) ?? '',
        mobile: (m['mobile'] as String?) ?? '',
        paymentType: (m['payment_type'] as String?) ?? 'CASH',
        totalExcl: _n(m['total_excl']),
        totalVat: _n(m['total_vat']),
        totalIncl: _n(m['total_incl']),
        cogs: _n(m['cogs']),
        uploadStatus: (m['upload_status'] as String?) ?? 'queued',
        attempts: (m['attempts'] as int?) ?? 0,
        lastError: m['last_error'] as String?,
        ackCode: m['ack_code'] as String?,
        ackMsg: m['ack_msg'] as String?,
        fiscalNo: (m['fiscal_no'] as String?) ?? '',
        verifyLink: (m['verify_url'] as String?) ?? '',
        items: items,
        vat: vat,
      );

  /// Receipt label shown to customer, e.g. "TZ-000123" (GC) - non-fiscal sales use "NF-<id>".
  String get number => fiscal ? (fiscalNo.isNotEmpty ? fiscalNo : gc.toString().padLeft(6, '0')) : 'NF-${id ?? 0}';

  /// TRA receipt verification URL / QR payload.
  /// Supplier-issued link wins; supplier code without link -> the code itself; direct EFDMS -> TRA verify URL.
  String get verifyUrl {
    if (verifyLink.isNotEmpty) return verifyLink;
    if (rctvnum.isEmpty) return '';
    if (fiscalNo.isNotEmpty) return rctvnum;
    return 'https://verify.tra.go.tz/${rctvnum}_${DateFormat('HHmmss').format(createdAt)}';
  }

  /// A sample receipt used to preview what will be sent to a supplier API.
  factory Sale.sample() {
    final now = DateTime.now();
    return Sale(
      id: 0, createdAt: now, day: DateFormat('yyyy-MM-dd').format(now), gc: 1, dc: 1, znum: DateFormat('yyyyMMdd').format(now), rctvnum: '',
      fiscal: true, customerName: 'Sample Customer', customerIdType: 1, customerId: '123-456-789', mobile: '0712345678', paymentType: 'CASH',
      totalExcl: 16949.15, totalVat: 3050.85, totalIncl: 20000, cogs: 12000, uploadStatus: 'queued', attempts: 0,
      items: [SaleItem(productId: 1, name: 'Sample item', sku: 'SKU-1', qty: 2, unitPrice: 10000, amount: 20000, cost: 6000, taxCode: 'A')],
      vat: [VatLine('A', 16949.15, 3050.85, 20000)],
    );
  }

  bool get uploaded => uploadStatus == 'uploaded';
}

class Dashboard {
  Dashboard({this.todayRevenue = 0, this.todayCount = 0, this.monthNet = 0, this.monthCogs = 0, this.stockValue = 0, this.productCount = 0, this.week = const [0, 0, 0, 0, 0, 0, 0], this.pendingCount = 0, this.pendingTotal = 0, this.monthGross = 0, this.monthOutputVat = 0});
  final double todayRevenue, monthNet, monthCogs, stockValue, pendingTotal, monthGross, monthOutputVat;
  final int todayCount, productCount, pendingCount;
  final List<double> week;
  double get grossMargin => monthNet <= 0 ? 0 : (monthNet - monthCogs) / monthNet * 100;
}

/// Aggregated figures for a reporting period.
class Statement {
  Statement({
    required this.salesByClass,
    required this.cogs,
    required this.expensesByCat,
    required this.purchasesNet,
    required this.purchasesVat,
    required this.expensesNet,
    required this.expensesVat,
    required this.paymentTotals,
    required this.receiptCount,
    required this.stockValue,
    this.adjustments = 0,
  });
  final Map<String, VatLine> salesByClass; // code -> net/vat/gross
  final double cogs, purchasesNet, purchasesVat, expensesNet, expensesVat, stockValue, adjustments; // adjustments: signed stock gain/(loss)
  final Map<String, double> expensesByCat, paymentTotals;
  final int receiptCount;

  double get revenueNet => salesByClass.values.fold(0, (a, b) => a + b.net);
  double get outputVat => salesByClass.values.fold(0, (a, b) => a + b.vat);
  double get revenueGross => salesByClass.values.fold(0, (a, b) => a + b.gross);
  double get grossProfit => revenueNet - cogs;
  double get netProfit => grossProfit + adjustments - expensesNet;
  double get inputVat => purchasesVat + expensesVat;
  double get vatPayable => outputVat - inputVat;
}

class Purchase {
  Purchase(this.date, this.product, this.qty, this.net, this.vat, this.gross, this.supplier, this.supplierTin, this.invoiceNo, this.efdReceipt, {this.id, this.paid = true, this.returned = 0, this.productId});
  final String date, product, supplier, supplierTin, invoiceNo, efdReceipt;
  final double qty, net, vat, gross, returned;
  final int? id, productId;
  final bool paid;
  double get returnable => qty - returned;
  factory Purchase.fromMap(Map<String, Object?> m) => Purchase(
        m['date'] as String,
        (m['product_name'] as String?) ?? '',
        _n(m['qty']),
        _n(m['net']),
        _n(m['vat']),
        _n(m['gross']),
        (m['supplier'] as String?) ?? '',
        (m['supplier_tin'] as String?) ?? '',
        (m['invoice_no'] as String?) ?? '',
        (m['efd_receipt'] as String?) ?? '',
        id: m['id'] as int?,
        paid: (m['paid'] as int? ?? 1) == 1,
        returned: _n(m['returned']),
        productId: m['product_id'] as int?,
      );
}

class Expense {
  Expense(this.date, this.category, this.description, this.net, this.vat, this.gross, this.supplierTin, this.ref);
  final String date, category, description, supplierTin, ref;
  final double net, vat, gross;
  factory Expense.fromMap(Map<String, Object?> m) => Expense(
        m['date'] as String,
        (m['category'] as String?) ?? '',
        (m['description'] as String?) ?? '',
        _n(m['net']),
        _n(m['vat']),
        _n(m['gross']),
        (m['supplier_tin'] as String?) ?? '',
        (m['ref'] as String?) ?? '',
      );
}

class Employee {
  Employee({this.id, required this.name, this.tin = '', this.nida = '', this.kind = 'permanent', this.basic = 0, this.allowances = 0});
  int? id;
  String name, tin, nida, kind; // kind: permanent | casual
  double basic, allowances;
  factory Employee.fromMap(Map<String, Object?> m) => Employee(
        id: m['id'] as int?,
        name: m['name'] as String,
        tin: (m['tin'] as String?) ?? '',
        nida: (m['nida'] as String?) ?? '',
        kind: (m['kind'] as String?) ?? 'permanent',
        basic: _n(m['basic']),
        allowances: _n(m['allowances']),
      );
  Map<String, Object?> toMap() => {if (id != null) 'id': id, 'name': name, 'tin': tin, 'nida': nida, 'kind': kind, 'basic': basic, 'allowances': allowances, 'active': 1};
}

class PayLine {
  PayLine(this.emp, this.basic, this.allowances, this.other);
  final Employee emp;
  final double basic, allowances, other;
  double get gross => basic + allowances + other;
}

/// Cumulative position of the books up to (and including) a date.
/// Everything is derived from sales, purchases, expenses, stock movements, the fixed-asset register and the
/// capital/tax ledger, so Assets = Liabilities + Equity holds by construction (verified by simulation).
class Cum {
  Cum({
    this.salesGross = 0, this.salesCredit = 0, this.salesNet = 0, this.salesVat = 0, this.cogs = 0,
    this.purchGross = 0, this.purchNet = 0, this.purchVat = 0, this.purchUnpaid = 0,
    this.expNet = 0, this.expVat = 0, this.expGross = 0, this.expUnpaid = 0, this.auditUnpaid = 0,
    this.openingStock = 0, this.adjustments = 0,
    this.capital = 0, this.drawings = 0, this.loanIn = 0, this.loanOut = 0, this.vatPaid = 0, this.taxPaid = 0,
    this.recCollected = 0, this.supPaid = 0, this.accPaid = 0,
    this.assetCost = 0, this.depreciation = 0, this.taxRate = 0.30,
    this.costByClass = const {}, this.depByClass = const {},
  });
  final double salesGross, salesCredit, salesNet, salesVat, cogs, purchGross, purchNet, purchVat, purchUnpaid, expNet, expVat, expGross, expUnpaid, auditUnpaid, openingStock, adjustments, capital, drawings, loanIn, loanOut, vatPaid, taxPaid, recCollected, supPaid, accPaid, assetCost, depreciation, taxRate;
  final Map<String, double> costByClass, depByClass;

  double get cash => capital + loanIn - loanOut + (salesGross - salesCredit) + recCollected - (purchGross - purchUnpaid) - supPaid - (expGross - expUnpaid) - accPaid - vatPaid - taxPaid - drawings - assetCost;
  double get receivables => salesCredit - recCollected;
  double get inventory => openingStock + purchNet - cogs + adjustments;
  double get fixedAssets => assetCost - depreciation;
  double get vatNet => salesVat - purchVat - expVat - vatPaid; // >0 payable, <0 recoverable
  double get tradePayables => purchUnpaid - supPaid;
  double get accrued => expUnpaid - accPaid;
  double get loans => loanIn - loanOut;
  double get pbt => salesNet - cogs + adjustments - expNet - depreciation; // profit before tax
  double get tax => pbt > 0 ? pbt * taxRate : 0;
  double get netTax => tax - taxPaid; // >0 payable, <0 provisional tax paid (asset)
  double get profitAfterTax => pbt - tax;
  double get equity => capital + openingStock - drawings + profitAfterTax;
  double get imbalance =>
      (cash + inventory + fixedAssets + receivables + (vatNet < 0 ? -vatNet : 0) + (netTax < 0 ? -netTax : 0)) -
      (loans + tradePayables + accrued + (vatNet > 0 ? vatNet : 0) + (netTax > 0 ? netTax : 0)) -
      equity;
}

/// Statement figures for one reporting period plus the opening/closing books.
class Period {
  Period(this.st, this.open, this.close);
  final Statement st;
  final Cum open, close;
}

/// An item of an original sale with the quantity that can still be returned.
class ReturnableItem {
  ReturnableItem(this.item, this.remaining);
  final SaleItem item;
  final double remaining;
}

/// A sales return = credit note.
class SaleReturn {
  SaleReturn({required this.id, required this.createdAt, required this.day, required this.saleId, required this.saleNumber, required this.reason, required this.totalExcl, required this.totalVat, required this.totalIncl, required this.cogs, required this.credit, required this.uploadStatus, this.lastError, this.ackMsg, this.fiscalNo = '', this.verifyCode = '', this.verifyUrl = '', this.items = const [], this.vat = const []});
  final int id, saleId;
  final DateTime createdAt;
  final String day, saleNumber, reason, uploadStatus, fiscalNo, verifyCode, verifyUrl;
  final double totalExcl, totalVat, totalIncl, cogs;
  final bool credit;
  final String? lastError, ackMsg;
  final List<SaleItem> items;
  final List<VatLine> vat;
  String get number => fiscalNo.isNotEmpty ? fiscalNo : 'CN-${id.toString().padLeft(5, '0')}';
  String get statusLabel => uploadStatus == 'uploaded' ? 'Fiscalised' : uploadStatus == 'queued' ? 'Queued for supplier' : uploadStatus == 'failed' ? 'Rejected' : uploadStatus == 'manual' ? 'Issue manually' : 'Non-fiscal';

  factory SaleReturn.fromMap(Map<String, Object?> m, {List<SaleItem> items = const [], List<VatLine> vat = const []}) {
    final gc = (m['gc'] as int?) ?? 0;
    final fn = (m['sale_fiscal_no'] as String?) ?? '';
    return SaleReturn(
      id: m['id'] as int,
      createdAt: DateTime.parse(m['created_at'] as String),
      day: m['day'] as String,
      saleId: m['sale_id'] as int,
      saleNumber: fn.isNotEmpty ? fn : (gc > 0 ? gc.toString().padLeft(6, '0') : 'NF-${m['sale_id']}'),
      reason: (m['reason'] as String?) ?? '',
      totalExcl: _n(m['total_excl']),
      totalVat: _n(m['total_vat']),
      totalIncl: _n(m['total_incl']),
      cogs: _n(m['cogs']),
      credit: (m['credit'] as int? ?? 0) == 1,
      uploadStatus: (m['upload_status'] as String?) ?? 'manual',
      lastError: m['last_error'] as String?,
      ackMsg: m['ack_msg'] as String?,
      fiscalNo: (m['fiscal_no'] as String?) ?? '',
      verifyCode: (m['verify_code'] as String?) ?? '',
      verifyUrl: (m['verify_url'] as String?) ?? '',
      items: items,
      vat: vat,
    );
  }
}

/// A purchase return = debit note.
class PurchaseReturn {
  PurchaseReturn({required this.id, required this.createdAt, required this.day, required this.purchaseId, required this.product, required this.qty, required this.net, required this.vat, required this.gross, required this.note, required this.unpaid, this.supplier = '', this.invoiceNo = ''});
  final int id, purchaseId;
  final DateTime createdAt;
  final String day, product, note, supplier, invoiceNo;
  final double qty, net, vat, gross;
  final bool unpaid;
  String get number => 'DN-${id.toString().padLeft(5, '0')}';
  factory PurchaseReturn.fromMap(Map<String, Object?> m) => PurchaseReturn(
        id: m['id'] as int,
        createdAt: DateTime.parse(m['created_at'] as String),
        day: m['day'] as String,
        purchaseId: m['purchase_id'] as int,
        product: (m['product_name'] as String?) ?? '',
        qty: _n(m['qty']),
        net: _n(m['net']),
        vat: _n(m['vat']),
        gross: _n(m['gross']),
        note: (m['note'] as String?) ?? '',
        unpaid: (m['unpaid'] as int? ?? 0) == 1,
        supplier: (m['supplier'] as String?) ?? '',
        invoiceNo: (m['invoice_no'] as String?) ?? '',
      );
}

/// A credit sale (receivable) or credit purchase (payable) with what has been paid so far.
class CreditDoc {
  CreditDoc({required this.id, required this.number, required this.party, required this.date, required this.total, required this.returned, required this.paid, this.detail = ''});
  final int id;
  final String number, party, date, detail;
  final double total, returned, paid;
  double get balance => total - returned - paid;
  bool get settled => balance < 0.5;
}
