import 'dart:async';

import 'package:et_plate_reader/et_plate_reader.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_plate_service.dart';

void main() {
  late FakePlateService fake;
  late PlateReaderController controller;

  setUp(() {
    fake = FakePlateService();
    controller = PlateReaderController(
      service: fake,
      requestCameraPermission: () async => true,
      stableFrames: 3,
    );
  });

  tearDown(() => controller.dispose());

  Future<void> tick() => Future<void>.delayed(Duration.zero);

  Future<void> scanning() async {
    await controller.initialize();
    await controller.startSession();
  }

  Future<void> emit(List<String> texts, {int times = 1}) async {
    for (var i = 0; i < times; i++) {
      fake.emitLines(texts);
      await tick();
    }
  }

  test('startSession starts the backend', () async {
    await scanning();
    expect(controller.phase, ScanPhase.scanning);
    expect(fake.running, isTrue);
  });

  test('stable frames auto-lock and pause the backend', () async {
    await scanning();
    await emit(['2 AA A12345'], times: 2);
    expect(controller.phase, ScanPhase.scanning);
    expect(controller.liveCandidate?.serial, 'A12345');
    await emit(['2 AA A12345']);
    expect(controller.phase, ScanPhase.locked);
    expect(controller.draftSerial, 'A12345');
    expect(fake.running, isFalse);
    expect(controller.canConfirm, isTrue);
  });

  test('confirm returns a record', () async {
    await scanning();
    await emit(['3 OR 54321'], times: 3);
    final record = await controller.confirm();
    expect(record.canonical, '3-OR-54321');
    expect(record.editedByUser, isFalse);
    expect(controller.phase, ScanPhase.confirmed);
  });

  test('lines outside the region of interest are ignored', () async {
    await scanning();
    fake.emitLines(['2 AA 12345']);
    await tick();
    expect(controller.liveCandidate, isNotNull);

    fake.emitFrame([
      const OcrLine(
        text: '2 AA 99999',
        box: NormalizedRect(0.2, 0.01, 0.8, 0.05),
        confidence: 0.95,
      ),
    ]);
    await tick();
    expect(controller.liveCandidate, isNull);
  });

  test('manual lock + edit fixes an incomplete reading', () async {
    await scanning();
    await emit(['2 12345']);
    expect(controller.liveCandidate!.isValid, isFalse);
    expect(await controller.lockCurrent(), isTrue);
    expect(controller.canConfirm, isFalse);
    expect(controller.draftIssues, [PlateIssue.missingRegion]);

    controller.editField(regionCode: 'AA');
    expect(controller.canConfirm, isTrue);
    final record = await controller.confirm();
    expect(record.regionCode, 'AA');
    expect(record.editedByUser, isTrue);
  });

  test('editField normalises the serial', () async {
    await scanning();
    await emit(['2 AA 12345'], times: 3);
    controller.editField(serial: 'b 67890');
    expect(controller.draftSerial, 'B67890');
  });

  test('confirm before lock throws', () async {
    await scanning();
    expect(controller.confirm, throwsA(isA<PlateReaderException>()));
  });

  test('rescan resumes scanning', () async {
    await scanning();
    await emit(['2 AA 12345'], times: 3);
    await controller.rescan();
    expect(controller.phase, ScanPhase.scanning);
    expect(controller.lockedCandidate, isNull);
    expect(fake.startCalls, 2);
  });

  test('permission denied surfaces an error', () async {
    final c = PlateReaderController(
      service: FakePlateService(),
      requestCameraPermission: () async => false,
    );
    await expectLater(c.initialize, throwsA(isA<PlateReaderException>()));
    expect(c.phase, ScanPhase.error);
    expect(c.error, contains('permission'));
    c.dispose();
  });

  test('unsupported device', () async {
    final f = FakePlateService()..supported = false;
    final c = PlateReaderController(
      service: f,
      requestCameraPermission: () async => true,
    );
    await expectLater(c.initialize, throwsA(isA<PlateReaderException>()));
    expect(c.isSupported, isFalse);
    c.dispose();
  });

  test('platform errors move to the error phase', () async {
    await scanning();
    fake.emitError('Camera closed');
    await tick();
    expect(controller.phase, ScanPhase.error);
    expect(controller.error, 'Camera closed');
  });

  test('torch toggles', () async {
    await scanning();
    await controller.toggleTorch();
    expect(controller.torchOn, isTrue);
  });

  test('autoLock: false never locks on its own', () async {
    final c = PlateReaderController(
      service: fake,
      requestCameraPermission: () async => true,
      stableFrames: 1,
      autoLock: false,
    );
    await c.initialize();
    await c.startSession();
    fake.emitLines(['2 AA 12345']);
    await tick();
    expect(c.phase, ScanPhase.scanning);
    unawaited(c.cancelSession());
  });
}
