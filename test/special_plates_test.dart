import 'package:et_plate_reader/et_plate_reader.dart';
import 'package:flutter_test/flutter_test.dart';

import 'arranger_test.dart' show word;

/// Plates from the metaappz sample sheet scanned on a phone.
void main() {
  const arranger = PlateArranger();

  RegionColumn column(String letters, double left, double right,
          {String source = 'zone'}) =>
      RegionColumn(
        letters: letters,
        source: source,
        box: NormalizedRect(left, 0.15, right, 0.85),
        topHalf: NormalizedRect(left, 0.15, right, 0.5),
        bottomHalf: NormalizedRect(left, 0.5, right, 0.85),
      );

  test('UN plate: የተመ 0123456 U/N', () {
    final r = arranger.arrange(AreaOcr(
      elements: [word('0123456', left: 0.3, top: 0.15, bottom: 0.85)],
      regionColumns: [column('UN', 0.9, 0.97)],
      inkColor: const [60, 140, 210], // light blue would say "2"
    ));
    expect(r.arrangement.code.value, 'UN');
    expect(r.arrangement.latinRegion.value, 'UN');
    expect(r.candidate.isValid, isTrue);
  });

  test('AU plate: letters side by side', () {
    final r = arranger.arrange(AreaOcr(
      elements: [
        word('0123456', left: 0.25, top: 0.15, bottom: 0.85),
        word('AU', left: 0.86, top: 0.3, bottom: 0.65, charWidth: 0.05),
      ],
    ));
    expect(r.arrangement.code.value, 'AU');
  });

  test('diplomatic plate: 06 ·Ge\'ez· 0123 C/D, merged C/D read as "5"', () {
    final r = arranger.arrange(AreaOcr(
      elements: [
        word('06', left: 0.03, top: 0.15, bottom: 0.85, charWidth: 0.09),
        word('01235', left: 0.4, top: 0.15, bottom: 0.85, charWidth: 0.1),
      ],
      regionColumns: [column('CD', 0.815, 0.925, source: 'lastDigit')],
      inkColor: const [40, 40, 45],
    ));
    final a = r.arrangement;
    expect(a.number.value, '0123');
    expect(a.code.value, 'CD');
    expect(a.code.note, 'embassy 06 · Turkey');
    expect(r.candidate.isValid, isTrue);
  });

  test('police plate: yellow background, no circle', () {
    final r = arranger.arrange(AreaOcr(
      elements: [word('012345', left: 0.35, top: 0.15, bottom: 0.85)],
      regionColumns: [column('AA', 0.92, 0.98)],
      inkColor: const [77, 46, 32], // dark brown would say "5"
      paperColor: const [235, 160, 40],
    ));
    expect(r.arrangement.code.value, 'POLICE');
    expect(r.arrangement.code.note, 'Police');
    expect(r.arrangement.number.value, '012345');
    expect(r.candidate.regionCode, 'AA');
    expect(r.candidate.isValid, isTrue);
  });

  group('code: circle vote vs ink colour', () {
    final number = word('0123456', left: 0.3, top: 0.15, bottom: 0.85);

    test('strong circle vote keeps ⑤ on a plate photographed red', () {
      final r = arranger.arrange(AreaOcr(
        elements: [number],
        codeHint: '5',
        codeVotes: 4,
        inkColor: const [180, 93, 100],
      ));
      expect(r.arrangement.code.value, '5');
      expect(r.arrangement.code.note, isNull);
    });

    test('red and orange never override each other', () {
      final r = arranger.arrange(AreaOcr(
        elements: [number],
        codeHint: '5',
        codeVotes: 1,
        inkColor: const [200, 40, 40],
      ));
      expect(r.arrangement.code.value, '5');
    });

    test('a weak circle read loses to a clear, different colour', () {
      final r = arranger.arrange(AreaOcr(
        elements: [number],
        codeHint: '3',
        codeVotes: 1,
        inkColor: const [50, 54, 123],
      ));
      expect(r.arrangement.code.value, '2');
      expect(r.arrangement.code.note, 'by colour (circle read 3)');
    });
  });

  test('yellow detection', () {
    expect(PaperColor.isYellow(235, 160, 40), isTrue); // amber
    expect(PaperColor.isYellow(240, 250, 40), isTrue); // lemon
    expect(PaperColor.isYellow(235, 235, 240), isFalse); // white plate
    expect(PaperColor.isYellow(200, 60, 60), isFalse); // red
  });
}
