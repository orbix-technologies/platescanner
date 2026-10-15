/// Category encoded by the number in the plate's circle (section 1), and
/// by the plate's colours.
///
/// Source: https://www.metaappz.com/References/Ethiopian_licence_plates
/// (the page notes its samples may not be identical to the originals).
enum PlateServiceType {
  /// Code 1 — taxi: minibuses, contract taxis, bajajs. Red.
  publicTransport('1', 'Taxi', InkColor.red),

  /// Code 2 — private vehicle. Blue on white.
  private('2', 'Private', InkColor.blue),

  /// Code 3 — commercial / business. Green on white.
  commercial('3', 'Commercial', InkColor.green),

  /// Code 4 — government. Black on white.
  government('4', 'Government', InkColor.black),

  /// Code 5 — Red Cross, religious and civic societies. Orange on white.
  ngo('5', 'Red Cross / civic society', InkColor.orange),

  /// Diplomatic corps (embassies carry a numbered country code).
  diplomatic('CD', 'Diplomatic', null),

  /// African Union — light green, marked "አሕ" and "AU".
  africanUnion('AU', 'African Union', null),

  /// United Nations — light blue, marked "የተመ" and "UN".
  unitedNations('UN', 'United Nations', null),

  /// Police — yellow with black characters, "ፖሊስ" on the left.
  police('POLICE', 'Police', null);

  const PlateServiceType(this.code, this.label, this.ink);

  /// Value printed in the circle (or the special tag).
  final String code;

  /// English display label.
  final String label;

  /// Character colour that identifies the category, for codes 1–5.
  final InkColor? ink;

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

  /// Category whose characters have [ink], or `null`.
  static PlateServiceType? fromInk(InkColor? ink) {
    if (ink == null) return null;
    for (final t in values) {
      if (t.ink == ink) return t;
    }
    return null;
  }
}

/// Character colours used on Ethiopian plates (codes 1–5).
enum InkColor {
  /// Code 1.
  red,

  /// Code 5.
  orange,

  /// Code 3.
  green,

  /// Code 2.
  blue,

  /// Code 4.
  black;

  /// Classifies an average ink colour (0–255 channels), or `null` when it
  /// matches none clearly (e.g. washed out or a colour cast).
  static InkColor? classify(int r, int g, int b) {
    final rf = r / 255, gf = g / 255, bf = b / 255;
    final max = [rf, gf, bf].reduce((a, b) => a > b ? a : b);
    final min = [rf, gf, bf].reduce((a, b) => a < b ? a : b);
    final delta = max - min;
    final saturation = max == 0 ? 0.0 : delta / max;
    if (saturation < 0.25) {
      // No clear hue: black ink is dark; anything lighter is unknown.
      return max < 0.45 ? InkColor.black : null;
    }
    double hue;
    if (max == rf) {
      hue = 60 * (((gf - bf) / delta) % 6);
    } else if (max == gf) {
      hue = 60 * ((bf - rf) / delta + 2);
    } else {
      hue = 60 * ((rf - gf) / delta + 4);
    }
    if (hue < 0) hue += 360;
    if (hue < 18 || hue >= 330) return InkColor.red;
    if (hue < 45) return InkColor.orange;
    if (hue >= 75 && hue < 170) return InkColor.green;
    if (hue >= 185 && hue < 260) return InkColor.blue;
    return null;
  }
}

/// Plate background colours.
class PaperColor {
  PaperColor._();

  /// Yellow / amber background (police plates), from an average colour.
  static bool isYellow(int r, int g, int b) {
    final rf = r / 255, gf = g / 255, bf = b / 255;
    final max = [rf, gf, bf].reduce((a, b) => a > b ? a : b);
    final min = [rf, gf, bf].reduce((a, b) => a < b ? a : b);
    final delta = max - min;
    if (max < 0.35 || delta / max < 0.35) return false;
    double hue;
    if (max == rf) {
      hue = 60 * (((gf - bf) / delta) % 6);
    } else if (max == gf) {
      hue = 60 * ((bf - rf) / delta + 2);
    } else {
      return false;
    }
    return hue >= 25 && hue <= 70;
  }
}
