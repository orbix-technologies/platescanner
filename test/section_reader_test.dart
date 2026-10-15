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

  test('sections assembled: 4 · XX · 0123456 · ET', () {
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
    expect(a.layoutText, '4 XX 0123456 ET');
    expect(a.latinRegion.chars.map((c) => c.text), ['E', 'T']);
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
    expect(r.arrangement.layoutText, '4 XX 0123456 ET');
  });

  test('crops include the word and repeated-digit requests', () {
    expect(crops.where((c) => c.role == 'latinWord').single.group, hasLength(2));
    expect(crops.where((c) => c.role == 'codeRepeat').single.repeat, 3);
  });
}
