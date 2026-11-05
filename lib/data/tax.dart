/// TRA VAT classes. Rates/codes follow the common EFDMS mapping (A..E -> 1..5).
/// Registration returns the authoritative TAXITEMS for your VFD - confirm these match.
const taxNames = {
  'A': 'A - Standard 18%',
  'B': 'B - Special rate',
  'C': 'C - Zero rated',
  'D': 'D - Special relief',
  'E': 'E - Exempt',
};
const taxRates = {'A': 0.18, 'B': 0.0, 'C': 0.0, 'D': 0.0, 'E': 0.0};
const taxTraCode = {'A': 1, 'B': 2, 'C': 3, 'D': 4, 'E': 5};
const taxLetters = ['A', 'B', 'C', 'D', 'E'];

/// Label -> EFDMS PMTTYPE
const payTypes = {
  'Cash': 'CASH',
  'Mobile money': 'EMONEY',
  'Card': 'CCARD',
  'Cheque': 'CHEQUE',
  'Invoice': 'INVOICE',
};

double r2(double v) => (v * 100).roundToDouble() / 100;

/// Prices are VAT-inclusive (retail). Splits a gross amount into net + VAT.
({double net, double vat}) splitGross(double gross, String code) {
  final r = taxRates[code] ?? 0;
  final net = r2(gross / (1 + r));
  return (net: net, vat: r2(gross - net));
}

String fmtQty(double q) => q == q.roundToDouble() ? q.toStringAsFixed(0) : q.toStringAsFixed(3).replaceFirst(RegExp(r'0+$'), '');
