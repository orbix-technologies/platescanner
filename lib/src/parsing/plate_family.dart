/// Layout family of an Ethiopian plate (geometry / generation), distinct
/// from [PlateServiceType] (taxi / private / …) and [PlateLayout]
/// (single-row vs two-row within classic plates).
enum PlateFamily {
  /// Circled code · Ge'ez stack · number · Latin stack on one row.
  classicSingle,

  /// Code / region letters on the top row, large serial below.
  classicTwoRow,

  /// New national plate (Directive 1050/2025): ETH block, `AAA####`, no region.
  nationalEth,

  /// Police, diplomatic, UN, AU, temporary, daily permit, etc.
  special,

  /// Classifier could not decide; force review.
  unknown;

  /// Best-effort family from a confirmed reading (for session labelling).
  static PlateFamily fromConfirmed({
    required String? code,
    required String? regionCode,
    required String? serial,
    required bool twoRow,
  }) {
    if (code == 'ETH' ||
        (serial != null && RegExp(r'^[A-Z]{3}\d{4}$').hasMatch(serial))) {
      return PlateFamily.nationalEth;
    }
    if (code == 'CD' ||
        code == 'UN' ||
        code == 'AU' ||
        code == 'POLICE' ||
        code == 'TEMP' ||
        code == 'DAILY') {
      return PlateFamily.special;
    }
    if (twoRow) return PlateFamily.classicTwoRow;
    if (code != null || regionCode != null) return PlateFamily.classicSingle;
    return PlateFamily.unknown;
  }
}
