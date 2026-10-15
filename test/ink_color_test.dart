import 'package:et_plate_reader/et_plate_reader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('InkColor.classify', () {
    test('plate colours', () {
      expect(InkColor.classify(200, 40, 40), InkColor.red);
      expect(InkColor.classify(225, 95, 95), InkColor.red); // red off a screen
      expect(InkColor.classify(240, 140, 30), InkColor.orange);
      expect(InkColor.classify(40, 150, 60), InkColor.green);
      expect(InkColor.classify(30, 70, 200), InkColor.blue);
      expect(InkColor.classify(30, 30, 35), InkColor.black);
    });

    test('washed-out grey is not guessed', () {
      expect(InkColor.classify(150, 150, 150), isNull);
    });
  });

  test('colour maps to the category code', () {
    expect(PlateServiceType.fromInk(InkColor.red)!.code, '1');
    expect(PlateServiceType.fromInk(InkColor.blue)!.code, '2');
    expect(PlateServiceType.fromInk(InkColor.green)!.code, '3');
    expect(PlateServiceType.fromInk(InkColor.black)!.code, '4');
    expect(PlateServiceType.fromInk(InkColor.orange)!.code, '5');
  });

  group('section 1 from the ink colour', () {
    const number = OcrElement(
      text: '0123456',
      box: NormalizedRect(0.3, 0.2, 0.9, 0.8),
    );
    const arranger = PlateArranger();

    test('used when the circle is not read', () {
      final r = arranger.arrange(
        const AreaOcr(elements: [number], inkColor: [210, 60, 60]),
      );
      expect(r.arrangement.code.value, '1');
      expect(r.arrangement.code.note, 'by colour');
    });

    test('a clear colour wins when the circle read disagrees', () {
      final r = arranger.arrange(
        const AreaOcr(
            elements: [number], codeHint: '3', inkColor: [210, 60, 60]),
      );
      expect(r.arrangement.code.value, '1');
      expect(r.arrangement.code.note, 'by colour (circle read 3)');
    });

    test('agreeing circle and colour: no note', () {
      final r = arranger.arrange(
        const AreaOcr(
            elements: [number], codeHint: '1', inkColor: [210, 60, 60]),
      );
      expect(r.arrangement.code.value, '1');
      expect(r.arrangement.code.note, isNull);
    });

    test('an unclear colour leaves the circle read', () {
      final r = arranger.arrange(
        const AreaOcr(
            elements: [number], codeHint: '3', inkColor: [150, 150, 150]),
      );
      expect(r.arrangement.code.value, '3');
    });
  });
}
