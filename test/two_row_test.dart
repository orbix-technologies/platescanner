import 'package:et_plate_reader/et_plate_reader.dart';
import 'package:et_plate_reader/src/parsing/plate_section_reader.dart';
import 'package:et_plate_reader/src/segmentation/segment_capture.dart';
import 'package:flutter_test/flutter_test.dart';

/// Old two-row plates: circle · two Ge'ez letters · chip · two Latin letters
/// (side by side) on top, the number alone below.
void main() {
  const area = NormalizedRect(0, 0, 1, 1);
  const reader = PlateSectionReader();

  // Fixture → digits in the number, whether the top row is read in full.
  const fixtures = {
    'two_row_a45699.png': (6, true),
    'two_row_04765.png': (5, true),
    'two_row_04765_car.png': (5, true),
    'two_row_51988_et.png': (5, true),
    'two_row_71141_rotated.png': (5, true),
    'two_row_a84451.png': (6, false),
  };

  fixtures.forEach((name, expected) {
    test('$name: two rows found', () {
      final seg = segmentCaptureSync('test/fixtures/plates/$name', area)!;
      expect(seg.twoRow, isTrue);
      expect(seg.numberChars, hasLength(expected.$1));
      // The number is the lower row.
      expect(seg.number!.top, greaterThan(0.3));
      if (expected.$2) {
        expect(seg.geezStack, hasLength(2));
        expect(seg.latinStack, hasLength(2));
        expect(seg.latinSideBySide, isTrue);
        // Region letters on the top row, side by side, left to right.
        for (final r in [...seg.geezStack, ...seg.latinStack]) {
          expect(r.bottom, lessThanOrEqualTo(seg.number!.top + 0.02));
        }
        expect(seg.latinStack[0].right, lessThan(seg.latinStack[1].left));
      }
    });
  });

  test('read: 2 · አአ · A45699 · AA, two-row layout', () {
    final seg =
        segmentCaptureSync('test/fixtures/plates/two_row_a45699.png', area)!;
    final crops = reader.cropsFor(seg, area);
    // The number crop is not cut short by the region letters above it.
    final number = crops.firstWhere((c) => c.role == 'number').inArea;
    expect(number.left, lessThan(seg.numberChars.first.left));
    expect(number.right, greaterThan(seg.numberChars.last.right));
    final byRole = {
      'number0': ['A45699', 'A45699', null],
      'latinWord0': ['AA', 'AA', null],
      'code0': ['2', '2', null],
    };
    final r = reader.read(
      seg,
      crops,
      [
        for (final c in crops)
          byRole['${c.role}${c.index}'] ?? const [null, null, null],
      ],
      const AreaOcr(elements: []),
    );
    expect(r.arrangement.layoutText, '2 አአ A45699 AA');
    expect(r.candidate.layout, PlateLayout.twoRow);
    expect(r.candidate.isValid, isTrue);
  });

  test('one-row plates are not taken for two-row', () {
    for (final name in ['et.png', 'cd.png', 'police.png', 'un.png', 'au.png']) {
      final seg = segmentCaptureSync('test/fixtures/plates/$name', area)!;
      expect(seg.twoRow, isFalse, reason: name);
    }
  });

  // Walking patrol photos (2026-10-23): tilted two-row plates whose
  // region row touches the border and whose circle and Ge'ez letters merge.
  // B32675's circle is not found yet.
  for (final (plate, seed, circle) in [
    ('B32675', const NormalizedRect(0.1875, 0.338, 0.5988, 0.4422), false),
    ('C69001', const NormalizedRect(0.0, 0.3922, 0.5714, 0.5484), true),
  ]) {
    test('patrol photo $plate: the top row is found and read in sections', () {
      final path = 'test/fixtures/stills/patrol_$plate.jpg';
      final bounds = findCaptureBoundsSync(path, seed);
      expect(bounds?.twoRow, isTrue);
      final seg = segmentCaptureSync(path, bounds!.area, twoRowHint: true)!;
      expect(seg.twoRow, isTrue);
      if (circle) expect(seg.code, isNotNull);
      expect(seg.geezStack, hasLength(2));
      expect(seg.latinStack, hasLength(2));
      expect(seg.numberChars.length, greaterThanOrEqualTo(6));
    });
  }
}
