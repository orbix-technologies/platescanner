import 'package:et_plate_reader/et_plate_reader.dart';
import 'package:flutter/material.dart';
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
      stableFrames: 2,
    );
  });

  Future<void> pumpView(WidgetTester tester, {
    PlateScannerOverlayBuilder? overlay,
    ValueChanged<PlateRecord>? onConfirmed,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlateScannerView(
            controller: controller,
            overlayBuilder: overlay,
            onPlateConfirmed: onConfirmed,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('Done sits beside the reading and confirms after lock',
      (tester) async {
    PlateRecord? confirmed;
    await pumpView(tester, onConfirmed: (r) => confirmed = r);
    expect(controller.phase, ScanPhase.scanning);
    expect(find.text('Fit the plate inside the box'), findsOneWidget);

    fake.emitLines(['2 AA A12345']);
    await tester.pump();
    await tester.pump();
    expect(find.text('2  ·  AA  ·  A12345'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Done'), findsOneWidget);

    fake.emitLines(['2 AA A12345']);
    await tester.pump();
    await tester.pump();
    expect(controller.phase, ScanPhase.locked);
    expect(find.text('Plate detected'), findsOneWidget);

    await tester.tap(find.text('Done'));
    await tester.pump();
    expect(confirmed?.canonical, '2-AA-A12345');
  });

  testWidgets('Done while scanning confirms the live reading', (tester) async {
    PlateRecord? confirmed;
    await pumpView(tester, onConfirmed: (r) => confirmed = r);
    fake.emitLines(['3 OR 54321']);
    await tester.pump();
    await tester.pump();
    expect(controller.phase, ScanPhase.scanning);

    await tester.tap(find.text('Done'));
    await tester.pump();
    expect(confirmed?.canonical, '3-OR-54321');
  });

  testWidgets('Done is disabled for an incomplete reading', (tester) async {
    await pumpView(tester);
    fake.emitLines(['2 12345']);
    await tester.pump();
    await tester.pump();
    final done = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Done'),
    );
    expect(done.onPressed, isNull);
    expect(find.text('Region not read'), findsOneWidget);
  });

  testWidgets('region of interest follows the drawn guide box',
      (tester) async {
    await pumpView(tester);
    final size = tester.getSize(find.byType(PlateScannerView));
    final guide = PlateScannerView.guideRect(size);
    final roi = controller.regionOfInterest;
    expect(roi.left, closeTo(guide.left / size.width, 1e-9));
    expect(roi.bottom, closeTo(guide.bottom / size.height, 1e-9));

    // A plate above the box is ignored.
    fake.emitFrame([
      OcrLine(
        text: '2 AA 99999',
        box: NormalizedRect(0.2, roi.top - 0.12, 0.8, roi.top - 0.04),
        confidence: 0.95,
      ),
    ]);
    await tester.pump();
    await tester.pump();
    expect(controller.liveCandidate, isNull);
  });

  testWidgets('Edit opens the field editor after lock', (tester) async {
    await pumpView(tester);
    fake.emitLines(['2 AA 12345']);
    fake.emitLines(['2 AA 12345']);
    await tester.pump();
    await tester.pump();
    expect(controller.phase, ScanPhase.locked);
    await tester.tap(find.text('Edit'));
    await tester.pump();
    expect(find.text('Serial'), findsOneWidget);
  });

  testWidgets('custom overlay replaces the default HUD', (tester) async {
    await pumpView(
      tester,
      overlay: (context, c) => Text('phase: ${c.phase.name}'),
    );
    expect(find.text('phase: scanning'), findsOneWidget);
    expect(find.text('Fit the plate inside the box'), findsNothing);
  });

  testWidgets('unsupported device shows the message', (tester) async {
    fake.supported = false;
    await pumpView(tester);
    expect(find.text('This device cannot read plates.'), findsOneWidget);
  });
}
