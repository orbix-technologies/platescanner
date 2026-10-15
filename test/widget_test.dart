import 'package:et_plate_reader/et_plate_reader.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'controller_test.dart' show plateOcr;
import 'fake_plate_service.dart';

void main() {
  late FakePlateService fake;
  late PlateReaderController controller;

  setUp(() {
    fake = FakePlateService()..areaOcr = plateOcr;
    controller = PlateReaderController(
      service: fake,
      requestCameraPermission: () async => true,
      autoCapture: false,
    );
  });

  Future<void> pumpView(
    WidgetTester tester, {
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

  testWidgets('full flow: detect → confirm area → review → Done',
      (tester) async {
    PlateRecord? confirmed;
    await pumpView(tester, onConfirmed: (r) => confirmed = r);
    expect(find.text('Fit the plate inside the box'), findsOneWidget);

    fake.emitLines(['D-0123456']);
    await tester.pump();
    await tester.pump();
    expect(find.text('Plate found — hold steady'), findsOneWidget);

    // Image.file can't load in tests; the flow itself is what's checked.
    await tester.runAsync(() => controller.captureArea());
    await tester.pump();
    expect(find.text('Confirm area'), findsOneWidget);
    expect(find.text('Retake'), findsOneWidget);

    await tester.tap(find.text('Confirm area'));
    await tester.pump();
    await tester.pump();
    expect(controller.phase, ScanPhase.review);
    expect(find.text('0123456'), findsOneWidget); // serial chip
    expect(find.text('Serial'), findsOneWidget);
    expect(find.text('1  ·  AA  ·  0123456'), findsOneWidget);
    expect(find.text('አአ · Addis Ababa'), findsOneWidget);

    await tester.tap(find.text('Done'));
    await tester.pump();
    expect(confirmed?.canonical, '1-AA-0123456');
  });

  testWidgets('region of interest follows the drawn guide box', (tester) async {
    await pumpView(tester);
    final size = tester.getSize(find.byType(PlateScannerView));
    final guide = PlateScannerView.guideRect(size);
    expect(
      controller.regionOfInterest.left,
      closeTo(guide.left / size.width, 1e-9),
    );
  });

  testWidgets('custom overlay replaces the default HUD', (tester) async {
    await pumpView(
      tester,
      overlay: (context, c) => Text('phase: ${c.phase.name}'),
    );
    expect(find.text('phase: detecting'), findsOneWidget);
    expect(find.text('Capture'), findsNothing);
  });

  testWidgets('unsupported device shows the message', (tester) async {
    fake.supported = false;
    await pumpView(tester);
    expect(find.text('This device cannot read plates.'), findsOneWidget);
  });
}
