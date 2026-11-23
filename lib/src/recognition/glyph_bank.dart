import 'dart:convert';
import 'dart:typed_data';

// Pure Dart — no Flutter imports, so `dart run tool/build_glyph_bank.dart`
// can compile without pulling dart:ui / the Flutter framework.

/// Fixed mask size for every prototype and live crop (width × height).
/// Prototype / crop width in pixels.
const glyphWidth = 32;

/// Prototype / crop height in pixels.
const glyphHeight = 48;

/// [glyphWidth] × [glyphHeight].
const glyphLength = glyphWidth * glyphHeight;

/// One labelled ink-mask prototype (row-major, values 0.0–1.0 = ink).
class GlyphPrototype {
  /// Creates a prototype.
  const GlyphPrototype(this.label, this.mask);

  /// Character class (`0`–`9`, `A`–`Z`).
  final String label;

  /// Length [glyphLength]; 1 = ink, 0 = background.
  final Float32List mask;

  /// Serialises for [GlyphBank.toJson].
  Map<String, Object> toJson() => {
        'label': label,
        'mask': [for (final v in mask) (v * 255).round().clamp(0, 255)],
      };

  /// Deserialises from JSON bytes 0–255.
  factory GlyphPrototype.fromJson(Map<String, dynamic> json) {
    final raw = (json['mask'] as List).cast<num>();
    final mask = Float32List(glyphLength);
    for (var i = 0; i < glyphLength && i < raw.length; i++) {
      mask[i] = raw[i].toDouble() / 255.0;
    }
    return GlyphPrototype(json['label'] as String, mask);
  }
}

/// Bundled (or in-memory) set of glyph prototypes for [GlyphClassifier].
class GlyphBank {
  /// Creates a bank.
  GlyphBank(this.prototypes);

  /// Every prototype, usually several per label.
  final List<GlyphPrototype> prototypes;

  /// Labels present in the bank.
  Set<String> get labels => {for (final p in prototypes) p.label};

  /// Mean mask per label (centroid), for faster scoring.
  Map<String, Float32List> get centroids {
    final sums = <String, Float32List>{};
    final counts = <String, int>{};
    for (final p in prototypes) {
      final s = sums.putIfAbsent(p.label, () => Float32List(glyphLength));
      counts[p.label] = (counts[p.label] ?? 0) + 1;
      for (var i = 0; i < glyphLength; i++) {
        s[i] += p.mask[i];
      }
    }
    final out = <String, Float32List>{};
    for (final e in sums.entries) {
      final n = counts[e.key]!;
      final c = Float32List(glyphLength);
      for (var i = 0; i < glyphLength; i++) {
        c[i] = e.value[i] / n;
      }
      out[e.key] = c;
    }
    return out;
  }

  /// Serialises the bank for `assets/glyphs/bank.json`.
  Map<String, Object> toJson() => {
        'width': glyphWidth,
        'height': glyphHeight,
        'prototypes': [for (final p in prototypes) p.toJson()],
      };

  /// Deserialises a bank written by [toJson] / `tool/build_glyph_bank.dart`.
  factory GlyphBank.fromJson(Map<String, dynamic> json) {
    final list = (json['prototypes'] as List).cast<Map<String, dynamic>>();
    return GlyphBank([for (final m in list) GlyphPrototype.fromJson(m)]);
  }

  /// Parses a bank JSON string (tests / tools).
  static GlyphBank fromJsonString(String raw) =>
      GlyphBank.fromJson(jsonDecode(raw) as Map<String, dynamic>);
}

