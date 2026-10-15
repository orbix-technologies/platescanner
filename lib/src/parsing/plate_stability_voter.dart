import '../models/plate_record.dart';

/// Locks a reading once the same valid candidate repeats across frames.
///
/// Single-frame OCR flickers between near-identical reads (`A12345` /
/// `A12346`); requiring [stableFrames] consecutive matches above
/// [minConfidence] keeps a wrong digit from being accepted.
class PlateStabilityVoter {
  /// Creates a voter.
  PlateStabilityVoter({this.stableFrames = 4, this.minConfidence = 0.7})
      : assert(stableFrames >= 1),
        assert(minConfidence >= 0 && minConfidence <= 1);

  /// Consecutive matching valid frames needed to lock.
  final int stableFrames;

  /// Minimum mean confidence over those frames.
  final double minConfidence;

  final List<PlateCandidate> _run = [];

  /// Frames in the current run of matching valid readings.
  int get streak => _run.length;

  /// Progress towards a lock (`0.0`–`1.0`).
  double get progress => (_run.length / stableFrames).clamp(0.0, 1.0);

  /// Feeds one frame; returns the candidate to lock, or `null`.
  ///
  /// Invalid frames do not break the run (a blurred frame between two good
  /// ones is common); a different valid reading does.
  PlateCandidate? add(PlateCandidate candidate) {
    if (!candidate.isValid) return null;
    if (_run.isNotEmpty && _run.last.key != candidate.key) {
      _run.clear();
    }
    _run.add(candidate);
    if (_run.length > stableFrames) _run.removeAt(0);
    if (_run.length < stableFrames) return null;

    final mean =
        _run.map((c) => c.confidence).reduce((a, b) => a + b) / _run.length;
    if (mean < minConfidence) return null;

    // Return the most confident frame of the run (best rawText / box).
    return _run.reduce((a, b) => b.confidence > a.confidence ? b : a);
  }

  /// Clears the current run.
  void reset() => _run.clear();
}
