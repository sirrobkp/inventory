/// Property, plant & equipment classes and depreciation rates (reducing balance, per annum).
const assetClasses = {
  'furniture': 'Office furniture & fittings',
  'computers': 'Office computers',
  'equipment': 'Equipment & machinery',
  'vehicles': 'Motor vehicles',
};
const assetRates = {'furniture': 0.125, 'computers': 0.333, 'equipment': 0.125, 'vehicles': 0.25};

class Asset {
  Asset({this.id, required this.date, required this.cls, required this.description, required this.cost});
  final int? id;
  final DateTime date;
  final String cls, description;
  final double cost;

  factory Asset.fromMap(Map<String, Object?> m) => Asset(
        id: m['id'] as int?,
        date: DateTime.parse(m['date'] as String),
        cls: m['cls'] as String,
        description: (m['description'] as String?) ?? '',
        cost: (m['cost'] as num).toDouble(),
      );

  /// Accumulated depreciation at [d] (inclusive): reducing balance on the opening net book value of each
  /// calendar year, pro-rated by whole months in service (month of purchase counts as a full month).
  double accDepAt(DateTime d) {
    if (d.isBefore(date)) return 0;
    final rate = assetRates[cls] ?? 0;
    var acc = 0.0;
    for (var y = date.year; y <= d.year; y++) {
      final startMonth = y == date.year ? date.month : 1;
      final endMonth = y == d.year ? d.month : 12;
      acc += (cost - acc) * rate * (endMonth - startMonth + 1) / 12;
    }
    return acc > cost ? cost : acc;
  }
}
