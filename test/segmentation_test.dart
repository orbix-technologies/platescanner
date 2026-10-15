import 'package:et_plate_reader/src/models/ocr_frame.dart';
import 'package:et_plate_reader/src/segmentation/plate_segmenter.dart';
import 'package:et_plate_reader/src/segmentation/segment_capture.dart';
import 'package:flutter_test/flutter_test.dart';

/// Real plates photographed with the app (crops of the confirmed area).
/// The sections are found from the image alone; the vertical stacks must
/// never be counted as digits.
void main() {
  PlateSegmentation seg(String name) => segmentCaptureSync(
        'test/fixtures/plates/$name.png',
        const NormalizedRect(0, 0, 1, 1),
      )!;

  void expectStandard(String name, {int digits = 7}) {
    test('$name: circle · Ge\'ez stack · $digits digits · Latin stack', () {
      final s = seg(name);
      expect(s.numberChars, hasLength(digits), reason: s.notes.join(' '));
      expect(s.latinStack, hasLength(2), reason: '${s.columns}');
      expect(s.geezStack, isNotEmpty, reason: '${s.columns}');
      expect(s.code, isNotNull, reason: '${s.columns}');
      // The stacks sit outside the number.
      expect(s.latinStack.first.left, greaterThan(s.number!.right));
      expect(s.geezStack.first.right, lessThan(s.number!.left));
    });
  }

  expectStandard('am');
  expectStandard('af');
  expectStandard('dr');
  expectStandard('or');
  expectStandard('et'); // E over T, read by OCR as a "4" glued to the number
  expectStandard('sm');
  expectStandard('red5');
  expectStandard('real_94529', digits: 5);
  expectStandard('real_71462', digits: 5);

  test('police: Ge\'ez stack · 6 digits · Latin stack, no circle', () {
    final s = seg('police');
    expect(s.numberChars, hasLength(6));
    expect(s.latinStack, hasLength(2));
    expect(s.geezStack, isNotEmpty);
    expect(s.code, isNull);
  });

  test('diplomatic: embassy digits · Ge\'ez · 4 digits · C/D', () {
    final s = seg('cd');
    expect(s.numberChars, hasLength(4), reason: '${s.columns}');
    expect(s.latinStack, hasLength(2));
    expect(s.leftDigits, hasLength(2));
  });

  test('UN: 7 digits · U/N stack', () {
    final s = seg('un');
    expect(s.numberChars, hasLength(7), reason: '${s.columns}');
    expect(s.latinStack, hasLength(2));
  });
}
