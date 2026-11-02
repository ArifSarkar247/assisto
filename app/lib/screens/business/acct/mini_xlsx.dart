// acctui — a tiny pure-Dart .xlsx (Office Open XML spreadsheet) writer for
// the accountant export. No package: the pubspec has no Excel library, and
// an .xlsx is only a ZIP of a few XML files. Cells are inline strings or
// numbers; three styles (number "#,##0.00", bold text, bold number). The ZIP
// uses raw DEFLATE (dart:io) with a CRC-32 per file. Opens in Excel, Google
// Sheets, LibreOffice and WPS (the accountant's usual tools).
import 'dart:convert';
import 'dart:io' show ZLibEncoder;
import 'dart:typed_data';

class XlsxCell {
  final Object? value; // String | num | null
  final bool bold;
  const XlsxCell(this.value, {this.bold = false});
}

class XlsxSheet {
  final String name;
  final List<List<XlsxCell?>> rows;
  final List<double> widths; // column widths in characters
  const XlsxSheet(this.name, this.rows, {this.widths = const []});
}

/// A safe, unique sheet name (Excel: ≤ 31 chars, none of []:*?/\).
String xlsxSheetName(String raw, Set<String> used) {
  var s = raw.replaceAll(RegExp(r'[\[\]:*?/\\]'), ' ').trim();
  if (s.isEmpty) s = 'Sheet';
  if (s.length > 28) s = s.substring(0, 28);
  var out = s;
  var i = 2;
  while (used.contains(out.toLowerCase())) {
    out = '$s ${i++}';
  }
  used.add(out.toLowerCase());
  return out;
}

String _esc(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    // XML 1.0 forbids most control characters
    .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '');

String xlsxColumn(int i) {
  var n = i + 1;
  var s = '';
  while (n > 0) {
    final r = (n - 1) % 26;
    s = String.fromCharCode(65 + r) + s;
    n = (n - 1) ~/ 26;
  }
  return s;
}

String _sheetXml(XlsxSheet sh) {
  final b = StringBuffer()
    ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
    ..write('<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">');
  if (sh.widths.isNotEmpty) {
    b.write('<cols>');
    for (var i = 0; i < sh.widths.length; i++) {
      b.write('<col min="${i + 1}" max="${i + 1}" width="${sh.widths[i]}" customWidth="1"/>');
    }
    b.write('</cols>');
  }
  b.write('<sheetData>');
  for (var r = 0; r < sh.rows.length; r++) {
    b.write('<row r="${r + 1}">');
    final row = sh.rows[r];
    for (var c = 0; c < row.length; c++) {
      final cell = row[c];
      if (cell == null || cell.value == null) continue;
      final ref = '${xlsxColumn(c)}${r + 1}';
      final v = cell.value;
      if (v is num) {
        final s = cell.bold ? 3 : 1;
        b.write('<c r="$ref" s="$s"><v>${v.isFinite ? v : 0}</v></c>');
      } else {
        final s = cell.bold ? ' s="2"' : '';
        b.write('<c r="$ref" t="inlineStr"$s><is><t xml:space="preserve">${_esc('$v')}</t></is></c>');
      }
    }
    b.write('</row>');
  }
  b.write('</sheetData></worksheet>');
  return b.toString();
}

const _styles = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
    '<numFmts count="1"><numFmt numFmtId="164" formatCode="#,##0.00"/></numFmts>'
    '<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font>'
    '<font><b/><sz val="11"/><name val="Calibri"/></font></fonts>'
    '<fills count="2"><fill><patternFill patternType="none"/></fill>'
    '<fill><patternFill patternType="gray125"/></fill></fills>'
    '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>'
    '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
    '<cellXfs count="4">'
    '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>'
    '<xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>'
    '<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>'
    '<xf numFmtId="164" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1" applyNumberFormat="1"/>'
    '</cellXfs>'
    '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>'
    '</styleSheet>';

/// The .xlsx bytes for [sheets] (at least one).
Uint8List buildXlsx(List<XlsxSheet> sheets) {
  final used = <String>{};
  final names = [for (final s in sheets) xlsxSheetName(s.name, used)];
  final files = <String, String>{
    '[Content_Types].xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
        '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
        '${[
          for (var i = 0; i < sheets.length; i++)
            '<Override PartName="/xl/worksheets/sheet${i + 1}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
        ].join()}'
        '</Types>',
    '_rels/.rels': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
        '</Relationships>',
    'xl/workbook.xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>'
        '${[
          for (var i = 0; i < sheets.length; i++)
            '<sheet name="${_esc(names[i])}" sheetId="${i + 1}" r:id="rId${i + 1}"/>'
        ].join()}'
        '</sheets></workbook>',
    'xl/_rels/workbook.xml.rels': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '${[
          for (var i = 0; i < sheets.length; i++)
            '<Relationship Id="rId${i + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet${i + 1}.xml"/>'
        ].join()}'
        '<Relationship Id="rId${sheets.length + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
        '</Relationships>',
    'xl/styles.xml': _styles,
    for (var i = 0; i < sheets.length; i++) 'xl/worksheets/sheet${i + 1}.xml': _sheetXml(sheets[i]),
  };
  return zipFiles({for (final e in files.entries) e.key: utf8.encode(e.value)});
}

// ---------------------------------------------------------------- zip
final List<int> _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int crc32(List<int> data) {
  var c = 0xFFFFFFFF;
  for (final b in data) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

/// A ZIP archive (DEFLATE) of [files] — name -> bytes.
Uint8List zipFiles(Map<String, List<int>> files) {
  final out = BytesBuilder(copy: false);
  final central = BytesBuilder(copy: false);
  var offset = 0;
  void u16(BytesBuilder b, int v) => b.add([v & 0xFF, (v >> 8) & 0xFF]);
  void u32(BytesBuilder b, int v) =>
      b.add([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);
  for (final e in files.entries) {
    final name = utf8.encode(e.key);
    final raw = e.value;
    final crc = crc32(raw);
    final data = ZLibEncoder(raw: true, level: 6).convert(raw);
    final h = BytesBuilder(copy: false);
    u32(h, 0x04034b50);
    u16(h, 20); // version needed
    u16(h, 0x0800); // UTF-8 names
    u16(h, 8); // deflate
    u16(h, 0); // time
    u16(h, 0x21); // date 1980-01-01
    u32(h, crc);
    u32(h, data.length);
    u32(h, raw.length);
    u16(h, name.length);
    u16(h, 0);
    h.add(name);
    final header = h.takeBytes();
    out.add(header);
    out.add(data);
    u32(central, 0x02014b50);
    u16(central, 20);
    u16(central, 20);
    u16(central, 0x0800);
    u16(central, 8);
    u16(central, 0);
    u16(central, 0x21);
    u32(central, crc);
    u32(central, data.length);
    u32(central, raw.length);
    u16(central, name.length);
    u16(central, 0); // extra
    u16(central, 0); // comment
    u16(central, 0); // disk
    u16(central, 0); // internal attrs
    u32(central, 0); // external attrs
    u32(central, offset);
    central.add(name);
    offset += header.length + data.length;
  }
  final cd = central.takeBytes();
  out.add(cd);
  final end = BytesBuilder(copy: false);
  u32(end, 0x06054b50);
  u16(end, 0);
  u16(end, 0);
  u16(end, files.length);
  u16(end, files.length);
  u32(end, cd.length);
  u32(end, offset);
  u16(end, 0);
  out.add(end.takeBytes());
  return out.takeBytes();
}
