import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../controller/plate_reader_controller.dart';
import '../exceptions/plate_reader_exception.dart';
import '../models/ocr_frame.dart';
import '../models/plate_area.dart';
import '../models/plate_record.dart';
import '../parsing/ethiopian_region.dart';
import '../parsing/plate_service_type.dart';
import '../recognition/plate_camera_preview.dart';
import 'plate_scanner_options.dart';
import 'plate_scanner_strings.dart';

/// Overlay builder for host chrome above the camera preview.
typedef PlateScannerOverlayBuilder = Widget Function(
  BuildContext context,
  PlateReaderController controller,
);

/// Embeddable plate scanning view.
///
/// Mounts the native camera preview and a default (or host) overlay driven
/// by [controller]. Requests camera permission and starts a session when
/// [autoStartSession] is true.
class PlateScannerView extends StatefulWidget {
  /// Creates a [PlateScannerView].
  const PlateScannerView({
    super.key,
    required this.controller,
    this.overlayBuilder,
    this.onPlateConfirmed,
    this.onCancel,
    this.onError,
    this.autoStartSession = true,
    this.initialLocation,
    this.strings,
    this.theme,
    this.options = const PlateScannerOptions(),
  });

  /// Session controller shared with the host.
  final PlateReaderController controller;

  /// Optional host chrome; when null, the package default HUD is used.
  final PlateScannerOverlayBuilder? overlayBuilder;

  /// Called after a successful [PlateReaderController.confirm].
  final ValueChanged<PlateRecord>? onPlateConfirmed;

  /// Called when the user closes the default overlay.
  final VoidCallback? onCancel;

  /// Called for init failures and surfaced platform errors.
  final ValueChanged<Object>? onError;

  /// When true, calls [PlateReaderController.startSession] after init.
  final bool autoStartSession;

  /// Optional GPS passed into [PlateReaderController.startSession].
  final PlateLocation? initialLocation;

  /// Texts; built-in English or Amharic (by locale) when null.
  final PlateScannerStrings? strings;

  /// Colour overrides; the host app's theme otherwise.
  final PlateScannerTheme? theme;

  /// Which steps and controls to show.
  final PlateScannerOptions options;

  /// Guide box drawn over a preview of [size]: 86% wide, 2.2:1 (a single-row
  /// plate), slightly above centre. Only text inside it is read.
  static Rect guideRect(Size size) {
    final width = size.width * 0.86;
    final height = width / 2.2;
    final top = (size.height - height) / 2 * 0.8;
    return Rect.fromLTWH((size.width - width) / 2, top, width, height);
  }

  @override
  State<PlateScannerView> createState() => _PlateScannerViewState();
}

