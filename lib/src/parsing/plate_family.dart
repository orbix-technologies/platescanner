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
  unknown,
}
