import 'dart:io';

import 'package:excel/excel.dart';
import 'package:path_provider/path_provider.dart';

import '../data/models.dart';
import '../data/repo.dart';

class SdlResult {
  SdlResult(this.file, this.notes);
  final File file;
  final List<String> notes; // what was matched / filled - shown to the user for verification
}

/// Skills & Development Levy return.
/// - Computes SDL = rate x total gross emoluments.
/// - If the user imported TRA's own Excel template, fills it IN PLACE (header names are matched
///   heuristically, formulas are never overwritten, every action is reported in [SdlResult.notes]).
/// - Otherwise writes a clean standard workbook.
class SdlService {
  SdlService(this.repo);
  final Repo repo;

  Future<File> get templateFile async => File('${(await getApplicationDocumentsDirectory()).path}/sdl_template.xlsx');
  Future<bool> get hasTemplate async => (await templateFile).exists();

  Future<void> importTemplate(String path) async {
    final bytes = await File(path).readAsBytes();
    Excel.decodeBytes(bytes); // throws if it is not a readable .xlsx
    await (await templateFile).writeAsBytes(bytes, flush: true);
  }

  Future<void> removeTemplate() async {
    final f = await templateFile;
    if (await f.exists()) await f.delete();
  }

  static double rateOf(Map<String, String> cfg) => (double.tryParse(cfg['sdl_rate'] ?? '') ?? 3.5) / 100;
  static int thresholdOf(Map<String, String> cfg) => int.tryParse(cfg['sdl_threshold'] ?? '') ?? 10;

  // ---------------------------------------------------------------- helpers
  String _text(Data? d) {
    final v = d?.value;
    if (v == null) return '';
    if (v is TextCellValue) return v.value.toString();
    return v.toString();
  }

