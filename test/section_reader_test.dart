import 'package:et_plate_reader/et_plate_reader.dart';
import 'package:et_plate_reader/src/parsing/plate_section_reader.dart';
import 'package:et_plate_reader/src/segmentation/segment_capture.dart';
import 'package:flutter_test/flutter_test.dart';

/// Screenshot 1: ④ ·Ge'ez· 0123456 · E/T, where whole-plate OCR read the
/// E/T stack as a "4" glued to the number ("01234564").
void main() {
  const area = NormalizedRect(0, 0, 1, 1);
  final seg = segmentCaptureSync('test/fixtures/plates/et.png', area)!;
  const reader = PlateSectionReader();
  final crops = reader.cropsFor(seg, area);

  List<List<String?>> reads(Map<String, List<String?>> byRole) => [
        for (final c in crops)
          byRole['${c.role}${c.index}'] ?? const [null, null, null],
      ];

  test('each section is read from its own crop', () {
    // Single digits are a second round only.
    expect(crops.where((c) => c.role == 'digit'), isEmpty);
    expect(reader.cropsFor(seg, area, digits: true), hasLength(7));
    expect(crops.where((c) => c.role == 'latin'), hasLength(2));
    expect(crops.where((c) => c.role == 'code'), hasLength(1));
    // The number crop ends before the E/T column starts.
    final number = crops.firstWhere((c) => c.role == 'number').inArea;
    expect(number.right, lessThan(seg.latinStack.first.left));
  });

  test('sections assembled: 4 · ኢት · 0123456 · ET', () {
    final r = reader.read(
      seg,
      crops,
      reads({
        'number0': ['0123456', '0123456', 'O123456'],
        for (var i = 0; i < 7; i++) 'digit$i': ['$i', '$i', null],
        'latin0': ['E', 'E', 'F'],
        'latin1': ['T', 'T', null],
        'code0': ['4', '4', 'A'],
      }),
      const AreaOcr(elements: []),
    );
    final a = r.arrangement;
    expect(a.layoutText, '4 ኢት 0123456 ET');
    expect(a.latinRegion.chars.map((c) => c.text), ['E', 'T']);
    // Section 2 is spelled from section 4, one letter per stacked box.
    expect(a.geezRegion.chars.map((c) => c.text), ['ኢ', 'ት']);
    expect(a.geezRegion.note, 'from ET');
    expect(r.candidate.region!.englishName, 'Federal');
    expect(r.candidate.isValid, isTrue);
  });

  test('three agreeing digit reads beat a lone line read', () {
    final all = [...crops, ...reader.cropsFor(seg, area, digits: true)];
    List<List<String?>> reads2(Map<String, List<String?>> byRole) => [
          for (final c in all)
            byRole['${c.role}${c.index}'] ?? const [null, null, null],
        ];
    final r = reader.read(
      seg,
      all,
      reads2({
        'number0': ['0123458', null, null],
        for (var i = 0; i < 7; i++) 'digit$i': ['$i', '$i', '$i'],
        'latin0': ['E', null, null],
        'latin1': ['T', null, null],
        'code0': ['4', '4', null],
      }),
      const AreaOcr(elements: []),
    );
    expect(r.arrangement.number.value, '0123456');
  });

  test('reads short of the segmented count do not outvote the full one', () {
    // As logged for C06703 (session 1794983758902): "CO67t3" and "Ci673"
    // lose characters ("0673", "1673") and agreed on length 4 against the
    // one full read; single digits mostly empty.
    final all = [...crops, ...reader.cropsFor(seg, area, digits: true)];
    final r = reader.read(
      seg,
      all,
      [
        for (final c in all)
          {
                'number0': ['0123456', '0I23t5', 'O1234'],
                'latin0': ['E', 'E', null],
                'latin1': ['T', 'T', null],
                'code0': ['4', '4', null],
              }['${c.role}${c.index}'] ??
              const [null, null, null],
      ],
      const AreaOcr(elements: []),
    );
    expect(r.arrangement.number.value, '0123456');
  });

  test('series letter kept when the region letter is glued on', () {
    // As logged for C06703 (session 1794984929605): "CU6703A" twice, the
    // trailing A from the A/A stack; read as 06703 before.
    final r = reader.read(
      seg,
      crops,
      reads({
        'number0': ['CU6703A', 'CU6703A', 'Ci6733A]'],
        'latin0': ['E', 'E', null],
        'latin1': ['T', 'T', null],
        'code0': ['4', '4', null],
      }),
      const AreaOcr(elements: []),
    );
    expect(r.arrangement.number.value, 'C06703');
  });

  test('split whole reads: single reads settle, blank singles are 0', () {
    // As logged for the two-row B00490 (session 37882): "BOG490" against
    // "D67009", each lone 0 read as nothing, the 9 read as 6 and 9.
    final all = [...crops, ...reader.cropsFor(seg, area, digits: true)];
    final r = reader.read(
      seg,
      all,
      [
        for (final c in all)
          switch ('${c.role}${c.index}') {
            'number0' => ['0100406', '0670096', ''],
            'digit1' => ['1', '', ''],
            'digit2' || 'digit5' => ['', '', ''],
            'digit4' => ['4', '9', ''],
            'latin0' || 'latin1' => ['A', 'A', ''],
            _ => const [null, null, null],
          },
      ],
      const AreaOcr(elements: []),
    );
    expect(r.arrangement.number.value, '0100406');
  });

  test('real reads: notched 0 read as G, single digits mostly empty', () {
    // Session 82594 / 54935: number reads and (empty) letter reads as logged.
    final r = reader.read(
      seg,
      crops,
      reads({
        'number0': ['G123456', '0123456', '23456'],
        'latin0': ['E', '', ''],
        'latin1': ['T', '', ''],
        'code0': ['', '4', '1'],
      }),
      const AreaOcr(elements: []),
    );
    expect(r.arrangement.number.value, '0123456');
    expect(r.arrangement.latinRegion.value, 'ET');
  });

  test('a digit read as a letter needs two reads (no "IA")', () {
    final r = reader.read(
      seg,
      crops,
      reads({
        'number0': ['0123456', '0123456', null],
        'latin0': ['', '', '1.'],
        'latin1': ['A', '', ''],
      }),
      const AreaOcr(elements: []),
    );
    expect(r.arrangement.latinRegion.value, isEmpty);
  });

  test('series letter before five digits is kept (real logs)', () {
    final r = reader.read(
      seg,
      crops,
      reads({
        'number0': ['CO6703', 'CO6703', 'CI6713'],
        'latin0': ['A', 'A', ''],
        'latin1': ['A', 'A', ''],
      }),
      const AreaOcr(elements: []),
    );
    expect(r.arrangement.number.value, 'C06703');
    expect(r.candidate.serial, 'C06703'); // series letter + five digits
  });

  test('lone letters empty (real logs): the side-by-side word fills them', () {
    final r = reader.read(
      seg,
      crops,
      reads({
        'number0': ['0123456', '0123456', '23456'],
        'latin0': ['E', 'E', ''],
        'latin1': ['', '', ''], // the T, as logged in 19206 / 26303
        'latinWord0': ['ET', 'ET', 'E T'],
        'code0': ['', '', ''], // the 4, as logged
        'codeRepeat0': ['444', '444', '44'],
      }),
      const AreaOcr(elements: []),
    );
    expect(r.arrangement.layoutText, '4 ኢት 0123456 ET');
  });

  group('region from one letter (session logs of 2026-11-19)', () {
    String? region(Map<String, List<String?>> letters) => reader
        .read(
          seg,
          crops,
          reads({
            'number0': ['0123456', '0123456', null],
            'code0': ['4', '4', null],
            ...letters,
          }),
          const AreaOcr(elements: []),
        )
        .candidate
        .regionCode;

    test('E above, T unread: only ET has E on top', () {
      expect(
          region({
            'latin0': ['E', 'E', null]
          }),
          'ET');
    });
    test('T below read twice, E read as J: ET', () {
      expect(
          region({
            'latin0': ['J', null, null],
            'latin1': [null, 'T', 'T'],
          }),
          'ET');
    });
    test('A below: only AA ends in A', () {
      expect(
          region({
            'latin1': ['A', 'A', null]
          }),
          'AA');
    });
    test('one pass alone does not decide', () {
      expect(
          region({
            'latin0': ['E', null, null],
            'latinRepeat0': ['E\nE\nE', null, null],
          }),
          isNull);
    });
    test('A above fits AA, AF and AM: undecided', () {
      expect(
          region({
            'latin0': ['A', 'A', 'A']
          }),
          isNull);
    });
  });

  group('letters drawn alike (SM-M166P logs of 2026-11-19)', () {
    String? region(double? match, Map<String, List<String?>> letters) => reader
        .read(
          seg.withStackMatch(match),
          crops,
          reads({
            'number0': ['0123456', '0123456', null],
            'code0': ['2', '2', null],
            ...letters,
          }),
          const AreaOcr(elements: []),
        )
        .candidate
        .regionCode;

    test('A on top, bottom unread, both alike: AA', () {
      expect(
          region(0.72, {
            'latin0': ['A', 'A', 'A']
          }),
          'AA');
    });
    test('bottom read as a letter no region has there: AA', () {
      expect(
          region(0.94, {
            'latin0': ['A', 'A', null],
            'latin1': ['V', 'V', null],
          }),
          'AA');
    });
    test('not alike: undecided', () {
      expect(
          region(0.3, {
            'latin0': ['A', 'A', 'A']
          }),
          isNull);
    });
    test('none read but clearly alike: AA', () {
      expect(region(0.87, {}), 'AA');
    });
    test('none read and only loosely alike: undecided', () {
      expect(region(0.55, {}), isNull);
    });
    test('a region letter read below blocks it (M: AM, SM or GM)', () {
      expect(
          region(0.9, {
            'latin1': ['M', 'M', null]
          }),
          isNull);
    });
  });

  group('4-ET-37617 (SM-A176B logs of 2026-11-23)', () {
    final stack = seg.latinStack.reduce((a, b) => a.union(b));
    AreaOcr line(String text) => AreaOcr(elements: [
          OcrElement(
            text: text,
            box: NormalizedRect(
                0, stack.top - 0.05, stack.right + 0.02, stack.bottom + 0.05),
          ),
        ]);
    ({PlateArrangement arrangement, PlateCandidate candidate}) read(
            Map<String, List<String?>> r, AreaOcr ocr) =>
        reader.read(seg, crops, reads(r), ocr);

    test('T beside a screw unread: the area line "QhtET," gives ET', () {
      final r = read({
        'number0': ['0123456', '0123456', null],
        'code0': ['4', '4', null],
        'latin0': ['E', null, null],
      }, line('QhtET,'));
      expect(r.candidate.regionCode, 'ET');
    });
    test('a letter misread once ("H") does not block the area line', () {
      final r = read({
        'number0': ['0123456', '0123456', null],
        'code0': ['4', '4', null],
        'latin1': ['H', null, null],
        'latinWord0': ['E', 'E', 'IF'],
      }, line('QhtET,'));
      expect(r.candidate.regionCode, 'ET');
    });
    test('the area line contradicting a letter read is ignored', () {
      final r = read({
        'number0': ['0123456', '0123456', null],
        'code0': ['4', '4', null],
        'latin0': ['A', 'A', null],
        'latin1': ['M', 'M', null],
      }, line('QhtET,'));
      expect(r.candidate.regionCode, isNot('ET'));
    });
    test('number read with the badge and top row: the digit line', () {
      final r = read({
        'number0': [
          'TOYOTA4W\nhtET, |\n0123456',
          'TOYOTA4W\n2A ET,\n0123456',
          'OYOTA AW\n0123456'
        ],
        'code0': ['4', '4', null],
        'latin0': ['E', 'E', null],
        'latin1': ['T', 'T', null],
      }, const AreaOcr(elements: []));
      expect(r.arrangement.number.value, '0123456');
    });
  });

  test('plate edge read as I before a series letter is dropped', () {
    // C61754 (session logs of 2026-11-19): the left edge read as "I".
    final r = reader.read(
      seg,
      crops,
      reads({
        'number0': ['IC61754', 'IC61754', 'C6.754'],
        'latin0': ['E', 'E', null],
        'latin1': ['T', 'T', null],
        'code0': ['4', '4', null],
      }),
      const AreaOcr(elements: []),
    );
    expect(r.arrangement.number.value, 'C61754');
  });

  test('crops include the word and repeated-digit requests', () {
    expect(
        crops.where((c) => c.role == 'latinWord').single.group, hasLength(2));
    expect(crops.where((c) => c.role == 'codeRepeat').single.repeat, 3);
  });
}
