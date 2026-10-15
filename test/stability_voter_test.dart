import 'package:et_plate_reader/et_plate_reader.dart';
import 'package:flutter_test/flutter_test.dart';

PlateCandidate cand(String serial, {double conf = 0.9, bool valid = true}) =>
    PlateCandidate(
      code: '2',
      regionCode: 'AA',
      serial: serial,
      layout: PlateLayout.singleRow,
      rawText: serial,
      confidence: conf,
      issues: valid ? const [] : const [PlateIssue.missingRegion],
    );

void main() {
  test('locks after N identical valid frames', () {
    final v = PlateStabilityVoter(stableFrames: 3);
    expect(v.add(cand('12345')), isNull);
    expect(v.add(cand('12345')), isNull);
    expect(v.add(cand('12345')), isNotNull);
  });

  test('a different reading restarts the run', () {
    final v = PlateStabilityVoter(stableFrames: 3);
    v.add(cand('12345'));
    v.add(cand('12345'));
    expect(v.add(cand('12346')), isNull);
    expect(v.streak, 1);
  });

  test('invalid frames do not break the run', () {
    final v = PlateStabilityVoter(stableFrames: 2);
    v.add(cand('12345'));
    expect(v.add(cand('12345', valid: false)), isNull);
    expect(v.add(cand('12345')), isNotNull);
  });

  test('low mean confidence blocks the lock', () {
    final v = PlateStabilityVoter(stableFrames: 2, minConfidence: 0.8);
    v.add(cand('12345', conf: 0.5));
    expect(v.add(cand('12345', conf: 0.6)), isNull);
  });

  test('returns the most confident frame', () {
    final v = PlateStabilityVoter(stableFrames: 2);
    v.add(cand('12345', conf: 0.95));
    expect(v.add(cand('12345', conf: 0.85))!.confidence, 0.95);
  });
}
