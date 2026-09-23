// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:typed_data';

/// Locally generated, controlled Type3 glyphs with exact rectangles and an
/// explicit ToUnicode map. No external document/font input or OCR is involved.
Uint8List extractionFixture({
  int rotation = 0,
  String text = 'AB',
  bool scanned = false,
  bool negativeOrigin = false,
  List<String> links = const [],
  String? toUnicode,
}) {
  String stream(String data) =>
      '<< /Length ${utf8.encode(data).length} >>\nstream\n$data\nendstream';
  final cmap =
      toUnicode ??
      '''/CIDInit /ProcSet findresource begin
12 dict begin begincmap
/CIDSystemInfo << /Registry (ALNOTE) /Ordering (Test) /Supplement 0 >> def
/CMapName /ALNOTETest def /CMapType 2 def
1 begincodespacerange <00> <FF> endcodespacerange
2 beginbfchar <41> <03A9> <42> <D83DDE00> endbfchar
endcmap CMapName currentdict /CMap defineresource pop end end''';
  final x = negativeOrigin ? -30 : 30;
  final y = negativeOrigin ? -10 : 50;
  final crop = negativeOrigin ? '-40 -20 10 40' : '20 40 70 100';
  final media = negativeOrigin ? '-60 -60 40 60' : '0 0 100 120';
  final content = scanned
      ? 'q 20 0 0 14 $x $y cm /Im1 Do Q'
      : 'BT /F1 20 Tf $x $y Td ($text) Tj ET';
  final objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [$media] /CropBox [$crop] /Rotate $rotation /Resources << /Font << /F1 5 0 R >> /XObject << /Im1 9 0 R >> >> /Contents 6 0 R /Annots [${List.generate(links.length, (i) => '${10 + i} 0 R').join(' ')}] >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 120] /Resources << >> >>',
    '<< /Type /Font /Subtype /Type3 /Name /F1 /FontBBox [0 0 500 700] /FontMatrix [.001 0 0 .001 0 0] /CharProcs << /A 7 0 R /B 7 0 R >> /Encoding << /Type /Encoding /Differences [65 /A /B] >> /FirstChar 65 /LastChar 66 /Widths [500 500] /Resources << >> /ToUnicode 8 0 R >>',
    stream(content),
    stream('500 0 0 0 500 700 d1 0 0 500 700 re f'),
    stream(cmap),
    '<< /Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /ASCIIHexDecode /Length 3 >>\nstream\n00>\nendstream',
    for (final action in links)
      '<< /Type /Annot /Subtype /Link /Rect [30 50 40 64] $action >>',
  ];
  final bytes = BytesBuilder()..add(ascii.encode('%PDF-1.7\n'));
  final offsets = <int>[0];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(bytes.length);
    bytes.add(utf8.encode('${i + 1} 0 obj\n${objects[i]}\nendobj\n'));
  }
  final xref = bytes.length;
  bytes.add(
    ascii.encode('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n'),
  );
  for (final offset in offsets.skip(1)) {
    bytes.add(ascii.encode('${offset.toString().padLeft(10, '0')} 00000 n \n'));
  }
  bytes.add(
    ascii.encode(
      'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n',
    ),
  );
  return bytes.takeBytes();
}