class _PlateScannerViewState extends State<PlateScannerView> {
  final GlobalKey _previewKey = GlobalKey();
  Object? _reportedError;
  bool _bootstrapCancelled = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  @override
  void didUpdateWidget(covariant PlateScannerView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
      _reportedError = widget.controller.error;
    }
  }

  Future<void> _bootstrap() async {
    try {
      await widget.controller.initialize();
      if (_bootstrapCancelled || !mounted) return;
      if (widget.autoStartSession && !widget.controller.hasActiveSession) {
        await widget.controller.startSession(
          location: widget.initialLocation,
        );
      }
    } catch (e) {
      if (!_bootstrapCancelled) widget.onError?.call(e);
    }
  }

  void _onControllerChanged() {
    final err = widget.controller.error;
    if (err != null && err != _reportedError) {
      _reportedError = err;
      // Init failures are reported once by _bootstrap.
      if (widget.controller.isSupported) widget.onError?.call(err);
    }
    _autoSteps();
    if (mounted) setState(() {});
  }

  bool _autoPending = false;

  /// Steps the host turned off (or that aren't needed) run on their own:
  /// confirming an area that snapped to the plate, and Done on a valid
  /// reading without review.
  void _autoSteps() {
    final c = widget.controller;
    final o = widget.options;
    if (_autoPending) return;
    VoidCallback? step;
    if (c.phase == ScanPhase.confirmingArea) {
      final skip = switch (o.confirmArea) {
        ConfirmAreaMode.never => true,
        ConfirmAreaMode.always => false,
        ConfirmAreaMode.auto => !c.isSnappingArea && c.areaSnapped,
      };
      if (skip) step = c.confirmArea;
    } else if (c.phase == ScanPhase.review && !o.showReview && c.canConfirm) {
      step = _confirm;
    }
    if (step == null) return;
    // Not from inside the controller's notification.
    _autoPending = true;
    final run = step;
    scheduleMicrotask(() {
      _autoPending = false;
      if (mounted) run();
    });
  }

  Future<void> _confirm() async {
    try {
      final record = await widget.controller.confirm();
      widget.onPlateConfirmed?.call(record);
    } catch (e) {
      widget.onError?.call(e);
    }
  }

  @override
  void dispose() {
    _bootstrapCancelled = true;
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final strings = widget.strings ?? PlateScannerStrings.of(context);
    final colors = ResolvedPlateScannerTheme.of(context, widget.theme);
    final showUnsupported = !controller.isSupported &&
        controller.error != null &&
        !controller.isLoading;
    // While the area snaps after an automatic capture, don't show the
    // confirm step only to skip it a moment later.
    final hideConfirm = controller.phase == ScanPhase.confirmingArea &&
        widget.options.confirmArea == ConfirmAreaMode.auto &&
        controller.isSnappingArea;
    final frame = controller.capturedFrame;
    final frozen = frame != null &&
        const {
          ScanPhase.confirmingArea,
          ScanPhase.reading,
          ScanPhase.review,
          ScanPhase.confirmed,
        }.contains(controller.phase);
    final focused = frozen &&
        controller.phase != ScanPhase.confirmingArea &&
        controller.plateArea != null;

    return _Scope(
      strings: strings,
      colors: colors,
      options: widget.options,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          final guide = PlateScannerView.guideRect(size);
          // Search only inside the drawn box. The preview fills this widget,
          // so view-normalized = preview-normalized coordinates.
          if (size.width > 0 && size.height > 0) {
            controller.regionOfInterest = NormalizedRect(
              guide.left / size.width,
              guide.top / size.height,
              guide.right / size.width,
              guide.bottom / size.height,
            );
          }

          return Stack(
            fit: StackFit.expand,
            children: [
              const ColoredBox(color: Colors.black),
              if (controller.isSupported)
                PlateCameraPreview(
                  key: _previewKey,
                  service: controller.service,
                ),
              // Adjusting the area: the whole still, which covers exactly the
              // visible preview, so normalized coordinates stay aligned.
              if (frozen && !focused)
                Image.file(
                  File(frame.path),
                  fit: BoxFit.fill,
                  gaplessPlayback: true,
                  // A missing or unreadable photo leaves the area empty.
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              // Reading and review: only the plate, enlarged, on black.
              if (focused) ...[
                const ColoredBox(color: Colors.black),
                Align(
                  alignment: const Alignment(0, -0.5),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: ConstrainedBox(
                      constraints:
                          BoxConstraints(maxHeight: size.height * 0.24),
                      child: _PlateFocus(
                        frame: frame,
                        area: controller.plateArea!,
                        sections: const <PlateSection>[],
                      ),
                    ),
                  ),
                ),
              ],
              if (controller.isLoading)
                const Center(
                  child: SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: Colors.white70,
                    ),
                  ),
                ),
              if (showUnsupported)
                controller.errorCode == PlateReaderErrorCode.permissionDenied
                    ? _MessagePanel(
                        title: strings.permissionTitle,
                        message: strings.permissionMessage,
                        onClose: widget.onCancel,
                        actions: [
                          FilledButton(
                            onPressed: openAppSettings,
                            style: FilledButton.styleFrom(
                              backgroundColor: colors.accent,
                              foregroundColor: colors.onAccent,
                            ),
                            child: Text(strings.openSettings),
                          ),
                          TextButton(
                            onPressed: _bootstrap,
                            child: Text(strings.tryAgain),
                          ),
                        ],
                      )
                    : _MessagePanel(
                        message: controller.errorCode ==
                                PlateReaderErrorCode.unsupportedDevice
                            ? strings.unsupportedDevice
                            : controller.error!,
                        onClose: widget.onCancel,
                      )
              else if (controller.isSupported) ...[
                if (controller.phase == ScanPhase.detecting)
                  _DetectionLayer(guide: guide, controller: controller)
                else if (frozen &&
                    !focused &&
                    !hideConfirm &&
                    controller.plateArea != null)
                  _AreaLayer(controller: controller, size: size),
                if (widget.overlayBuilder != null)
                  widget.overlayBuilder!(context, controller)
                else
                  _DefaultOverlay(
                    controller: controller,
                    hideConfirm: hideConfirm,
                    onConfirm: _confirm,
                    onClose: () async {
                      await controller.cancelSession();
                      widget.onCancel?.call();
                    },
                  ),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// Strings, colours and options for the scanner's parts.
class _Scope extends InheritedWidget {
  const _Scope({
    required this.strings,
    required this.colors,
    required this.options,
    required super.child,
  });

  final PlateScannerStrings strings;
  final ResolvedPlateScannerTheme colors;
  final PlateScannerOptions options;

  static _Scope of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_Scope>()!;

  /// [PlateScannerOptions.allowEdit], without depending (e.g. initState).
  static bool allowEditOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_Scope>()?.options.allowEdit ??
      true;

  @override
  bool updateShouldNotify(_Scope old) =>
      old.strings != strings || old.colors != colors || old.options != options;
}

const _dim = Color(0x8C000000);

Rect _toView(NormalizedRect r, Size size) => Rect.fromLTRB(
      r.left * size.width,
      r.top * size.height,
      r.right * size.width,
      r.bottom * size.height,
    );

/// Step 1: the guide frame — corner marks over a dimmed preview, in the
/// accent colour once a plate is found.
class _DetectionLayer extends StatelessWidget {
  const _DetectionLayer({required this.guide, required this.controller});

  final Rect guide;
  final PlateReaderController controller;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        size: Size.infinite,
        painter: _DetectionPainter(
          guide: guide,
          color: controller.detectedArea != null
              ? _Scope.of(context).colors.accent
              : Colors.white,
        ),
      ),
    );
  }
}

