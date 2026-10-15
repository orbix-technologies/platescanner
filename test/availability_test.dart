import 'package:et_plate_reader/et_plate_reader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('maps native statuses', () {
    expect(
      PlateReader.fromNative({'status': 'supported'}).isSupported,
      isTrue,
    );
    expect(
      PlateReader.fromNative({'status': 'noCamera'}).status,
      PlateReaderAvailabilityStatus.unsupported,
    );
    expect(
      PlateReader.fromNative({'status': 'modelMissing'}).status,
      PlateReaderAvailabilityStatus.modelMissing,
    );
    expect(
      PlateReader.fromNative(null).status,
      PlateReaderAvailabilityStatus.unknown,
    );
  });

  test('non-mobile host platform is unsupported', () async {
    // flutter test runs on the host OS (Linux / macOS), not Android / iOS.
    final a = await PlateReader.checkAvailability();
    expect(a.isSupported, isFalse);
  });
}
