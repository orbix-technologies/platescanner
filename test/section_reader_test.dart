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
    expect(crops.where((c) => c.role == 'digit'), hasLength(7));
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

  test('a digit disagreeing with the line read keeps the confident read', () {
    final r = reader.read(
      seg,
      crops,
      reads({
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
}
