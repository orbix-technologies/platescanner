/// Regions (and the federal series) printed on Ethiopian plates.
///
/// Latin codes and Amharic labels are provisional — verify against the
/// Ministry of Transport and Logistics plate specification before release
/// (see doc/PLATE_FORMAT.md).
enum EthiopianRegion {
  /// Addis Ababa city administration.
  addisAbaba('AA', 'Addis Ababa', 'አአ'),

  /// Oromia.
  oromia('OR', 'Oromia', 'ኦሮ'),

  /// Amhara.
  amhara('AM', 'Amhara', 'አማ'),

  /// Tigray.
  tigray('TG', 'Tigray', 'ትግ', aliases: ['TIG', 'TGR']),

  /// Somali.
  somali('SM', 'Somali', 'ሶማ', aliases: ['SO']),

  /// Afar.
  afar('AF', 'Afar', 'አፋ'),

  /// Dire Dawa city administration.
  direDawa('DR', 'Dire Dawa', 'ድሬ', aliases: ['DD']),

  /// Harari.
  harari('HR', 'Harari', 'ሐረ', aliases: ['HA']),

  /// Benishangul-Gumuz.
  benishangulGumuz('BG', 'Benishangul-Gumuz', 'ቤጉ', aliases: ['BN']),

  /// Gambela.
  gambela('GM', 'Gambela', 'ጋም', aliases: ['GA']),

  /// Sidama.
  sidama('SD', 'Sidama', 'ሲዳ', aliases: ['SI']),

  /// Former SNNPR series, still on many vehicles.
  southern('SP', 'Southern (SNNP)', 'ደሕ', aliases: ['SN', 'SNNP']),

  /// South West Ethiopia Peoples'.
  southWest('SW', 'South West Ethiopia', 'ደም'),

  /// Federal / national series.
  federal('ET', 'Federal', 'ኢት');

  const EthiopianRegion(
    this.code,
    this.englishName,
    this.amharicLabel, {
    this.aliases = const [],
  });

  /// Latin abbreviation as printed on the plate.
  final String code;

  /// English display name.
  final String englishName;

  /// Ge'ez abbreviation as printed on the plate.
  final String amharicLabel;

  /// Other Latin spellings seen on older plates or produced by OCR.
  final List<String> aliases;

  /// Region for a Latin [token] (code or alias), or `null`.
  static EthiopianRegion? fromLatin(String token) {
    final t = token.trim().toUpperCase();
    if (t.isEmpty) return null;
    for (final r in values) {
      if (r.code == t || r.aliases.contains(t)) return r;
    }
    return null;
  }

  /// Region for a canonical [code] such as `AA`, or `null`.
  static EthiopianRegion? fromCode(String? code) {
    if (code == null) return null;
    for (final r in values) {
      if (r.code == code) return r;
    }
    return null;
  }

  /// Region whose Amharic label occurs in [text], or `null`.
  static EthiopianRegion? findAmharic(String text) {
    for (final r in values) {
      if (text.contains(r.amharicLabel)) return r;
    }
    return null;
  }
}
