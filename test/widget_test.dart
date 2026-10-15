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

  testWidgets('shows coaching, then the locked panel, then confirms',
      (tester) async {
    PlateRecord? confirmed;
    await pumpView(tester, onConfirmed: (r) => confirmed = r);
    expect(controller.phase, ScanPhase.scanning);
    expect(find.text('Fit the plate inside the box'), findsOneWidget);

    fake.emitLines(['2 AA A12345']);
    await tester.pump();
    await tester.pump();
    expect(find.text('2  ·  AA  ·  A12345'), findsOneWidget);

    fake.emitLines(['2 AA A12345']);
    await tester.pump();
    await tester.pump();
    expect(controller.phase, ScanPhase.locked);
    expect(find.text('Done'), findsOneWidget);

    await tester.tap(find.text('Done'));
    await tester.pump();
    expect(confirmed?.canonical, '2-AA-A12345');
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
