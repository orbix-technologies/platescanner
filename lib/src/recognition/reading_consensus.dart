import '../models/plate_record.dart';

/// Outcome of majority-voting several recognition passes on one still.
class ReadingConsensus {
  /// Creates a consensus result.
  const ReadingConsensus({
    required this.winner,
    required this.agreement,
    required this.ballots,
    required this.agreed,
    required this.meanConfidence,
  });

  /// Chosen candidate (majority, else highest confidence).
  final PlateCandidate winner;

  /// Fraction of ballots matching [winner.key] (`0`–`1`).
  final double agreement;

  /// Every pass's candidate.
  final List<PlateCandidate> ballots;

  /// True when ≥ [minAgreement] of ballots share [winner.key].
  final bool agreed;

  /// Mean confidence across ballots that match the winner.
  final double meanConfidence;

  /// True when the reading is strong enough to skip forcing review urgency.
  bool get reliable =>
      agreed && meanConfidence >= 0.55 && winner.issues.isEmpty;
}

/// Majority-votes [ballots] on [PlateCandidate.key].
///
/// Requires at least [minAgreement] (default 2/3) of non-empty ballots to
/// share the winning key. On ties or disagreement, picks the highest
/// confidence valid candidate (then any highest confidence).
ReadingConsensus voteReadings(
  List<PlateCandidate> ballots, {
  double minAgreement = 2 / 3,
}) {
  final usable = ballots.where((c) => c.serial != null && c.serial!.isNotEmpty);
  final list = usable.isEmpty ? ballots : usable.toList();
  if (list.isEmpty) {
    final empty = PlateCandidate(
      code: null,
      regionCode: null,
      serial: null,
      layout: PlateLayout.unknown,
      rawText: '',
      confidence: 0,
      issues: const [PlateIssue.missingSerial],
    );
    return ReadingConsensus(
      winner: empty,
      agreement: 0,
      ballots: ballots,
      agreed: false,
      meanConfidence: 0,
    );
  }

  final counts = <String, int>{};
  final bestForKey = <String, PlateCandidate>{};
  for (final c in list) {
    counts[c.key] = (counts[c.key] ?? 0) + 1;
    final prev = bestForKey[c.key];
    if (prev == null || c.confidence > prev.confidence) {
      bestForKey[c.key] = c;
    }
  }

  var winKey = counts.entries.reduce((a, b) {
    if (b.value != a.value) return b.value > a.value ? b : a;
    final ca = bestForKey[a.key]!.confidence;
    final cb = bestForKey[b.key]!.confidence;
    return cb >= ca ? b : a;
  }).key;

  // Prefer a valid majority when a invalid key tied or won narrowly.
  final validMajority = counts.entries
      .where((e) => bestForKey[e.key]!.issues.isEmpty)
      .toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  if (validMajority.isNotEmpty &&
      validMajority.first.value >= counts[winKey]! &&
      bestForKey[winKey]!.issues.isNotEmpty) {
    winKey = validMajority.first.key;
  }

  final winner = bestForKey[winKey]!;
  final n = list.length;
  final agreement = (counts[winKey] ?? 0) / n;
  final supporters = list.where((c) => c.key == winKey);
  final mean = supporters.isEmpty
      ? winner.confidence
      : supporters.map((c) => c.confidence).reduce((a, b) => a + b) /
          supporters.length;

  return ReadingConsensus(
    winner: winner,
    agreement: agreement,
    ballots: List.unmodifiable(ballots),
    agreed: agreement + 1e-9 >= minAgreement,
    meanConfidence: mean,
  );
}