/// Builds a complete charset of hand-drawn stencil-like masks so the
/// classifier works before any fixture harvest.
List<GlyphPrototype> buildSyntheticPrototypes() {
  final out = <GlyphPrototype>[];
  for (final d in '0123456789'.split('')) {
    out.add(GlyphPrototype(d, _drawDigit(d)));
    out.add(GlyphPrototype(d, _drawDigit(d, thick: true)));
    out.add(GlyphPrototype(d, _shift(_drawDigit(d), 1, 0)));
    out.add(GlyphPrototype(d, _shift(_drawDigit(d), -1, 1)));
  }
  for (final l in 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'.split('')) {
    out.add(GlyphPrototype(l, _drawLetter(l)));
    out.add(GlyphPrototype(l, _drawLetter(l, thick: true)));
    out.add(GlyphPrototype(l, _shift(_drawLetter(l), 0, 1)));
  }
  return out;
}

Float32List _blank() => Float32List(glyphLength);

void _ink(Float32List m, int x, int y, {int w = 1, int h = 1}) {
  for (var yy = y; yy < y + h && yy < glyphHeight; yy++) {
    if (yy < 0) continue;
    for (var xx = x; xx < x + w && xx < glyphWidth; xx++) {
      if (xx < 0) continue;
      m[yy * glyphWidth + xx] = 1;
    }
  }
}

Float32List _shift(Float32List src, int dx, int dy) {
  final out = _blank();
  for (var y = 0; y < glyphHeight; y++) {
    for (var x = 0; x < glyphWidth; x++) {
      final v = src[y * glyphWidth + x];
      if (v == 0) continue;
      final nx = x + dx, ny = y + dy;
      if (nx >= 0 && nx < glyphWidth && ny >= 0 && ny < glyphHeight) {
        out[ny * glyphWidth + nx] = v;
      }
    }
  }
  return out;
}

/// Stencil digit in a 6×10 cell grid mapped onto the glyph canvas.
Float32List _drawDigit(String d, {bool thick = false}) {
  final m = _blank();
  final t = thick ? 3 : 2;
  // 7-segment style: a top, b UR, c LR, d bottom, e LL, f UL, g mid.
  const segs = {
    '0': 'abcdef',
    '1': 'bc',
    '2': 'abged',
    '3': 'abgcd',
    '4': 'fgbc',
    '5': 'afgcd',
    '6': 'afgcde',
    '7': 'abc',
    '8': 'abcdefg',
    '9': 'abcdfg',
  };
  final s = segs[d] ?? '';
  void horiz(int y) => _ink(m, 8, y, w: 16, h: t);
  void vert(int x, int y0, int y1) => _ink(m, x, y0, w: t, h: y1 - y0);
  if (s.contains('a')) horiz(4);
  if (s.contains('g')) horiz(22);
  if (s.contains('d')) horiz(40);
  if (s.contains('f')) vert(8, 4, 22);
  if (s.contains('b')) vert(22, 4, 22);
  if (s.contains('e')) vert(8, 22, 40);
  if (s.contains('c')) vert(22, 22, 40);
  // Stencil notch on 0 (Ethiopian plate 0).
  if (d == '0') {
    _ink(m, 14, 20, w: 4, h: 4);
    for (var i = 14; i < 18; i++) {
      for (var j = 20; j < 24; j++) {
        m[j * glyphWidth + i] = 0;
      }
    }
  }
  return m;
}