class _DetectionPainter extends CustomPainter {
  _DetectionPainter({required this.guide, required this.color});

  final Rect guide;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const radius = 18.0;
    canvas.drawPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(Offset.zero & size)
        ..addRRect(
            RRect.fromRectAndRadius(guide, const Radius.circular(radius))),
      Paint()..color = _dim,
    );
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    final arm = guide.shortestSide * 0.18;
    final r = guide;
    for (final (corner, dx, dy) in [
      (r.topLeft, 1.0, 1.0),
      (r.topRight, -1.0, 1.0),
      (r.bottomLeft, 1.0, -1.0),
      (r.bottomRight, -1.0, -1.0),
    ]) {
      canvas.drawPath(
        Path()
          ..moveTo(corner.dx, corner.dy + dy * arm)
          ..lineTo(corner.dx, corner.dy + dy * radius)
          ..arcToPoint(
            Offset(corner.dx + dx * radius, corner.dy),
            radius: const Radius.circular(radius),
            clockwise: dx * dy > 0,
          )
          ..lineTo(corner.dx + dx * arm, corner.dy),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_DetectionPainter old) =>
      old.guide != guide || old.color != color;
}

/// Steps 2–4 on the frozen frame: the plate area (draggable while
/// confirming) and, in review, a box around each arranged segment.
class _AreaLayer extends StatelessWidget {
  const _AreaLayer({required this.controller, required this.size});

  final PlateReaderController controller;
  final Size size;

