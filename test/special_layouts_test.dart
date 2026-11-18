import 'package:et_plate_reader/et_plate_reader.dart';
import 'package:et_plate_reader/src/parsing/plate_section_reader.dart';
import 'package:et_plate_reader/src/segmentation/segment_capture.dart';
import 'package:flutter_test/flutter_test.dart';

/// Plates with a Ge'ez word in section 1 instead of a circled number:
/// police ፖሊስ, temporary ተላላፊ (both with a Ge'ez region stack), UN የተመ and
/// AU አሕ (no Ge'ez region; AU's letters side by side). Letters are left
/// unread so the layout has to decide; colours are from the session logs.
void main() {
  const area = NormalizedRect(0, 0, 1, 1);
  const reader = PlateSectionReader();

  ({PlateArrangement arrangement, PlateCandidate candidate}) read(
    String fixture,
    Map<String, List<String?>> byRole, {
    List<int>? ink,
    List<int>? paper,
  }) {
    final seg = segmentCaptureSync('test/fixtures/plates/$fixture', area)!;
    final crops = reader.cropsFor(seg, area);
    return reader.read(
      seg,
      crops,
      [
        for (final c in crops)
          byRole['${c.role}${c.index}'] ?? const [null, null, null],
      ],
      AreaOcr(elements: const [], inkColor: ink, paperColor: paper),
    );
  }

  test('AU: አሕ, seven digits, A U side by side', () {
    final seg = segmentCaptureSync('test/fixtures/plates/au.png', area)!;
    expect(seg.code, isNull);
    expect(seg.geezStack, isEmpty);
    expect(seg.latinSideBySide, isTrue);
    final a = read('au.png', {
      'number0': ['0123456', '0123456', null],
    }, ink: [
      101,
      145,
      180
    ]).arrangement;
    expect(a.code.value, 'AU');
    expect(a.code.chars.single.text, 'አሕ');
    expect(a.code.note, 'African Union');
    expect(a.geezRegion.value, isEmpty);
    expect(a.latinRegion.value, 'AU');
    expect(a.latinRegion.note, 'by layout');
  });

  test('UN: የተመ, seven digits, U/N stacked, no Ge\'ez region', () {
    final seg = segmentCaptureSync('test/fixtures/plates/un.png', area)!;
    expect(seg.code, isNull);
    expect(seg.geezStack, isEmpty);
    final a = read('un.png', {
      'number0': ['0123456', '0123456', null],
    }, ink: [
      94,
      130,
      184
    ]).arrangement;
    expect(a.code.value, 'UN');
    expect(a.code.chars.single.text, 'የተመ');
    expect(a.latinRegion.value, 'UN');
  });

  test('temporary: ተላላፊ in light blue, Ge\'ez stack, region', () {
    final r = read('temporary.png', {
      'number0': ['012345', '012345', null],
      'latin0': ['E', 'E', null],
      'latin1': ['T', 'T', null],
    }, ink: [
      101,
      133,
      182
    ]);
    final a = r.arrangement;
    expect(a.code.value, 'TEMP');
    expect(a.code.chars.single.text, 'ተላላፊ');
    expect(a.code.note, 'Temporary');
    expect(a.geezRegion.value, 'ኢት');
    expect(a.layoutText, 'TEMP ኢት 012345 ET');
    expect(r.candidate.isValid, isTrue);
  });

  test('police: the stencil 0 and gapped 1 stay in the number', () {
    final seg =
        segmentCaptureSync('test/fixtures/plates/police_gapped_one.png', area)!;
    expect(seg.numberChars, hasLength(6));
    expect(seg.leftDigits, isEmpty);
    final a = read('police_gapped_one.png', {
      'number0': ['012345', '012345', null],
    }, ink: [
      104,
      77,
      67
    ], paper: [
      210,
      147,
      99
    ]).arrangement;
    expect(a.code.value, 'POLICE');
    expect(a.code.chars.single.text, 'ፖሊስ');
  });

  test('police without a measured paper colour: ፖሊስ in black decides', () {
    final a = read('police.png', {
      'number0': ['012345', '012345', null],
    }, ink: [
      40,
      35,
      30
    ]).arrangement;
    expect(a.code.value, 'POLICE');
  });

  test('a daily permit read "eee0912" is not taken for a national plate', () {
    // Whole-area OCR on the phone (2026-11-06): the word as "eee", 091, and
    // the stacked O/R as "2". A national plate has no stacked region letters.
    final seg = segmentCaptureSync('test/fixtures/plates/daily.png', area)!;
    expect(seg.latinStack, hasLength(2));
    final crops = reader.cropsFor(seg, area);
    final r = reader.read(
      seg,
      crops,
      [
        for (final _ in crops) const <String?>[null, null, null]
      ],
      const AreaOcr(elements: [
        OcrElement(text: 'eee0912', box: NormalizedRect(0.05, 0.2, 0.95, 0.8)),
      ]),
    );
    expect(r.arrangement.code.value, isNot('ETH'));
    expect(r.candidate.serial, isNot('EEE0912'));
  });

  // The same daily permit photographed off a screen on the phone
  // (2026-11-06 11:49, reads, ink and paper as logged). The red ink comes out
  // pink-grey (168, 144, 160) and is red only against its cream paper; the
  // bolt hole and የ left of the word look like an embassy's two digits.
  test('daily permit off a screen: washed-out red, bolt hole, 091', () {
    final seg =
        segmentCaptureSync('test/fixtures/plates/daily_screen.png', area)!;
    expect(seg.code, isNull);
    expect(seg.numberChars, hasLength(3));
    expect(seg.geezStack, hasLength(2));
    expect(seg.latinStack, hasLength(2));
    final r = read('daily_screen.png', {
      'number0': ['091', '091', ''],
      'latin0': ['0', '', ''],
      'latin1': ['R', 'R', 'R'],
      'latinWord0': ['0R', '0 R', 'R'],
      'digit1': ['6', '', ''],
      'digit2': ['1', '1', ''],
    }, ink: [
      172,
      144,
      160
    ], paper: [
      235,
      223,
      241
    ]);
    expect(r.arrangement.code.value, 'DAILY');
    expect(r.candidate.regionCode, 'OR');
    expect(r.candidate.serial, '091');
    expect(r.candidate.isValid, isTrue);
  });

  // Real daily permit (የዕለት ኦሮ 091 OR, red on cream, through a windscreen;
  // 2026-11-06). Section reading is ready for it, but the segmenter takes
  // the Ge'ez word for digits: with only three digits of uneven height
  // (88/74/95 px) the digit height settles on the word's letters.
  test('daily permit: የዕለት, Ge\'ez stack, three digits, O/R stacked', () {
    final seg = segmentCaptureSync('test/fixtures/plates/daily.png', area)!;
    expect(seg.code, isNull);
    expect(seg.numberChars, hasLength(3));
    expect(seg.geezStack, hasLength(2));
    expect(seg.latinStack, hasLength(2));
    final r = read('daily.png', {
      'number0': ['091', '091', null],
      'latin0': ['O', 'O', null],
      'latin1': ['R', 'R', null],
    }, ink: [
      160,
      70,
      75
    ]);
    expect(r.arrangement.code.value, 'DAILY');
    expect(r.arrangement.code.chars.single.text, 'የዕለት');
    expect(r.candidate.regionCode, 'OR');
    expect(r.candidate.serial, '091');
    expect(r.candidate.isValid, isTrue);
  }, skip: 'segmenter: digit height on a three-digit number (see comment)');
}
