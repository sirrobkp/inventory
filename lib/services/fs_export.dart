import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:excel/excel.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'fs_model.dart';

// =============================================================== PDF
Future<Uint8List> fsToPdf(FsDoc d) async {
  final doc = pw.Document();
  doc.addPage(pw.Page(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(50),
    build: (_) => pw.Center(
      child: pw.Column(mainAxisAlignment: pw.MainAxisAlignment.center, children: [
        for (var i = 0; i < d.cover.length; i++)
          pw.Padding(
            padding: pw.EdgeInsets.only(bottom: i == 0 ? 18 : 6),
            child: pw.Text(d.cover[i], textAlign: pw.TextAlign.center, style: pw.TextStyle(fontSize: i == 0 ? 22 : (i == 1 ? 16 : 11), fontWeight: i <= 1 ? pw.FontWeight.bold : pw.FontWeight.normal)),
          ),
      ]),
    ),
  ));
  final w = <pw.Widget>[];
  for (var i = 0; i < d.sections.length; i++) {
    if (i > 0) w.add(pw.NewPage());
    for (final b in d.sections[i].blocks) {
      w.add(_pw(b));
    }
  }
  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.fromLTRB(44, 40, 44, 40),
    header: (ctx) => pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 10),
      child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Text(d.company.toUpperCase(), style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
        pw.Text('FINANCIAL STATEMENTS ${d.periodTitle}', style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
        pw.Divider(thickness: 0.5),
      ]),
    ),
    footer: (ctx) => pw.Align(alignment: pw.Alignment.centerRight, child: pw.Text('${ctx.pageNumber}', style: const pw.TextStyle(fontSize: 9))),
    build: (_) => w,
  ));
  return doc.save();
}

pw.Widget _pw(Block b) {
  if (b is BTitle) return pw.Padding(padding: const pw.EdgeInsets.only(bottom: 10), child: pw.Text(b.text, style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold)));
  if (b is BHead) return pw.Padding(padding: const pw.EdgeInsets.only(top: 14, bottom: 5), child: pw.Text(b.text, style: pw.TextStyle(fontSize: 11.5, fontWeight: pw.FontWeight.bold)));
  if (b is BSub) return pw.Text(b.text, style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold));
  if (b is BGap) return pw.SizedBox(height: b.h);
  if (b is BPara) {
    final t = pw.Text(b.text, textAlign: b.center ? pw.TextAlign.center : pw.TextAlign.justify, style: pw.TextStyle(fontSize: b.size, lineSpacing: 2.5, fontWeight: b.bold ? pw.FontWeight.bold : pw.FontWeight.normal));
    return pw.Padding(padding: const pw.EdgeInsets.only(bottom: 7), child: b.center ? pw.Center(child: t) : t);
  }
  if (b is BRow) {
    return pw.Container(
      decoration: b.topLine ? const pw.BoxDecoration(border: pw.Border(top: pw.BorderSide(width: 0.6))) : null,
      padding: pw.EdgeInsets.only(top: 3, bottom: 3, left: b.indent * 14.0),
      child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
        pw.Expanded(child: pw.Text(b.label, style: pw.TextStyle(fontSize: 10, fontWeight: b.bold ? pw.FontWeight.bold : pw.FontWeight.normal))),
        pw.Text(b.value, style: pw.TextStyle(fontSize: 10, fontWeight: b.bold ? pw.FontWeight.bold : pw.FontWeight.normal)),
      ]),
    );
  }
  if (b is BTable) {
    return pw.TableHelper.fromTextArray(
      headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 8),
      cellStyle: const pw.TextStyle(fontSize: 8),
      headers: b.headers,
      data: b.data,
      cellAlignments: {for (var i = 1; i < b.headers.length; i++) i: pw.Alignment.centerRight},
      headerAlignments: {for (var i = 1; i < b.headers.length; i++) i: pw.Alignment.centerRight},
    );
  }
  return pw.SizedBox();
}