  String? _classify(String raw) {
    final t = raw.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.isEmpty) return null;
    if (const ['s/n', 's.n', 'sn', 's/no', 'no', 'no.', '#'].contains(t)) return 'sn';
    if (t.contains('employer')) return null;
    if (RegExp(r'\btin\b').hasMatch(t) || t.contains('tax identification')) return 'tin';
    if (t.contains('nida') || t.contains('national id') || RegExp(r'\bid (no|number)').hasMatch(t)) return 'nida';
    if (t.contains('basic')) return 'basic';
    if (t.contains('allowance')) return 'allow';
    if (t.contains('gross') || t.contains('emolument')) return 'gross';
    if (RegExp(r'\bsdl\b').hasMatch(t) || t.contains('levy')) return 'sdl';
    if (t.contains('name')) return 'name';
    if (t.contains('type') || t.contains('category')) return 'kind';
    return null;
  }

  ({int row, Map<String, int> cols})? _findHeader(Sheet sh) {
    final maxR = sh.maxRows < 60 ? sh.maxRows : 60;
    for (var r = 0; r < maxR; r++) {
      final cols = <String, int>{};
      final row = sh.row(r);
      for (var c = 0; c < row.length; c++) {
        final f = _classify(_text(row[c]));
        if (f != null && !cols.containsKey(f)) cols[f] = c;
      }
      if (cols.length >= 3 && (cols.containsKey('name') || cols.containsKey('gross'))) return (row: r, cols: cols);
    }
    return null;
  }

  void _set(Sheet sh, int r, int c, CellValue v) {
    final idx = CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r);
    if (sh.cell(idx).value is FormulaCellValue) return; // never overwrite template formulas
    sh.updateCell(idx, v);
  }

  Future<File> _out(String period) async {
    final d = Directory('${(await getApplicationDocumentsDirectory()).path}/exports');
    if (!await d.exists()) await d.create(recursive: true);
    return File('${d.path}/SDL_return_$period.xlsx');
  }

  // ----------------------------------------------------------------- export
  Future<SdlResult> export(String period, Map<String, String> cfg) async {
    final lines = await repo.payrollFor(period);
    if (lines.isEmpty) throw StateError('Add employees first');
    final rate = rateOf(cfg);
    final totalGross = lines.fold<double>(0, (a, l) => a + l.gross);
    final tpl = await templateFile;
    if (await tpl.exists()) return _fillTemplate(tpl, period, cfg, lines, rate, totalGross);
    return _standard(period, cfg, lines, rate, totalGross);
  }

  Future<SdlResult> _fillTemplate(File tpl, String period, Map<String, String> cfg, List<PayLine> lines, double rate, double totalGross) async {
    final ex = Excel.decodeBytes(await tpl.readAsBytes());
    final notes = <String>[];
    var filled = false;
    final sdlTotal = totalGross * rate;

    for (final name in ex.tables.keys.toList()) {
      final sh = ex.tables[name]!;
      final h = _findHeader(sh);
      if (h == null) continue;
      filled = true;
      for (var i = 0; i < lines.length; i++) {
        final l = lines[i];
        final r = h.row + 1 + i;
        final c = h.cols;
        if (c.containsKey('sn')) _set(sh, r, c['sn']!, IntCellValue(i + 1));
        if (c.containsKey('name')) _set(sh, r, c['name']!, TextCellValue(l.emp.name));
        if (c.containsKey('tin')) _set(sh, r, c['tin']!, TextCellValue(l.emp.tin));
        if (c.containsKey('nida')) _set(sh, r, c['nida']!, TextCellValue(l.emp.nida));
        if (c.containsKey('kind')) _set(sh, r, c['kind']!, TextCellValue(l.emp.kind == 'casual' ? 'Casual' : 'Permanent'));
        if (c.containsKey('basic')) _set(sh, r, c['basic']!, DoubleCellValue(l.basic));
        if (c.containsKey('allow')) _set(sh, r, c['allow']!, DoubleCellValue(l.allowances + l.other));
        if (c.containsKey('gross')) _set(sh, r, c['gross']!, DoubleCellValue(l.gross));
        if (c.containsKey('sdl')) _set(sh, r, c['sdl']!, DoubleCellValue(l.gross * rate));
      }
      notes.add('Sheet "$name": header on row ${h.row + 1}; matched columns: ${h.cols.keys.join(', ')}; wrote ${lines.length} employees.');
      const all = ['sn', 'name', 'tin', 'nida', 'kind', 'basic', 'allow', 'gross', 'sdl'];
      final missing = all.where((f) => !h.cols.containsKey(f)).toList();
      if (missing.isNotEmpty) notes.add('Not found in this sheet (left as is): ${missing.join(', ')}.');

      // labelled summary cells outside the employee table (only written into EMPTY cells to the right)
      final lastData = h.row + lines.length;
      for (var r = 0; r < sh.maxRows; r++) {
        if (r >= h.row && r <= lastData) continue;
        final row = sh.row(r);
        for (var c = 0; c < row.length; c++) {
          final t = _text(row[c]).toLowerCase().trim();
          if (t.isEmpty || t.length > 90) continue;
          CellValue? v;
          String what = '';
          if (t.contains('total') && (t.contains('gross') || t.contains('emolument'))) {
            v = DoubleCellValue(totalGross);
            what = 'total gross emoluments';
          } else if ((RegExp(r'\bsdl\b').hasMatch(t) || t.contains('levy')) && (t.contains('payable') || t.contains('due') || t.contains('amount') || t.contains('total'))) {
            v = DoubleCellValue(sdlTotal);
            what = 'SDL payable';
          } else if (RegExp(r'(number|no\.?) of employees').hasMatch(t)) {
            v = IntCellValue(lines.length);
            what = 'number of employees';
          } else if (t.contains('employer') && RegExp(r'\btin\b').hasMatch(t) && (cfg['tin'] ?? '').isNotEmpty) {
            v = TextCellValue(cfg['tin']!);
            what = 'employer TIN';
          } else if (t.contains('name of employer') || t == 'employer name' || t == 'employer') {
            final n = (cfg['biz_name'] ?? '').isNotEmpty ? cfg['biz_name']! : (cfg['name'] ?? '');
            if (n.isNotEmpty) {
              v = TextCellValue(n);
              what = 'employer name';
            }
          }
          if (v == null) continue;
          for (var k = c + 1; k <= c + 3; k++) {
            final idx = CellIndex.indexByColumnRow(columnIndex: k, rowIndex: r);
            if (sh.cell(idx).value == null) {
              sh.updateCell(idx, v);
              notes.add('Row ${r + 1}: filled $what next to "${_text(row[c]).trim()}".');
              break;
            }
          }
        }
      }
    }

    if (!filled) {
      const sn = 'SDL (generated)';
      _writeStandardSheet(ex[sn], period, cfg, lines, rate, totalGross);
      notes.add("Could not recognise the layout of your template (no header row with names/TIN/gross). A standard 'SDL (generated)' sheet was added to the workbook instead.");
    } else {
      notes.add('Check employer details, the month/period cells and any totals formulas in your template before uploading.');
    }
    final bytes = ex.save();
    if (bytes == null) throw StateError('Could not write the workbook');
    final f = await _out(period);
    await f.writeAsBytes(bytes, flush: true);
    return SdlResult(f, notes);
  }

  void _writeStandardSheet(Sheet sh, String period, Map<String, String> cfg, List<PayLine> lines, double rate, double totalGross) {
    final bizName = (cfg['biz_name'] ?? '').isNotEmpty ? cfg['biz_name']! : (cfg['name'] ?? '');
    void bold(int row, int cols) {
      for (var c = 0; c < cols; c++) {
        sh.cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: row)).cellStyle = CellStyle(bold: true);
      }
    }

    sh.appendRow([TextCellValue('SKILLS AND DEVELOPMENT LEVY - MONTHLY RETURN')]);
    bold(0, 1);
    sh.appendRow([TextCellValue('Employer'), TextCellValue(bizName)]);
    sh.appendRow([TextCellValue('Employer TIN'), TextCellValue(cfg['tin'] ?? '')]);
    sh.appendRow([TextCellValue('Period (yyyy-MM)'), TextCellValue(period)]);
    sh.appendRow([TextCellValue('SDL rate'), TextCellValue('${(rate * 100).toStringAsFixed(2)}%')]);
    sh.appendRow([TextCellValue('')]);
    sh.appendRow([TextCellValue('S/N'), TextCellValue('Employee name'), TextCellValue('TIN'), TextCellValue('NIDA'), TextCellValue('Employee type'), TextCellValue('Basic salary'), TextCellValue('Allowances & other'), TextCellValue('Total gross emoluments'), TextCellValue('SDL')]);
    bold(6, 9);
    for (var i = 0; i < lines.length; i++) {
      final l = lines[i];
      sh.appendRow([IntCellValue(i + 1), TextCellValue(l.emp.name), TextCellValue(l.emp.tin), TextCellValue(l.emp.nida), TextCellValue(l.emp.kind == 'casual' ? 'Casual' : 'Permanent'), DoubleCellValue(l.basic), DoubleCellValue(l.allowances + l.other), DoubleCellValue(l.gross), DoubleCellValue(l.gross * rate)]);
    }
    sh.appendRow([TextCellValue(''), TextCellValue('TOTAL'), TextCellValue(''), TextCellValue(''), TextCellValue(''), DoubleCellValue(lines.fold<double>(0, (a, l) => a + l.basic)), DoubleCellValue(lines.fold<double>(0, (a, l) => a + l.allowances + l.other)), DoubleCellValue(totalGross), DoubleCellValue(totalGross * rate)]);
    bold(7 + lines.length, 9);
    sh.appendRow([TextCellValue('')]);
    sh.appendRow([TextCellValue('SDL payable'), TextCellValue((totalGross * rate).toStringAsFixed(2))]);
    sh.appendRow([TextCellValue('Number of employees'), IntCellValue(lines.length)]);
  }

  Future<SdlResult> _standard(String period, Map<String, String> cfg, List<PayLine> lines, double rate, double totalGross) async {
    final ex = Excel.createExcel();
    const sn = 'SDL Return';
    ex.rename('Sheet1', sn);
    _writeStandardSheet(ex[sn], period, cfg, lines, rate, totalGross);
    final bytes = ex.save();
    if (bytes == null) throw StateError('Could not write the workbook');
    final f = await _out(period);
    await f.writeAsBytes(bytes, flush: true);
    return SdlResult(f, ['No TRA template imported - wrote a standard SDL workbook. Import your TRA template to have it filled in place.']);
  }
}
