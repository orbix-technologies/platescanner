import 'package:et_plate_reader/src/models/plate_record.dart';
import 'package:et_plate_reader/src/recognition/reading_consensus.dart';
import 'package:flutter_test/flutter_test.dart';

PlateCandidate cand(String code, String region, String serial, double conf) =>
    PlateCandidate(
      code: code,
      regionCode: region,
      serial: serial,
      layout: PlateLayout.singleRow,
      rawText: '$code-$region-$serial',
      confidence: conf,
      issues: const [],
    );

void main() {
  test('majority wins at 2/3', () {
    final c = voteReadings([
      cand('2', 'AA', 'C06703', 0.7),
      cand('2', 'AA', 'C06703', 0.8),
      cand('2', 'AA', 'C06708', 0.9),
    ]);
    expect(c.winner.serial, 'C06703');
    expect(c.agreed, isTrue);
    expect(c.agreement, closeTo(2 / 3, 0.01));
  });

  test('disagreement marks unreliable', () {
    final c = voteReadings([
      cand('2', 'AA', 'C06703', 0.7),
      cand('2', 'AA', 'B05475', 0.8),
      cand('2', 'OR', 'C06703', 0.6),
    ]);
    expect(c.agreed, isFalse);
    expect(c.reliable, isFalse);
  });

  test('highest confidence among majority', () {
    final c = voteReadings([
      cand('2', 'AA', 'C06703', 0.5),
      cand('2', 'AA', 'C06703', 0.95),
      cand('3', 'AA', 'C06703', 0.4),
    ]);
    expect(c.winner.confidence, 0.95);
    expect(c.agreed, isTrue);
  });
}
