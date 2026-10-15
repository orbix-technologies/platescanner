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

/// Section values left to right.
List<String> values(PlateArrangement a) =>
    a.sections.map((s) => s.value).toList();

void main() {
  const arranger = PlateArranger();

  test('screenshot plate ① ·Ge\'ez· 01906 A/M: four sections', () {
    // As ML Kit read it: ring as "O", Ge'ez as Latin garbage, the number,
    // and the stacked A / M glued to the number's element.
    final r = arranger.arrange(AreaOcr(
      codeHint: '1',
      elements: [
        word('O', left: 0.03, top: 0.3, bottom: 0.62, charWidth: 0.06),
        word('H', left: 0.17, top: 0.12, bottom: 0.42, charWidth: 0.04),
        word('09', left: 0.17, top: 0.5, bottom: 0.82, charWidth: 0.03),
        OcrElement(
          text: '01906AM',
          box: const NormalizedRect(0.37, 0.12, 0.97, 0.88),
          symbols: [
            for (var i = 0; i < 5; i++)
              OcrSymbol(
                text: '01906'[i],
                box: NormalizedRect(0.37 + i * 0.1, 0.12, 0.45 + i * 0.1, 0.88),
              ),
            const OcrSymbol(
                text: 'A', box: NormalizedRect(0.9, 0.1, 0.95, 0.45)),
            const OcrSymbol(
                text: 'M', box: NormalizedRect(0.9, 0.55, 0.95, 0.88)),
          ],
        ),
      ],
    ));
    final a = r.arrangement;
    expect(values(a), ['1', 'XX', '01906', 'AM']);
    expect(a.layoutText, '1 XX 01906 AM');
    expect(a.geezRegion.detected, isFalse);
    expect(a.latinRegion.chars.map((c) => c.text), ['A', 'M']);
    expect(a.number.chars.map((c) => c.text).join(), '01906');

    final c = r.candidate;
    expect([c.code, c.regionCode, c.serial], ['1', 'AM', '01906']);
    expect(c.region!.englishName, 'Amhara');
    expect(c.isValid, isTrue);
  });

  test('EBR sample: ring as D, seven-digit number, A/A', () {
    final r = arranger.arrange(AreaOcr(
      codeHint: '1',
      elements: [
        word('D', left: 0.02, top: 0.3, bottom: 0.7, charWidth: 0.06),
        word('0123456', left: 0.25, top: 0.2, bottom: 0.8),
        word('A', left: 0.92, top: 0.15, bottom: 0.45, charWidth: 0.05),
        word('A', left: 0.92, top: 0.55, bottom: 0.85, charWidth: 0.05),
      ],
    ));
    expect(values(r.arrangement), ['1', 'XX', '0123456', 'AA']);
    expect(r.candidate.isValid, isTrue);
  });

  test('real plate ②·94529·A/A: security number and ETH marks ignored', () {
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
        word('ETH', left: 0.93, top: 0.04, bottom: 0.09, charWidth: 0.01),
      ],
    ));
    final a = r.arrangement;
    // Ge'ez read here (a recogniser that supports it), so it is shown.
    expect(values(a), ['2', 'ከከ', '94529', 'AA']);
    expect(a.geezRegion.detected, isTrue);
    expect(a.ignored.map((c) => c.text).join(), contains('0752645'));
    expect(r.candidate.isValid, isTrue);
  });

  test('circled digit ① read directly, 1·03189·A/A', () {
    final r = arranger.arrange(AreaOcr(
      elements: [
        word('①', left: 0.03, top: 0.35, bottom: 0.6, charWidth: 0.06),
        word('03189', left: 0.3, top: 0.15, bottom: 0.85, charWidth: 0.1),
        word('A', left: 0.88, top: 0.12, bottom: 0.45, charWidth: 0.05),
        word('A', left: 0.88, top: 0.55, bottom: 0.88, charWidth: 0.05),
      ],
    ));
    expect(values(r.arrangement), ['1', 'XX', '03189', 'AA']);
  });

  test("a single group next to the number is Ge'ez, not the code", () {
    final r = arranger.arrange(AreaOcr(
      elements: [
        word('H', left: 0.2, top: 0.15, bottom: 0.45, charWidth: 0.04),
        word('0123456', left: 0.28, top: 0.2, bottom: 0.8),
        word('T', left: 0.92, top: 0.15, bottom: 0.45, charWidth: 0.05),
        word('G', left: 0.92, top: 0.55, bottom: 0.85, charWidth: 0.05),
      ],
    ));
    final a = r.arrangement;
    expect(a.code.detected, isFalse);
    expect(a.geezRegion.box, isNotNull);
    expect(a.latinRegion.value, 'TG');
    expect(r.candidate.issues, [PlateIssue.missingCode]);
  });

  test('a digit misread inside the Latin region is mapped to a letter', () {
    final r = arranger.arrange(AreaOcr(
      codeHint: '3',
      elements: [
        word('654321', left: 0.3, top: 0.2, bottom: 0.8),
        word('0', left: 0.92, top: 0.15, bottom: 0.45, charWidth: 0.05),
        word('M', left: 0.92, top: 0.55, bottom: 0.85, charWidth: 0.05),
      ],
    ));
    expect(r.arrangement.latinRegion.value, 'OM');
    expect(r.candidate.region!.englishName, 'Oromia');
  });

  test('nothing number-like: every section empty, nothing invented', () {
    final r = arranger.arrange(AreaOcr(
      elements: [word('TOYOTA', left: 0.1, top: 0.3, bottom: 0.6)],
    ));
    final a = r.arrangement;
    expect(a.number.value, isEmpty);
    expect(a.code.detected, isFalse);
    expect(r.candidate.isValid, isFalse);
  });
}