// =============================================================== Word (.docx)
String _x(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

String _runs(String text, {bool bold = false, double size = 9.5}) {
  final rpr = '<w:rPr>${bold ? '<w:b/>' : ''}<w:sz w:val="${(size * 2).round()}"/></w:rPr>';
  return text.split('\n').map((l) => '<w:r>$rpr<w:t xml:space="preserve">${_x(l)}</w:t></w:r>').join('<w:r><w:br/></w:r>');
}

String _p(String runs, {String ppr = ''}) => '<w:p>${ppr.isEmpty ? '' : '<w:pPr>$ppr</w:pPr>'}$runs</w:p>';
const _pageBreak = '<w:p><w:r><w:br w:type="page"/></w:r></w:p>';

bool _isNum(String s) => RegExp(r'^\(?-?[\d,]+(\.\d+)?\)?$').hasMatch(s.trim());

String _docxBlock(Block b) {
  if (b is BTitle) return _p(_runs(b.text, bold: true, size: 13), ppr: '<w:spacing w:before="0" w:after="160"/>');
  if (b is BHead) return _p(_runs(b.text, bold: true, size: 11.5), ppr: '<w:keepNext/><w:spacing w:before="240" w:after="80"/>');
  if (b is BSub) return _p(_runs(b.text, bold: true, size: 10), ppr: '<w:spacing w:before="80" w:after="40"/>');
  if (b is BGap) return _p('', ppr: '<w:spacing w:before="0" w:after="${(b.h * 10).round()}"/>');
  if (b is BPara) return _p(_runs(b.text, bold: b.bold, size: b.size), ppr: '<w:spacing w:before="0" w:after="120"/><w:jc w:val="${b.center ? 'center' : 'both'}"/>');
  if (b is BRow) {
    final border = b.topLine ? '<w:pBdr><w:top w:val="single" w:sz="4" w:space="1" w:color="000000"/></w:pBdr>' : '';
    return _p('${_runs(b.label, bold: b.bold, size: 10)}<w:r><w:tab/></w:r>${_runs(b.value, bold: b.bold, size: 10)}',
        ppr: '$border<w:tabs><w:tab w:val="right" w:pos="9800"/></w:tabs><w:spacing w:before="30" w:after="30"/><w:ind w:left="${b.indent * 280}"/>');
  }
  if (b is BTable) {
    final cols = b.headers.length;
    final first = cols <= 2 ? 6000 : (cols <= 5 ? 2600 : 1900);
    final rest = cols > 1 ? ((9800 - first) ~/ (cols - 1)) : 0;
    String cell(String t, int w, {bool bold = false, bool right = false}) =>
        '<w:tc><w:tcPr><w:tcW w:w="$w" w:type="dxa"/></w:tcPr>${_p(_runs(t, bold: bold, size: 8), ppr: '<w:spacing w:before="20" w:after="20"/>${right ? '<w:jc w:val="right"/>' : ''}')}</w:tc>';
    final rows = StringBuffer();
    rows.write('<w:tr>${[for (var i = 0; i < cols; i++) cell(b.headers[i], i == 0 ? first : rest, bold: true, right: i > 0)].join()}</w:tr>');
    for (final r in b.data) {
      rows.write('<w:tr>${[for (var i = 0; i < cols; i++) cell(i < r.length ? r[i] : '', i == 0 ? first : rest, right: i > 0)].join()}</w:tr>');
    }
    const bd = '<w:top w:val="single" w:sz="4" w:color="808080"/><w:left w:val="single" w:sz="4" w:color="808080"/><w:bottom w:val="single" w:sz="4" w:color="808080"/><w:right w:val="single" w:sz="4" w:color="808080"/><w:insideH w:val="single" w:sz="4" w:color="808080"/><w:insideV w:val="single" w:sz="4" w:color="808080"/>';
    return '<w:tbl><w:tblPr><w:tblW w:w="9800" w:type="dxa"/><w:tblBorders>$bd</w:tblBorders></w:tblPr><w:tblGrid>${[for (var i = 0; i < cols; i++) '<w:gridCol w:w="${i == 0 ? first : rest}"/>'].join()}</w:tblGrid>$rows</w:tbl><w:p/>';
  }
  return '';
}

List<int> fsToDocx(FsDoc d) {
  const ns = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"';
  final body = StringBuffer();
  for (var i = 0; i < d.cover.length; i++) {
    body.write(_p(_runs(d.cover[i], bold: i <= 1, size: i == 0 ? 22 : (i == 1 ? 16 : 11)), ppr: '<w:spacing w:before="${i == 0 ? 3000 : 0}" w:after="200"/><w:jc w:val="center"/>'));
  }
  for (final s in d.sections) {
    body.write(_pageBreak);
    for (final b in s.blocks) {
      body.write(_docxBlock(b));
    }
  }
  body.write('<w:sectPr><w:headerReference w:type="default" r:id="rId2"/><w:footerReference w:type="default" r:id="rId1"/><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1200" w:right="1000" w:bottom="1000" w:left="1000" w:header="500" w:footer="500" w:gutter="0"/></w:sectPr>');
  final document = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document $ns><w:body>$body</w:body></w:document>';
  final footer = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:ftr $ns><w:p><w:pPr><w:jc w:val="right"/></w:pPr><w:r><w:fldChar w:fldCharType="begin"/></w:r><w:r><w:instrText xml:space="preserve"> PAGE </w:instrText></w:r><w:r><w:fldChar w:fldCharType="separate"/></w:r><w:r><w:t>1</w:t></w:r><w:r><w:fldChar w:fldCharType="end"/></w:r></w:p></w:ftr>';
  final header = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:hdr $ns>${_p(_runs(d.company.toUpperCase(), bold: true, size: 10))}${_p(_runs('FINANCIAL STATEMENTS ${d.periodTitle}', bold: true, size: 9))}</w:hdr>';
  const contentTypes = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/footer1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"/><Override PartName="/word/header1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml"/></Types>';
  const rootRels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>';
  const docRels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer" Target="footer1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/header" Target="header1.xml"/></Relationships>';

  final ar = Archive();
  void add(String name, String content) {
    final bytes = utf8.encode(content);
    ar.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  add('[Content_Types].xml', contentTypes);
  add('_rels/.rels', rootRels);
  add('word/document.xml', document);
  add('word/_rels/document.xml.rels', docRels);
  add('word/footer1.xml', footer);
  add('word/header1.xml', header);
  final List<int> out = ZipEncoder().encode(ar) ?? <int>[];
  return out;
}

// =============================================================== Excel (.xlsx)
double? _numOf(String s) {
  final t = s.trim();
  if (!_isNum(t)) return null;
  final neg = t.startsWith('(') || t.startsWith('-');
  final v = double.tryParse(t.replaceAll(RegExp(r'[(),\-]'), ''));
  if (v == null) return null;
  return neg ? -v : v;
}

CellValue _cv(String s) {
  final n = _numOf(s);
  if (n == null) return TextCellValue(s);
  return n == n.roundToDouble() ? IntCellValue(n.toInt()) : DoubleCellValue(n);
}

String _sheetName(String n, Set<String> used) {
  var s = n.replaceAll(RegExp(r'[\[\]:*?/\\]'), ' ').trim();
  if (s.length > 31) s = s.substring(0, 31);
  var out = s, i = 2;
  while (used.contains(out)) {
    out = '${s.substring(0, s.length > 28 ? 28 : s.length)} $i';
    i++;
  }
  used.add(out);
  return out;
}

List<int> fsToXlsx(FsDoc d) {
  final ex = Excel.createExcel();
  final used = <String>{};
  final cover = _sheetName('Cover', used);
  ex.rename('Sheet1', cover);
  final cs = ex[cover];
  cs.setColumnWidth(0, 80);
  for (var i = 0; i < d.cover.length; i++) {
    cs.appendRow([TextCellValue(d.cover[i])]);
    if (i <= 1) cs.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: i)).cellStyle = CellStyle(bold: true);
  }
  for (final s in d.sections) {
    final sh = ex[_sheetName(s.name, used)];
    sh.setColumnWidth(0, 78);
    sh.setColumnWidth(1, 20);
    var r = 0;
    void bold(int row, int cols) {
      for (var c = 0; c < cols; c++) {
        sh.cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: row)).cellStyle = CellStyle(bold: true);
      }
    }

    for (final b in s.blocks) {
      if (b is BTitle) {
        sh.appendRow([TextCellValue(b.text)]);
        bold(r, 1);
        r++;
      } else if (b is BHead || b is BSub) {
        sh.appendRow([TextCellValue(b is BHead ? b.text : (b as BSub).text)]);
        bold(r, 1);
        r++;
      } else if (b is BPara) {
        sh.appendRow([TextCellValue(b.text)]);
        if (b.bold) bold(r, 1);
        r++;
      } else if (b is BGap) {
        sh.appendRow([TextCellValue('')]);
        r++;
      } else if (b is BRow) {
        sh.appendRow([TextCellValue('${'    ' * b.indent}${b.label}'), b.value.isEmpty ? TextCellValue('') : _cv(b.value)]);
        if (b.bold) bold(r, 2);
        r++;
      } else if (b is BTable) {
        sh.appendRow([for (final h in b.headers) TextCellValue(h)]);
        bold(r, b.headers.length);
        r++;
        for (final row in b.data) {
          sh.appendRow([for (var i = 0; i < b.headers.length; i++) i == 0 ? TextCellValue(i < row.length ? row[i] : '') : _cv(i < row.length ? row[i] : '')]);
          r++;
        }
      }
    }
  }
  return ex.save() ?? <int>[];
}
