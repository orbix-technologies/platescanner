import 'package:et_plate_reader/et_plate_reader.dart';
import 'package:flutter_test/flutter_test.dart';

/// Element with per-character boxes laid out left to right from [left].
OcrElement word(
  String text, {
  required double left,
  required double top,
  required double bottom,
  double charWidth = 0.08,
  double gap = 0.005,
  double confidence = 0.9,
}) {
  final symbols = <OcrSymbol>[];
  var x = left;
  for (final ch in text.split('')) {
    symbols.add(OcrSymbol(
      text: ch,
      box: NormalizedRect(x, top, x + charWidth, bottom),
    ));
    x += charWidth + gap;
  }
  return OcrElement(
    text: text,
    box: NormalizedRect(left, top, x - gap, bottom),
    confidence: confidence,
    symbols: symbols,
  );
}

void main() {
  const arranger = PlateArranger();

  test('new-format plate: ring as D, code from the disc pass, stacked A/A', () {
    final r = arranger.arrange(AreaOcr(
      codeHint: '1',
      elements: [
        word('D', left: 0.02, top: 0.3, bottom: 0.7),
        word('0123456', left: 0.25, top: 0.2, bottom: 0.8),
        word('A', left: 0.92, top: 0.15, bottom: 0.45, charWidth: 0.05),
        word('A', left: 0.92, top: 0.55, bottom: 0.85, charWidth: 0.05),
      ],
    ));
    final c = r.candidate;
    expect([c.code, c.regionCode, c.serial], ['1', 'AA', '0123456']);
    expect(c.isValid, isTrue);
    expect(r.arrangement.layoutText, '1 0123456 A/A');

    final cols = r.arrangement.columns;
    expect(cols, hasLength(3));
    expect(cols.last.map((s) => s.text), ['A', 'A']);
    expect(cols.last.map((s) => s.row), [0, 1]);
    expect(cols.last.every((s) => s.role == PlateSegmentRole.region), isTrue);
  });

  test("Ge'ez is ignored; region comes from the Latin letters", () {
    final r = arranger.arrange(AreaOcr(
      codeHint: '1',
      elements: [
        word('አ', left: 0.12, top: 0.15, bottom: 0.45, charWidth: 0.05),
        word('አ', left: 0.12, top: 0.55, bottom: 0.85, charWidth: 0.05),
        word('0123456', left: 0.25, top: 0.2, bottom: 0.8),
        word('T', left: 0.92, top: 0.15, bottom: 0.45, charWidth: 0.05),
        word('G', left: 0.92, top: 0.55, bottom: 0.85, charWidth: 0.05),
      ],
    ));
    expect(r.candidate.regionCode, 'TG');
    expect(r.arrangement.segments.any((s) => s.text.contains('አ')), isFalse);
  });

  test('OM maps to Oromia', () {
    final r = arranger.arrange(AreaOcr(
      elements: [
        word('3', left: 0.02, top: 0.3, bottom: 0.7),
        word('OM', left: 0.12, top: 0.3, bottom: 0.7),
        word('654321', left: 0.35, top: 0.2, bottom: 0.8),
      ],
    ));
    expect([r.candidate.code, r.candidate.regionCode], ['3', 'OR']);
    expect(r.candidate.region!.englishName, 'Oromia');
  });

  test('older single-row plate: code, region, lettered serial', () {
    final r = arranger.arrange(AreaOcr(
      elements: [
        word('2', left: 0.02, top: 0.3, bottom: 0.7),
        word('AA', left: 0.12, top: 0.3, bottom: 0.7),
        word('A', left: 0.35, top: 0.2, bottom: 0.8),
        word('12345', left: 0.45, top: 0.2, bottom: 0.8),
      ],
    ));
    final c = r.candidate;
    expect([c.code, c.regionCode, c.serial], ['2', 'AA', 'A12345']);
    expect(c.layout, PlateLayout.singleRow);
  });

  test('older two-row plate: code + region above the serial', () {
    final r = arranger.arrange(AreaOcr(
      elements: [
        word('2', left: 0.2, top: 0.05, bottom: 0.4),
        word('DR', left: 0.5, top: 0.05, bottom: 0.4),
        word('67890', left: 0.2, top: 0.5, bottom: 0.95),
      ],
    ));
    final c = r.candidate;
    expect([c.code, c.regionCode, c.serial], ['2', 'DR', '67890']);
    expect(c.layout, PlateLayout.twoRow);
  });

  test('characters split by spacing inside one element', () {
    // ML Kit element "2 AA 12345" with per-char boxes and gaps.
    const syms = [
      ('2', 0.02), ('A', 0.15), ('A', 0.21), //
      ('1', 0.35), ('2', 0.41), ('3', 0.47), ('4', 0.53), ('5', 0.59),
    ];
    final r = arranger.arrange(AreaOcr(elements: [
      OcrElement(
        text: '2 AA 12345',
        box: const NormalizedRect(0.02, 0.2, 0.65, 0.8),
        symbols: [
          for (final (t, x) in syms)
            OcrSymbol(text: t, box: NormalizedRect(x, 0.2, x + 0.055, 0.8)),
        ],
      ),
    ]));
    expect(r.arrangement.layoutText, '2 AA 12345');
    expect(r.candidate.isValid, isTrue);
  });

  test('real plate 2·AA·94529: edge security number and ETH marks ignored', () {
    // Vertical security number on the left edge, read as one element whose
    // characters are stacked (tall box, small glyphs).
    final security = OcrElement(
      text: '0752645',
      box: const NormalizedRect(0.025, 0.25, 0.04, 0.75),
      symbols: [
        for (var i = 0; i < 7; i++)
          OcrSymbol(
            text: '0752645'[i],
            box: NormalizedRect(0.025, 0.25 + i * 0.07, 0.04, 0.31 + i * 0.07),
          ),
      ],
    );
    final r = arranger.arrange(AreaOcr(
      elements: [
        word('ETH', left: 0.03, top: 0.08, bottom: 0.14, charWidth: 0.01),
        security,
        word('2', left: 0.07, top: 0.38, bottom: 0.6, charWidth: 0.05),
        word('ከ', left: 0.2, top: 0.1, bottom: 0.4, charWidth: 0.04),
        word('ከ', left: 0.2, top: 0.55, bottom: 0.85, charWidth: 0.04),
        word('94529', left: 0.37, top: 0.15, bottom: 0.85, charWidth: 0.09),
        word('A', left: 0.89, top: 0.12, bottom: 0.45, charWidth: 0.05),
        word('A', left: 0.89, top: 0.55, bottom: 0.88, charWidth: 0.05),
        word('ETH', left: 0.93, top: 0.08, bottom: 0.14, charWidth: 0.01),
      ],
    ));
    final c = r.candidate;
    expect([c.code, c.regionCode, c.serial], ['2', 'AA', '94529']);
    expect(c.isValid, isTrue);
    expect(r.arrangement.layoutText, '2 94529 A/A');
  });

  test('real plate 1·AA·03189: circled digit read as ①', () {
    final r = arranger.arrange(AreaOcr(
      elements: [
        word('①', left: 0.03, top: 0.35, bottom: 0.6, charWidth: 0.06),
        word('03189', left: 0.3, top: 0.15, bottom: 0.85, charWidth: 0.1),
        word('A', left: 0.88, top: 0.12, bottom: 0.45, charWidth: 0.05),
        word('A', left: 0.88, top: 0.55, bottom: 0.88, charWidth: 0.05),
      ],
    ));
    expect(
      [r.candidate.code, r.candidate.regionCode, r.candidate.serial],
      ['1', 'AA', '03189'],
    );
  });

  test('missing code is reported, not invented', () {
    final r = arranger.arrange(AreaOcr(
      elements: [
        word('D', left: 0.02, top: 0.3, bottom: 0.7),
        word('0123456', left: 0.25, top: 0.2, bottom: 0.8),
      ],
    ));
    expect(r.candidate.code, isNull);
    expect(r.candidate.issues, contains(PlateIssue.missingCode));
  });
}
