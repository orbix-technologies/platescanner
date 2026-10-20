import 'package:flutter/material.dart';

import '../models/plate_area.dart';

/// When the user is asked to confirm the plate area after capture.
enum ConfirmAreaMode {
  /// Only when the area could not be snapped to the plate's outline (the
  /// user then checks the box); otherwise reading starts right away.
  auto,

  /// Always.
  always,

  /// Never: reading starts right after capture.
  never,
}

/// Which steps and controls the scanner shows.
@immutable
class PlateScannerOptions {
  /// Creates options; the defaults give the shortest flow — photo, then the
  /// plate number to check or edit.
  const PlateScannerOptions({
    this.confirmArea = ConfirmAreaMode.never,
    this.showReview = true,
    this.allowEdit = true,
    this.showTorch = true,
    this.autoCapture = true,
  });

  /// When to ask the user to confirm the plate area.
  final ConfirmAreaMode confirmArea;

  /// Show the reading for a Done tap. When false, a valid reading is
  /// returned at once; one with problems (number not read, unknown code)
  /// is still shown, so a wrong plate is never returned unseen.
  final bool showReview;

  /// Let the user correct the reading in review.
  final bool allowEdit;

  /// Show the torch button while scanning.
  final bool showTorch;

  /// Capture on its own once the plate holds still (a Capture button is
  /// always shown too).
  final bool autoCapture;
}

/// Colour overrides. Anything left null follows the host app's theme:
/// [accent] is its `colorScheme.primary`. The camera screens stay dark.
@immutable
class PlateScannerTheme {
  /// Creates a theme.
  const PlateScannerTheme({
    this.accent,
    this.onAccent,
    this.confirmed,
    this.panel,
    this.sectionColors,
  });

  /// Buttons, the detected plate box and the plate area while confirming.
  final Color? accent;

  /// Text and icons on [accent].
  final Color? onAccent;

  /// The plate area once confirmed.
  final Color? confirmed;

  /// Background of the panels over the camera.
  final Color? panel;

  /// Colour of each plate section's box and label in review.
  final Map<PlateSectionKind, Color>? sectionColors;
}

/// [PlateScannerTheme] with every colour decided.
@immutable
class ResolvedPlateScannerTheme {
  /// Resolves [theme] against the host's [context] theme.
  factory ResolvedPlateScannerTheme.of(
      BuildContext context, PlateScannerTheme? theme) {
    final scheme = Theme.of(context).colorScheme;
    final accent = theme?.accent ?? scheme.primary;
    final onAccent = theme?.onAccent ??
        (theme?.accent == null
            ? scheme.onPrimary
            : ThemeData.estimateBrightnessForColor(accent) == Brightness.dark
                ? Colors.white
                : Colors.black);
    return ResolvedPlateScannerTheme._(
      accent: accent,
      onAccent: onAccent,
      confirmed: theme?.confirmed ?? const Color(0xFF4CAF50),
      panel: theme?.panel ?? const Color(0xD9111111),
      sections: {
        PlateSectionKind.code: const Color(0xFF64B5F6),
        PlateSectionKind.geezRegion: const Color(0xFFBA68C8),
        PlateSectionKind.number: const Color(0xFFFFD54F),
        PlateSectionKind.latinRegion: const Color(0xFF81C784),
        ...?theme?.sectionColors,
      },
    );
  }

  const ResolvedPlateScannerTheme._({
    required this.accent,
    required this.onAccent,
    required this.confirmed,
    required this.panel,
    required this.sections,
  });

  /// See [PlateScannerTheme].
  final Color accent, onAccent, confirmed, panel;

  /// Colour per section.
  final Map<PlateSectionKind, Color> sections;

  /// Colour of [kind].
  Color section(PlateSectionKind kind) => sections[kind]!;
}
