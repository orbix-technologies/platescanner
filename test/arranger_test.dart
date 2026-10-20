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
    expect(values(a), ['1', 'አማ', '01906', 'AM']);
    expect(a.layoutText, '1 አማ 01906 AM');
    expect(a.geezRegion.note, 'from AM');
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
    expect(values(r.arrangement), ['1', 'አአ', '0123456', 'AA']);
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
    expect(values(r.arrangement), ['1', 'አአ', '03189', 'AA']);
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
        word('0', left: 0.85, top: 0.15, bottom: 0.45, charWidth: 0.05),
        word('M', left: 0.85, top: 0.55, bottom: 0.85, charWidth: 0.05),
      ],
    ));
    expect(r.arrangement.latinRegion.value, 'OM');
    expect(r.candidate.region!.englishName, 'Oromia');
  });

  group('stacked region merged into the number (screenshot 3)', () {
    // OCR read "0123456" plus the stacked A/A as one tall "1" at the end.
    final merged = word('01234561', left: 0.3, top: 0.15, bottom: 0.85);
    final lastBox = merged.symbols.last.box;

    test('region pass on the last "digit" recovers A/A and the 0', () {
      final r = arranger.arrange(AreaOcr(
        codeHint: '1',
        elements: [merged],
        regionColumns: [
          RegionColumn(
            letters: 'AA',
            source: 'lastDigit',
            box: NormalizedRect(
                lastBox.left - 0.005, 0.15, lastBox.right + 0.005, 0.85),
            topHalf: NormalizedRect(lastBox.left, 0.15, lastBox.right, 0.5),
            bottomHalf: NormalizedRect(lastBox.left, 0.5, lastBox.right, 0.85),
          ),
        ],
      ));
      expect(values(r.arrangement), ['1', 'አአ', '0123456', 'AA']);
      expect(
        r.arrangement.latinRegion.chars.map((c) => c.text),
        ['A', 'A'],
      );
      expect(r.candidate.isValid, isTrue);
    });

    test('without the pass the number keeps its leading digits', () {
      final r = arranger.arrange(AreaOcr(codeHint: '1', elements: [merged]));
      expect(r.arrangement.number.value, '0123456');
    });

    test('letters from a real digit are ignored unless they name a region', () {
      final r = arranger.arrange(AreaOcr(
        codeHint: '1',
        elements: [word('0123458', left: 0.3, top: 0.15, bottom: 0.85)],
        regionColumns: [
          RegionColumn(
            letters: 'OO', // an "8" split into two O-like halves
            source: 'lastDigit',
            box: NormalizedRect(0.78, 0.15, 0.86, 0.85),
            topHalf: NormalizedRect(0.78, 0.15, 0.86, 0.5),
            bottomHalf: NormalizedRect(0.78, 0.5, 0.86, 0.85),
          ),
        ],
      ));
      expect(r.arrangement.number.value, '0123458');
      expect(r.arrangement.latinRegion.value, isEmpty);
    });

    test('a column whose letters name no region is rejected (GI)', () {
      final r = arranger.arrange(AreaOcr(
        codeHint: '1',
        elements: [word('0123456', left: 0.3, top: 0.15, bottom: 0.85)],
        regionColumns: const [
          RegionColumn(
            letters: 'GI',
            source: 'zone',
            box: NormalizedRect(0.9, 0.15, 0.99, 0.85),
            topHalf: NormalizedRect(0.9, 0.15, 0.99, 0.5),
            bottomHalf: NormalizedRect(0.9, 0.5, 0.99, 0.85),
          ),
        ],
      ));
      expect(r.arrangement.number.value, '0123456');
      expect(r.candidate.regionCode, isNull);
    });

    test('a column found right of the number is trusted', () {
      final r = arranger.arrange(AreaOcr(
        codeHint: '2',
        elements: [word('94529', left: 0.3, top: 0.15, bottom: 0.85)],
        regionColumns: const [
          RegionColumn(
            letters: 'AM',
            source: 'zone',
            box: NormalizedRect(0.8, 0.15, 0.9, 0.85),
            topHalf: NormalizedRect(0.8, 0.15, 0.9, 0.5),
            bottomHalf: NormalizedRect(0.8, 0.5, 0.9, 0.85),
          ),
        ],
      ));
      expect(values(r.arrangement), ['2', 'አማ', '94529', 'AM']);
    });
  });

  group('real captures (raw ML Kit output from the phone)', () {
    /// One element whose characters are spread evenly over its box.
    OcrElement line(String text, double left, double right) =>
        OcrElement(text: text, box: NormalizedRect(left, 0.2, right, 0.8));

    test('EBR off the screen: "D-01234561"', () {
      final r = arranger.arrange(AreaOcr(
        codeHint: '1',
        elements: [line('D-01234561', 0.05, 0.95)],
      ));
      // The '-' keeps the ring out; the merged stacked letters are cut.
      expect(r.arrangement.number.value, '0123456');
      expect(r.candidate.code, '1');
    });

    test('taxi: "o17717A:" — ring read as lowercase o', () {
      final r = arranger.arrange(AreaOcr(
        elements: [line('o17717A:', 0.05, 0.95)],
      ));
      expect(r.arrangement.number.value, '17717');
    });
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

  test("Ge'ez spelled from the Latin region, every region", () {
    const unread = PlateSection(
      kind: PlateSectionKind.geezRegion,
      value: PlateSection.geezPlaceholder,
      box: NormalizedRect(0.1, 0.2, 0.2, 0.8),
      detected: false,
    );
    const expected = {
      'ET': 'ኢት',
      'AA': 'አአ',
      'AF': 'አፋ',
      'AM': 'አማ',
      'BG': 'ቤጉ',
      'DR': 'ድሬ',
      'GM': 'ጋም',
      'HR': 'ሐረ',
      'OR': 'ኦሮ',
      'SM': 'ሶማ',
    };
    expected.forEach((latin, geez) {
      final s = arranger.geezFromLatin(unread, latin);
      expect(s.value, geez, reason: latin);
      expect(s.chars.length, 2);
      // Top letter in the top half of the stack.
      expect(s.chars.first.box.bottom, closeTo(0.5, 1e-9));
      expect(s.note, 'from $latin');
    });
    // Not a region (diplomatic) or nothing read: stays unread.
    expect(arranger.geezFromLatin(unread, 'CD').value, 'XX');
    expect(arranger.geezFromLatin(unread, '').value, 'XX');
  });
}
