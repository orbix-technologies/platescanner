import 'package:et_plate_reader/et_plate_reader.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_plate_service.dart';

const plateOcr = AreaOcr(
  codeHint: '1',
  elements: [
    OcrElement(text: 'D', box: NormalizedRect(0.02, 0.3, 0.08, 0.7)),
    OcrElement(text: '0123456', box: NormalizedRect(0.25, 0.2, 0.85, 0.8)),
    OcrElement(text: 'A', box: NormalizedRect(0.92, 0.15, 0.97, 0.45)),
    OcrElement(text: 'A', box: NormalizedRect(0.92, 0.55, 0.97, 0.85)),
  ],
);

void main() {
  late FakePlateService fake;
  late PlateReaderController controller;

  setUp(() {
    fake = FakePlateService()..areaOcr = plateOcr;
    controller = PlateReaderController(
      service: fake,
      requestCameraPermission: () async => true,
      stableFrames: 2,
    );
  });

  tearDown(() => controller.dispose());

  Future<void> tick() => Future<void>.delayed(Duration.zero);

  Future<void> detecting() async {
    await controller.initialize();
    await controller.startSession();
  }

  Future<void> plateInView({int frames = 1}) async {
    for (var i = 0; i < frames; i++) {
      fake.emitLines(['D-0123456']);
      await tick();
    }
  }

  test('step 1: detects the plate area inside the box', () async {
    await detecting();
    expect(controller.phase, ScanPhase.detecting);
    await plateInView();
    expect(controller.detectedArea, isNotNull);
    expect(controller.phase, ScanPhase.detecting);
  });

  test('step 1: text outside the box is not detected', () async {
    await detecting();
    fake.emitFrame(const [
      OcrLine(text: '0123456', box: NormalizedRect(0.2, 0.01, 0.8, 0.05)),
    ]);
    await tick();
    expect(controller.detectedArea, isNull);
  });

  test('steady area auto-captures and pauses the camera (step 2)', () async {
    await detecting();
    await plateInView(frames: 2);
    await tick();
    expect(controller.phase, ScanPhase.confirmingArea);
    expect(fake.captures, 1);
    expect(fake.running, isFalse);
    expect(controller.plateArea, controller.detectedArea);
  });

  test('manual capture without detection proposes the guide box', () async {
    await detecting();
    expect(await controller.captureArea(), isTrue);
    expect(controller.plateArea, controller.regionOfInterest);
  });

  test('step 2: adjustArea clamps and rejects tiny areas', () async {
    await detecting();
    await controller.captureArea();
    controller.adjustArea(const NormalizedRect(-0.1, 0.3, 0.9, 0.5));
    expect(controller.plateArea!.left, 0);
    controller.adjustArea(const NormalizedRect(0.1, 0.3, 0.11, 0.5));
    expect(controller.plateArea!.right, 0.9);
  });

  test('steps 3–4: confirmArea reads and arranges the plate', () async {
    await detecting();
    await controller.captureArea();
    controller.adjustArea(const NormalizedRect(0.1, 0.3, 0.9, 0.5));
    await controller.confirmArea();
    expect(fake.lastArea, const NormalizedRect(0.1, 0.3, 0.9, 0.5));
    expect(controller.phase, ScanPhase.review);
    expect(controller.arrangement!.layoutText, '1 XX 0123456 AA');
    expect(
      [
        controller.draftCode,
        controller.draftRegionCode,
        controller.draftSerial
      ],
      ['1', 'AA', '0123456'],
    );
    expect(controller.canConfirm, isTrue);

    final record = await controller.confirm();
    expect(record.canonical, '1-AA-0123456');
    expect(record.imagePath, '/tmp/frame.jpg');
    expect(controller.phase, ScanPhase.confirmed);
  });

  test('edit fixes an incomplete reading', () async {
    fake.areaOcr = const AreaOcr(elements: [
      OcrElement(text: '0123456', box: NormalizedRect(0.25, 0.2, 0.85, 0.8)),
    ]);
    await detecting();
    await controller.captureArea();
    await controller.confirmArea();
    expect(controller.canConfirm, isFalse);
    controller.editField(code: '1', regionCode: 'AA');
    expect(controller.canConfirm, isTrue);
    expect((await controller.confirm()).editedByUser, isTrue);
  });

  test('adjustAgain returns to the area step on the same frame', () async {
    await detecting();
    await controller.captureArea();
    await controller.confirmArea();
    controller.adjustAgain();
    expect(controller.phase, ScanPhase.confirmingArea);
    expect(controller.capturedFrame, isNotNull);
  });

  test('retake goes back to detection', () async {
    await detecting();
    await controller.captureArea();
    await controller.retake();
    expect(controller.phase, ScanPhase.detecting);
    expect(controller.capturedFrame, isNull);
    expect(fake.running, isTrue);
  });

  test('confirm before review throws', () async {
    await detecting();
    expect(controller.confirm, throwsA(isA<PlateReaderException>()));
  });

  test('autoCapture: false waits for the user', () async {
    final c = PlateReaderController(
      service: fake,
      requestCameraPermission: () async => true,
      stableFrames: 1,
      autoCapture: false,
    );
    await c.initialize();
    await c.startSession();
    fake.emitLines(['D-0123456']);
    await tick();
    expect(c.phase, ScanPhase.detecting);
    expect(c.detectedArea, isNotNull);
  });

  test('permission denied surfaces an error', () async {
    final c = PlateReaderController(
      service: FakePlateService(),
      requestCameraPermission: () async => false,
    );
    await expectLater(c.initialize, throwsA(isA<PlateReaderException>()));
    expect(c.phase, ScanPhase.error);
    c.dispose();
  });

  test('platform errors move to the error phase; retake recovers', () async {
    await detecting();
    fake.emitError('Camera closed');
    await tick();
    expect(controller.phase, ScanPhase.error);
    await controller.retake();
    expect(controller.phase, ScanPhase.detecting);
  });
}