  @override
  Widget build(BuildContext context) {
    final area = _toView(controller.plateArea!, size);
    final editing = controller.phase == ScanPhase.confirmingArea;
    final colors = _Scope.of(context).colors;
    final sections = controller.phase == ScanPhase.review
        ? controller.arrangement?.sections ?? const <PlateSection>[]
        : const <PlateSection>[];
    return Stack(
      fit: StackFit.expand,
      children: [
        IgnorePointer(
          child: CustomPaint(
            painter: _AreaPainter(
              area: area,
              color: editing ? colors.accent : colors.confirmed,
              colors: colors,
              sections: [
                for (final s in sections)
                  if (s.box != null)
                    (
                      Rect.fromLTRB(
                        area.left + s.box!.left * area.width,
                        area.top + s.box!.top * area.height,
                        area.left + s.box!.right * area.width,
                        area.top + s.box!.bottom * area.height,
                      ),
                      s.kind,
                    ),
              ],
            ),
          ),
        ),
        if (editing)
          _AreaEditor(
            area: area,
            color: colors.accent,
            onChanged: (r) => controller.adjustArea(
              NormalizedRect(
                r.left / size.width,
                r.top / size.height,
                r.right / size.width,
                r.bottom / size.height,
              ),
            ),
          ),
      ],
    );
  }
}

class _AreaPainter extends CustomPainter {
  _AreaPainter({
    required this.area,
    required this.color,
    required this.colors,
    required this.sections,
  });