Float32List _drawLetter(String l, {bool thick = false}) {
  final m = _blank();
  final t = thick ? 3 : 2;
  void bar(int x, int y, int w, int h) => _ink(m, x, y, w: w, h: h);
  switch (l) {
    case 'A':
      bar(8, 6, t, 36);
      bar(22, 6, t, 36);
      bar(8, 6, 16, t);
      bar(8, 24, 16, t);
    case 'B':
      bar(8, 6, t, 36);
      bar(8, 6, 14, t);
      bar(8, 22, 14, t);
      bar(8, 40, 14, t);
      bar(20, 8, t, 12);
      bar(20, 26, t, 12);
    case 'C':
      bar(8, 6, t, 36);
      bar(8, 6, 16, t);
      bar(8, 40, 16, t);
    case 'D':
      bar(8, 6, t, 36);
      bar(8, 6, 12, t);
      bar(8, 40, 12, t);
      bar(20, 10, t, 28);
    case 'E':
      bar(8, 6, t, 36);
      bar(8, 6, 16, t);
      bar(8, 22, 12, t);
      bar(8, 40, 16, t);
    case 'F':
      bar(8, 6, t, 36);
      bar(8, 6, 16, t);
      bar(8, 22, 12, t);
    case 'G':
      bar(8, 6, t, 36);
      bar(8, 6, 16, t);
      bar(8, 40, 16, t);
      bar(18, 24, 8, t);
      bar(22, 24, t, 16);
    case 'H':
      bar(8, 6, t, 36);
      bar(22, 6, t, 36);
      bar(8, 22, 16, t);
    case 'I':
      bar(14, 6, t, 36);
      bar(10, 6, 10, t);
      bar(10, 40, 10, t);
    case 'J':
      bar(20, 6, t, 30);
      bar(8, 32, t, 10);
      bar(8, 40, 14, t);
    case 'K':
      bar(8, 6, t, 36);
      bar(8, 22, 8, t);
      for (var i = 0; i < 14; i++) {
        bar(16 + i ~/ 2, 22 - i, t, t);
        bar(16 + i ~/ 2, 22 + i, t, t);
      }
    case 'L':
      bar(8, 6, t, 36);
      bar(8, 40, 16, t);
    case 'M':
      bar(6, 6, t, 36);
      bar(24, 6, t, 36);
      for (var i = 0; i < 10; i++) {
        bar(6 + i, 6 + i, t, t);
        bar(24 - i, 6 + i, t, t);
      }
    case 'N':
      bar(8, 6, t, 36);
      bar(22, 6, t, 36);
      for (var i = 0; i < 16; i++) {
        bar(8 + i, 6 + i * 2, t, t);
      }
    case 'O':
      bar(8, 6, t, 36);
      bar(22, 6, t, 36);
      bar(8, 6, 16, t);
      bar(8, 40, 16, t);
    case 'P':
      bar(8, 6, t, 36);
      bar(8, 6, 14, t);
      bar(8, 22, 14, t);
      bar(20, 8, t, 12);
    case 'Q':
      bar(8, 6, t, 32);
      bar(22, 6, t, 32);
      bar(8, 6, 16, t);
      bar(8, 36, 16, t);
      bar(18, 32, 8, t);
    case 'R':
      bar(8, 6, t, 36);
      bar(8, 6, 14, t);
      bar(8, 22, 14, t);
      bar(20, 8, t, 12);
      for (var i = 0; i < 14; i++) {
        bar(14 + i ~/ 2, 22 + i, t, t);
      }
    case 'S':
      bar(8, 6, 16, t);
      bar(8, 6, t, 16);
      bar(8, 22, 16, t);
      bar(22, 22, t, 18);
      bar(8, 40, 16, t);
    case 'T':
      bar(8, 6, 16, t);
      bar(14, 6, t, 36);
    case 'U':
      bar(8, 6, t, 34);
      bar(22, 6, t, 34);
      bar(8, 40, 16, t);
    case 'V':
      for (var i = 0; i < 18; i++) {
        bar(8 + i ~/ 2, 6 + i * 2, t, t);
        bar(22 - i ~/ 2, 6 + i * 2, t, t);
      }
    case 'W':
      bar(6, 6, t, 36);
      bar(24, 6, t, 36);
      bar(15, 20, t, 22);
    case 'X':
      for (var i = 0; i < 20; i++) {
        bar(8 + i, 6 + i * 2, t, t);
        bar(22 - i, 6 + i * 2, t, t);
      }
    case 'Y':
      for (var i = 0; i < 10; i++) {
        bar(8 + i, 6 + i * 2, t, t);
        bar(22 - i, 6 + i * 2, t, t);
      }
      bar(14, 24, t, 18);
    case 'Z':
      bar(8, 6, 16, t);
      bar(8, 40, 16, t);
      for (var i = 0; i < 16; i++) {
        bar(22 - i, 6 + i * 2, t, t);
      }
    default:
      bar(10, 10, 12, 28);
  }
  return m;
}
