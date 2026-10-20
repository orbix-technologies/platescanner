import 'package:et_plate_reader/et_plate_reader.dart';
import 'package:et_plate_reader/src/parsing/plate_section_reader.dart';
import 'package:et_plate_reader/src/segmentation/segment_capture.dart';
import 'package:flutter_test/flutter_test.dart';

/// The new national plate (Directive 1050/2025, from June 2026): ኢት / ETH /
/// QR on the left, then three letters and four digits; no circle, no
/// region. Fixture from the published photo of an "AAA0000" plate.
void main() {
  const area = NormalizedRect(0, 0, 1, 1);
  const reader = PlateSectionReader();
  final seg =
      segmentCaptureSync('test/fixtures/plates/national_new.png', area)!;
  final crops = reader.cropsFor(seg, area);

  ({PlateArrangement arrangement, PlateCandidate candidate}) read(
          List<String?> numberReads) =>
      reader.read(
        seg,
        crops,
        [
          for (final c in crops)
            c.role == 'number' ? numberReads : const [null, null, null],
        ],
        const AreaOcr(elements: []),
      );

  test('layout: seven characters, no circle, no region letters', () {
    expect(seg.numberChars, hasLength(7));
    expect(seg.code, isNull);
    expect(seg.latinStack, isEmpty);
  });

  test('three letters and four digits, misreads mapped per part', () {
    // O read for 0 in the digits, 4 read for A in the letters.
    final r = read(['AAA0000', 'AAAOOOO', '4AA0000']);
    final a = r.arrangement;
    expect(a.number.value, 'AAA0000');
    expect(a.code.value, 'ETH');
    expect(a.code.chars.single.text, 'ኢት');
    expect(a.code.box, isNotNull);
    expect(a.geezRegion.value, isEmpty);
    expect(a.latinRegion.value, isEmpty);
    expect(a.latinRegion.note, 'none on ETH plates');
    expect([r.candidate.code, r.candidate.serial], ['ETH', 'AAA0000']);
    // No region on these plates: not an issue.
    expect(r.candidate.isValid, isTrue);
  });

  test('an all-digit read is never taken for the new format', () {
    final r = read(['0123456', '0123456', null]);
    expect(r.arrangement.code.value, isNot('ETH'));
    expect(r.arrangement.number.value, '0123456');
  });

  test('validation accepts ABC1234 only on ETH plates', () {
    const parser = EthiopianPlateParser();
    expect(parser.validate(code: 'ETH', serial: 'ABC1234'), isEmpty);
    expect(parser.validate(code: '2', regionCode: 'AA', serial: 'ABC1234'),
        contains(PlateIssue.missingSerial));
  });

  group('from the whole-area OCR (session logs)', () {
    const arranger = PlateArranger();
    AreaOcr ocr(List<String> texts) => AreaOcr(elements: [
          for (var i = 0; i < texts.length; i++)
            OcrElement(
              text: texts[i],
              box: NormalizedRect(0.25, 0.1 + i * 0.3, 0.95, 0.3 + i * 0.3),
            ),
        ]);

    test('the notched 0 read as G / O', () {
      for (final t in ['AAAGO00', 'AAAG000', 'AAAGGGO']) {
        final r = arranger.arrange(ocr(['ETH', t]));
        expect(r.arrangement.layoutText, 'ETH – AAA0000 –', reason: t);
        expect(r.arrangement.code.chars.single.text, 'ኢት');
        expect(r.candidate.isValid, isTrue);
      }
    });

    test('an old C06703 misread is not a national number', () {
      // Both read on old plates that carry a small "ETH" too.
      for (final t in ['CO67038', 'oCO670:']) {
        expect(arranger.nationalFromOcr(ocr(['ETH', t])), isNull, reason: t);
      }
    });
  });
}