  final Rect area;
  final Color color;
  final ResolvedPlateScannerTheme colors;
  final List<(Rect, PlateSectionKind)> sections;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(Offset.zero & size)
        ..addRect(area),
      Paint()..color = _dim,
    );
    canvas.drawRect(
      area,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
    for (final (rect, kind) in sections) {
      final c = colors.section(kind);
      canvas.drawRect(
        rect.inflate(2),
        Paint()
          ..color = c
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
      // Section number above its box: 1 code, 2 Ge'ez, 3 number, 4 region.
      final tp = TextPainter(
        text: TextSpan(
          text: '${kind.index + 1}',
          style: TextStyle(
            color: Colors.black,
            backgroundColor: c,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(rect.left, rect.top - tp.height - 4));
    }
  }

  @override
  bool shouldRepaint(_AreaPainter old) =>
      old.area != area || old.color != color || old.sections != sections;
}

/// The confirmed plate area alone, cropped from the still and enlarged,
/// with each section's box drawn on it.
class _PlateFocus extends StatelessWidget {
  const _PlateFocus({
    required this.frame,
    required this.area,
    required this.sections,
  });

  final CapturedFrame frame;
  final NormalizedRect area;
  final List<PlateSection> sections;

  @override
  Widget build(BuildContext context) {
    final pxW = area.width * frame.width;
    final pxH = area.height * frame.height;
    final aspect = pxW > 0 && pxH > 0 ? pxW / pxH : 3.0;
    return AspectRatio(
      aspectRatio: aspect,
      child: LayoutBuilder(
        builder: (context, c) {
          final w = c.maxWidth;
          final h = c.maxHeight;
          // The whole still scaled so that the area fills this box.
          final fullW = w / area.width;
          final fullH = h / area.height;
          return ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Positioned(
                  left: -area.left * fullW,
                  top: -area.top * fullH,
                  width: fullW,
                  height: fullH,
                  child: Image.file(
                    File(frame.path),
                    fit: BoxFit.fill,
                    gaplessPlayback: true,
                    // A missing or unreadable photo leaves the area empty.
                    errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                  ),
                ),
                IgnorePointer(
                  child: CustomPaint(
                    painter: _SectionPainter(_Scope.of(context).colors, [
                      for (final s in sections)
                        if (s.box != null)
                          (
                            Rect.fromLTRB(
                              s.box!.left * w,
                              s.box!.top * h,
                              s.box!.right * w,
                              s.box!.bottom * h,
                            ),
                            s.kind,
                          ),
                    ]),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _SectionPainter extends CustomPainter {
  _SectionPainter(this.colors, this.sections);

  final ResolvedPlateScannerTheme colors;
  final List<(Rect, PlateSectionKind)> sections;

  @override
  void paint(Canvas canvas, Size size) {
    for (final (rect, kind) in sections) {
      final c = colors.section(kind);
      final r = rect.intersect(Offset.zero & size).deflate(1);
      canvas.drawRect(
        r,
        Paint()
          ..color = c
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
      final tp = TextPainter(
        text: TextSpan(
          text: ' ${kind.index + 1} ',
          style: TextStyle(
            color: Colors.black,
            backgroundColor: c,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, r.topLeft);
    }
  }

  @override
  bool shouldRepaint(_SectionPainter old) => old.sections != sections;
}

/// Drag the body to move the area, a corner handle to resize it.
class _AreaEditor extends StatelessWidget {
  const _AreaEditor({
    required this.area,
    required this.color,
    required this.onChanged,
  });

  final Rect area;
  final Color color;
  final ValueChanged<Rect> onChanged;

  static const _handle = 36.0;

  @override
  Widget build(BuildContext context) {
    Widget corner(Alignment a, Rect Function(Offset d) resize) {
      final x = a.x < 0 ? area.left : area.right;
      final y = a.y < 0 ? area.top : area.bottom;
      return Positioned(
        left: x - _handle / 2,
        top: y - _handle / 2,
        width: _handle,
        height: _handle,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanUpdate: (d) => onChanged(resize(d.delta)),
          child: Center(
            child: Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.black54, width: 2),
              ),
            ),
          ),
        ),
      );
    }

    return Stack(
      children: [
        Positioned.fromRect(
          rect: area,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onPanUpdate: (d) => onChanged(area.shift(d.delta)),
          ),
        ),
        corner(
          Alignment.topLeft,
          (d) => Rect.fromLTRB(
              area.left + d.dx, area.top + d.dy, area.right, area.bottom),
        ),
        corner(
          Alignment.topRight,
          (d) => Rect.fromLTRB(
              area.left, area.top + d.dy, area.right + d.dx, area.bottom),
        ),
        corner(
          Alignment.bottomLeft,
          (d) => Rect.fromLTRB(
              area.left + d.dx, area.top, area.right, area.bottom + d.dy),
        ),
        corner(
          Alignment.bottomRight,
          (d) => Rect.fromLTRB(
              area.left, area.top, area.right + d.dx, area.bottom + d.dy),
        ),
      ],
    );
  }
}

class _DefaultOverlay extends StatelessWidget {
  const _DefaultOverlay({
    required this.controller,
    required this.hideConfirm,
    required this.onConfirm,
    required this.onClose,
  });

  final PlateReaderController controller;
  final bool hideConfirm;
  final VoidCallback onConfirm;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final scope = _Scope.of(context);
    final strings = scope.strings;

    final Widget bottom = switch (c.phase) {
      ScanPhase.detecting => _ShutterBar(controller: c),
      ScanPhase.confirmingArea when !hideConfirm =>
        _ConfirmAreaPanel(controller: c),
      ScanPhase.confirmingArea ||
      ScanPhase.reading =>
        _Pill(text: strings.reading, busy: true),
      ScanPhase.review => _ResultSheet(controller: c, onDone: onConfirm),
      ScanPhase.error => _ErrorPanel(controller: c),
      _ => const SizedBox.shrink(),
    };

    return Stack(
      children: [
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                _HudIconButton(
                  icon: Icons.close,
                  tooltip: strings.close,
                  onPressed: onClose,
                ),
                const Spacer(),
                if (c.phase == ScanPhase.detecting && scope.options.showTorch)
                  _HudIconButton(
                    icon: c.torchOn
                        ? Icons.flashlight_on_rounded
                        : Icons.flashlight_off_rounded,
                    tooltip: strings.torch,
                    onPressed: c.toggleTorch,
                  ),
              ],
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            child: KeyedSubtree(key: ValueKey(c.phase), child: bottom),
          ),
        ),
      ],
    );
  }
}

const _hint = TextStyle(color: Colors.white, fontSize: 15, height: 1.3);

/// A short message in a translucent pill, optionally with a spinner.
class _Pill extends StatelessWidget {
  const _Pill({required this.text, this.busy = false});

  final String text;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 40),
        child: Center(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0x99000000),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (busy) ...[
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(width: 10),
                  ],
                  Text(text, style: _hint),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Step 1: one hint and the shutter.
class _ShutterBar extends StatelessWidget {
  const _ShutterBar({required this.controller});

  final PlateReaderController controller;

  @override
  Widget build(BuildContext context) {
    final scope = _Scope.of(context);
    final found = controller.detectedArea != null;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              found ? scope.strings.plateFound : scope.strings.fitPlate,
              textAlign: TextAlign.center,
              style: _hint.copyWith(
                shadows: const [Shadow(blurRadius: 6, color: Colors.black54)],
              ),
            ),
            const SizedBox(height: 22),
            Semantics(
              button: true,
              label: scope.strings.capture,
              child: GestureDetector(
                onTap: controller.captureArea,
                child: Container(
                  width: 76,
                  height: 76,
                  padding: const EdgeInsets.all(5),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: found ? scope.colors.accent : Colors.white,
                      width: 4,
                    ),
                  ),
                  child: const DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Optional step: confirm the plate area (host chose `always`, or the area
/// couldn't be snapped).
class _ConfirmAreaPanel extends StatelessWidget {
  const _ConfirmAreaPanel({required this.controller});

  final PlateReaderController controller;

  @override
  Widget build(BuildContext context) {
    final scope = _Scope.of(context);
    return _Sheet(
      children: [
        Text(
          scope.strings.confirmAreaHint,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: controller.retake,
                style: _outlined(),
                child: Text(scope.strings.retake),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                onPressed: controller.confirmArea,
                style: _filled(scope.colors),
                child: Text(scope.strings.confirmArea),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// A bottom sheet in the host app's surface colours.
class _Sheet extends StatelessWidget {
  const _Sheet({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      surfaceTintColor: scheme.surfaceTint,
      elevation: 6,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: scheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}

/// The result: the plate number, one line of detail, edit, Done / Retake.
class _ResultSheet extends StatefulWidget {
  const _ResultSheet({required this.controller, required this.onDone});

  final PlateReaderController controller;
  final VoidCallback onDone;

  @override
  State<_ResultSheet> createState() => _ResultSheetState();
}

class _ResultSheetState extends State<_ResultSheet> {
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    // Nothing usable read: go straight to typing it.
    final c = widget.controller;
    _editing = _Scope.allowEditOf(context) && c.draftSerial == null;
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final scope = _Scope.of(context);
    final strings = scope.strings;
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final issues = c.draftIssues;
    // Only what blocks Done is shown, e.g. "Number not read".
    final detail = issues.map(strings.issue).join(' · ');

    return _Sheet(
      children: [
        if (_editing)
          _EditForm(
            controller: c,
            onDone: () => setState(() => _editing = false),
          )
        else ...[
          Row(
            children: [
              Expanded(
                child: Center(
                  child: _PlateChip(
                    code: c.draftCode,
                    region: c.draftRegionCode,
                    serial: c.draftSerial,
                  ),
                ),
              ),
              if (scope.options.allowEdit)
                IconButton.filledTonal(
                  onPressed: () => setState(() => _editing = true),
                  icon: const Icon(Icons.edit_rounded),
                  tooltip: strings.edit,
                ),
            ],
          ),
          if (detail.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(color: scheme.error),
            ),
          ],
        ],
        const SizedBox(height: 20),
        FilledButton(
          onPressed: c.canConfirm ? widget.onDone : null,
          style: _filled(scope.colors),
          child: Text(strings.done),
        ),
        const SizedBox(height: 6),
        TextButton(
          onPressed: c.retake,
          style: TextButton.styleFrom(minimumSize: const Size.fromHeight(44)),
          child: Text(strings.retake),
        ),
      ],
    );
  }
}

/// The reading drawn like a small plate: code, number, region.
class _PlateChip extends StatelessWidget {
  const _PlateChip({this.code, this.region, this.serial});

  final String? code, region, serial;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ink = scheme.onSurface;
    final numeric = code != null && int.tryParse(code!) != null;
    final label = PlateServiceType.fromCode(code)?.amharicLabel ?? code;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (code != null) ...[
              numeric
                  ? Container(
                      width: 30,
                      height: 30,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: ink, width: 2),
                      ),
                      child: Text(
                        code!,
                        style: TextStyle(
                          color: ink,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    )
                  : Text(
                      label!,
                      style: TextStyle(
                        color: ink,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
              const SizedBox(width: 12),
            ],
            Text(
              serial ?? '—',
              style: TextStyle(
                color: ink,
                fontSize: 30,
                fontWeight: FontWeight.w800,
                letterSpacing: 2,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            if (region != null) ...[
              const SizedBox(width: 12),
              Text(
                region!,
                style: TextStyle(
                  color: ink,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Correct the reading: code, region, number.
class _EditForm extends StatefulWidget {
  const _EditForm({required this.controller, required this.onDone});

  final PlateReaderController controller;
  final VoidCallback onDone;

  @override
  State<_EditForm> createState() => _EditFormState();
}

class _EditFormState extends State<_EditForm> {
  late final TextEditingController _serial = TextEditingController(
    text: widget.controller.draftSerial ?? '',
  );

  @override
  void dispose() {
    _serial.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final strings = _Scope.of(context).strings;
    final codes = PlateServiceType.values.map((t) => t.code).toList();
    final code = codes.contains(c.draftCode) ? c.draftCode : null;
    final region = EthiopianRegion.fromCode(c.draftRegionCode);
    InputDecoration field(String label) => InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
        );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _serial,
          autofocus: c.draftSerial == null,
          textCapitalization: TextCapitalization.characters,
          style: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            letterSpacing: 2,
          ),
          decoration: field(strings.fieldSerial),
          onChanged: (v) => c.editField(serial: v),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: code,
                isExpanded: true,
                decoration: field(strings.fieldCode),
                items: [
                  for (final t in PlateServiceType.values)
                    DropdownMenuItem(
                      value: t.code,
                      child: Text(
                        int.tryParse(t.code) != null
                            ? '${t.code} · ${t.label}'
                            : t.label,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (v) => c.editField(code: v),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: DropdownButtonFormField<EthiopianRegion>(
                initialValue: region,
                isExpanded: true,
                decoration: field(strings.fieldRegion),
                items: [
                  for (final r in EthiopianRegion.values)
                    DropdownMenuItem(
                      value: r,
                      child: Text(
                        '${r.code} · ${r.englishName}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (v) => c.editField(regionCode: v?.code),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: widget.onDone,
            icon: const Icon(Icons.check_rounded),
            label: Text(strings.save),
          ),
        ),
      ],
    );
  }
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.controller});

  final PlateReaderController controller;

  @override
  Widget build(BuildContext context) {
    return _Card(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            controller.error ?? _Scope.of(context).strings.somethingWentWrong,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70),
          ),
          TextButton(
            onPressed: controller.retake,
            child: Text(_Scope.of(context).strings.tryAgain),
          ),
        ],
      ),
    );
  }
}

class _MessagePanel extends StatelessWidget {
  const _MessagePanel({
    required this.message,
    this.title,
    this.onClose,
    this.actions = const [],
  });

  final String? title;
  final String message;
  final VoidCallback? onClose;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final strings = _Scope.of(context).strings;
    return ColoredBox(
      color: const Color(0xEE111111),
      child: SafeArea(
        child: Stack(
          children: [
            if (onClose != null)
              Positioned(
                top: 8,
                left: 8,
                child: _HudIconButton(
                  icon: Icons.close,
                  tooltip: strings.close,
                  onPressed: onClose!,
                ),
              ),
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (title != null) ...[
                      Text(
                        title!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                    Text(
                      message,
                      textAlign: TextAlign.center,
                      style:
                          const TextStyle(color: Colors.white70, fontSize: 15),
                    ),
                    if (actions.isNotEmpty) ...[
                      const SizedBox(height: 20),
                      Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        alignment: WrapAlignment.center,
                        children: actions,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: _Scope.of(context).colors.panel,
      borderRadius: BorderRadius.circular(16),
      child: Padding(padding: const EdgeInsets.all(16), child: child),
    );
  }
}

class _HudIconButton extends StatelessWidget {
  const _HudIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0x88000000),
      shape: const CircleBorder(),
      child: IconButton(
        icon: Icon(icon, color: Colors.white),
        tooltip: tooltip,
        onPressed: onPressed,
      ),
    );
  }
}

/// Filled button in the scanner's accent colour.
ButtonStyle _filled(ResolvedPlateScannerTheme colors) => FilledButton.styleFrom(
      backgroundColor: colors.accent,
      foregroundColor: colors.onAccent,
      minimumSize: const Size.fromHeight(52),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    );

/// Outlined button on the result sheet.
ButtonStyle _outlined() =>
    OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52));
