import 'package:et_plate_reader/et_plate_reader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const detector = PlateAreaDetector();

  test('anchors on the serial and spans the band', () {
    final area = detector.detect(const [
      OcrLine(text: 'D-0123456', box: NormalizedRect(0.3, 0.40, 0.8, 0.46)),
      OcrLine(text: 'A', box: NormalizedRect(0.82, 0.39, 0.85, 0.42)),
      OcrLine(text: 'TOYOTA', box: NormalizedRect(0.3, 0.70, 0.6, 0.74)),
    ])!;
    expect(area.left, lessThan(0.3));
    expect(area.right, greaterThan(0.85));
    expect(area.top, lessThan(0.40));
    // The badge far below is not part of the plate.
    expect(area.bottom, lessThan(0.6));
  });

  test('anchors on the new national number (three letters, four digits)', () {
    final area = detector.detect(const [
      OcrLine(text: 'AAA0000', box: NormalizedRect(0.3, 0.40, 0.8, 0.46)),
    ]);
    expect(area, isNotNull);
    expect(area!.left, lessThan(0.3));
    // The notched 0 read as G / O (session logs).
    for (final t in ['AAAGG0O', 'AAAGGOO', 'AAAG000O']) {
      expect(
          detector.detect([
            OcrLine(text: t, box: const NormalizedRect(0.3, 0.4, 0.8, 0.46)),
          ]),
          isNotNull,
          reason: t);
    }
    // A digit run elsewhere in view doesn't take over (session logs).
    final both = detector.detectDetailed(const [
      OcrLine(text: '0123445', box: NormalizedRect(0.2, 0.1, 0.8, 0.2)),
      OcrLine(text: 'AAAGGO0', box: NormalizedRect(0.3, 0.4, 0.8, 0.46)),
    ])!;
    expect(both.national, isTrue);
    expect(both.area.top, greaterThan(0.3));
    // Words are not plates.
    for (final t in ['TOYOTA', 'ETHIOPIA', 'national']) {
      expect(
          detector.detect([
            OcrLine(text: t, box: const NormalizedRect(0.3, 0.4, 0.8, 0.46)),
          ]),
          isNull,
          reason: t);
    }
  });

  test('no serial-like text, no area', () {
    expect(
      detector.detect(const [
        OcrLine(text: 'TOYOTA', box: NormalizedRect(0.3, 0.4, 0.6, 0.45)),
      ]),
      isNull,
    );
  });

  test('tracker needs consecutive overlapping areas', () {
    final t = PlateAreaTracker(stableFrames: 3);
    const a = NormalizedRect(0.1, 0.4, 0.9, 0.5);
    const moved = NormalizedRect(0.5, 0.1, 0.9, 0.2);
    expect(t.add(a), isFalse);
    expect(t.add(a), isFalse);
    expect(t.add(moved), isFalse);
    expect(t.add(moved), isFalse);
    expect(t.add(moved), isTrue);
    expect(t.add(null), isFalse);
  });
}
