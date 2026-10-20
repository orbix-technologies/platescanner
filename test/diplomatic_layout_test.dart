import 'package:et_plate_reader/et_plate_reader.dart';
import 'package:et_plate_reader/src/parsing/plate_section_reader.dart';
import 'package:et_plate_reader/src/segmentation/segment_capture.dart';
import 'package:flutter_test/flutter_test.dart';

/// Diplomatic plate: embassy number · Ge'ez · 4 digits · C/D, no circle.
void main() {
  const area = NormalizedRect(0, 0, 1, 1);
  final seg = segmentCaptureSync('test/fixtures/plates/cd.png', area)!;
  const reader = PlateSectionReader();
  final crops = reader.cropsFor(seg, area);

  List<List<String?>> reads(Map<String, List<String?>> byRole) => [
        for (final c in crops)
          byRole['${c.role}${c.index}'] ?? const [null, null, null],
      ];

  test('layout: no circle, two embassy digits, four-digit number', () {
    expect(seg.code, isNull);
    expect(seg.leftDigits, hasLength(2));
    expect(seg.numberChars, hasLength(4));
    expect(crops.where((c) => c.role == 'embassy'), hasLength(2));
  });

  test('C/D misread on its yellow strip: still diplomatic, not by colour', () {
    final r = reader.read(
      seg,
      crops,
      reads({
        'number0': ['0123', '0123', null],
        'latin0': ['L', null, null],
        'latin1': [null, null, null],
        // Lone digits read badly; the pair as one word reads.
        'embassy0': [null, null, null],
        'embassy1': ['9', null, null],
        'embassyWord0': ['06', '06', null],
      }),
      const AreaOcr(elements: [], inkColor: [20, 20, 20]),
    );
    final a = r.arrangement;
    expect(a.code.value, 'CD');
    expect(a.code.note, startsWith('embassy 06'));
    // No circle: section 1 is the embassy number, boxed where it is.
    expect(a.code.chars.single.text, '06');
    expect(a.code.box, isNotNull);
    expect(a.code.box!.right, lessThan(seg.geezStack.first.left));
    expect(a.latinRegion.value, 'CD');
    expect(a.latinRegion.note, 'by layout');
    expect(a.number.value, '0123');
  });
}
