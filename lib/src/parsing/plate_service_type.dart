/// Service category encoded by the number (or tag) in the plate's code box.
///
/// Mapping is provisional — verify against the official specification.
enum PlateServiceType {
  /// Code 1 — taxi / public transport.
  publicTransport('1', 'Public transport'),

  /// Code 2 — private vehicle.
  private('2', 'Private'),

  /// Code 3 — commercial / goods.
  commercial('3', 'Commercial'),

  /// Code 4 — government.
  government('4', 'Government'),

  /// Code 5 — NGO / aid organisation.
  ngo('5', 'NGO'),

  /// Diplomatic corps.
  diplomatic('CD', 'Diplomatic'),

  /// African Union.
  africanUnion('AU', 'African Union'),

  /// United Nations.
  unitedNations('UN', 'United Nations'),

  /// Police.
  police('POLICE', 'Police');

  const PlateServiceType(this.code, this.label);

  /// Value printed in the code box.
  final String code;

  /// English display label.
  final String label;

  /// Service type for a printed [code], or `null`.
  static PlateServiceType? fromCode(String? code) {
    if (code == null) return null;
    final c = code.trim().toUpperCase();
    for (final t in values) {
      if (t.code == c) return t;
    }
    return null;
  }

  /// True when [code] is a known numeric or special code.
  static bool isKnown(String? code) => fromCode(code) != null;
}
