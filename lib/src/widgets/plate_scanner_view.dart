import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';

import '../controller/plate_reader_controller.dart';
import '../models/ocr_frame.dart';
import '../models/plate_area.dart';
import '../models/plate_record.dart';
import '../parsing/ethiopian_region.dart';
import '../parsing/plate_service_type.dart';
import '../recognition/plate_camera_preview.dart';

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
    if (mounted) setState(() {});
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
    final showUnsupported = !controller.isSupported &&
        controller.error != null &&
        !controller.isLoading;
    final frame = controller.capturedFrame;
    final frozen = frame != null &&
        const {
          ScanPhase.confirmingArea,
          ScanPhase.reading,
          ScanPhase.review,
          ScanPhase.confirmed,
        }.contains(controller.phase);

    return LayoutBuilder(
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
            // The captured still covers exactly the visible preview, so
            // filling the view keeps normalized coordinates aligned.
            if (frozen)
              Image.file(
                File(frame.path),
                fit: BoxFit.fill,
                gaplessPlayback: true,
              ),
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
              _MessagePanel(
                message: controller.error!,
                onClose: widget.onCancel,
              )
            else if (controller.isSupported) ...[
              if (controller.phase == ScanPhase.detecting)
                _DetectionLayer(guide: guide, controller: controller)
              else if (frozen && controller.plateArea != null)
                _AreaLayer(controller: controller, size: size),
              if (widget.overlayBuilder != null)
                widget.overlayBuilder!(context, controller)
              else
                _DefaultOverlay(
                  controller: controller,
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
    );
  }
}

const _accent = Color(0xFFF5C518);
const _good = Color(0xFF4CAF50);
const _dim = Color(0x8C000000);

Rect _toView(NormalizedRect r, Size size) => Rect.fromLTRB(
      r.left * size.width,
      r.top * size.height,
      r.right * size.width,
      r.bottom * size.height,
    );

/// Step 1: guide box (search area) with the live detected plate area.
class _DetectionLayer extends StatelessWidget {
  const _DetectionLayer({required this.guide, required this.controller});

  final Rect guide;
  final PlateReaderController controller;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, c) {
          final area = controller.detectedArea;
          return CustomPaint(
            size: c.biggest,
            painter: _DetectionPainter(
              guide: guide,
              detected: area == null ? null : _toView(area, c.biggest),
            ),
          );
        },
      ),
    );
  }
}

class _DetectionPainter extends CustomPainter {
  _DetectionPainter({required this.guide, required this.detected});

  final Rect guide;
  final Rect? detected;

  @override
  void paint(Canvas canvas, Size size) {
    final box = RRect.fromRectAndRadius(guide, const Radius.circular(14));
    canvas.drawPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(Offset.zero & size)
        ..addRRect(box),
      Paint()..color = _dim,
    );
    canvas.drawRRect(
      box,
      Paint()
        ..color = Colors.white70
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    final d = detected;
    if (d != null) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(d, const Radius.circular(6)),
        Paint()
          ..color = _accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3,
      );
    }
  }

  @override
  bool shouldRepaint(_DetectionPainter old) =>
      old.guide != guide || old.detected != detected;
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
              color: editing ? _accent : _good,
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

Color _sectionColor(PlateSectionKind kind) => switch (kind) {
      PlateSectionKind.code => const Color(0xFF64B5F6),
      PlateSectionKind.geezRegion => const Color(0xFFBA68C8),
      PlateSectionKind.number => _accent,
      PlateSectionKind.latinRegion => const Color(0xFF81C784),
    };

String _sectionLabel(PlateSectionKind kind) => switch (kind) {
      PlateSectionKind.code => 'Code',
      PlateSectionKind.geezRegion => "Region (Ge'ez)",
      PlateSectionKind.number => 'Number',
      PlateSectionKind.latinRegion => 'Region',
    };

class _AreaPainter extends CustomPainter {
  _AreaPainter({
    required this.area,
    required this.color,
    required this.sections,
  });

  final Rect area;
  final Color color;
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
      final c = _sectionColor(kind);
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

/// Drag the body to move the area, a corner handle to resize it.
class _AreaEditor extends StatelessWidget {
  const _AreaEditor({required this.area, required this.onChanged});

  final Rect area;
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
                color: _accent,
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

class _DefaultOverlay extends StatefulWidget {
  const _DefaultOverlay({
    required this.controller,
    required this.onConfirm,
    required this.onClose,
  });

  final PlateReaderController controller;
  final VoidCallback onConfirm;
  final VoidCallback onClose;

  @override
  State<_DefaultOverlay> createState() => _DefaultOverlayState();
}

class _DefaultOverlayState extends State<_DefaultOverlay> {
  bool _editing = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    if (c.phase != ScanPhase.review) _editing = false;

    final panel = switch (c.phase) {
      ScanPhase.detecting => _DetectingPanel(controller: c),
      ScanPhase.confirmingArea => _ConfirmAreaPanel(controller: c),
      ScanPhase.reading => const _Card(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white70,
                ),
              ),
              SizedBox(width: 12),
              Text(
                'Reading characters…',
                style: TextStyle(color: Colors.white70),
              ),
            ],
          ),
        ),
      ScanPhase.review => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_editing) ...[
              _EditPanel(controller: c),
              const SizedBox(height: 8),
            ],
            _ReviewPanel(
              controller: c,
              onDone: widget.onConfirm,
              onEdit: () => setState(() => _editing = !_editing),
            ),
          ],
        ),
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
                _HudIconButton(icon: Icons.close, onPressed: widget.onClose),
                const Spacer(),
                if (c.phase == ScanPhase.detecting)
                  _HudIconButton(
                    icon: c.torchOn ? Icons.flash_on : Icons.flash_off,
                    onPressed: c.toggleTorch,
                  ),
              ],
            ),
          ),
        ),
        Positioned(
          left: 16,
          right: 16,
          bottom: 16,
          child: SafeArea(top: false, child: panel),
        ),
      ],
    );
  }
}

String _issueText(PlateIssue issue) => switch (issue) {
      PlateIssue.missingCode => 'Code not read',
      PlateIssue.unknownCode => 'Unknown code',
      PlateIssue.missingRegion => 'Region not read',
      PlateIssue.missingSerial => 'Serial not read',
    };

const _hint = TextStyle(color: Colors.white70, fontSize: 14);

/// Step 1 controls.
class _DetectingPanel extends StatelessWidget {
  const _DetectingPanel({required this.controller});

  final PlateReaderController controller;

  @override
  Widget build(BuildContext context) {
    final found = controller.detectedArea != null;
    return _Card(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  found
                      ? 'Plate found — hold steady'
                      : 'Fit the plate inside the box',
                  style: _hint,
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: controller.captureArea,
                style: FilledButton.styleFrom(
                  backgroundColor: _accent,
                  foregroundColor: Colors.black,
                ),
                child: const Text('Capture'),
              ),
            ],
          ),
          if (found) ...[
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: controller.detectionProgress,
              color: _accent,
              backgroundColor: Colors.white12,
            ),
          ],
        ],
      ),
    );
  }
}

/// Step 2 controls.
class _ConfirmAreaPanel extends StatelessWidget {
  const _ConfirmAreaPanel({required this.controller});

  final PlateReaderController controller;

  @override
  Widget build(BuildContext context) {
    return _Card(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Is the whole plate inside the yellow box?\n'
            'Drag the box or its corners to adjust.',
            textAlign: TextAlign.center,
            style: _hint,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: controller.retake,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('Retake'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: controller.confirmArea,
                  style: FilledButton.styleFrom(
                    backgroundColor: _accent,
                    foregroundColor: Colors.black,
                  ),
                  child: const Text('Confirm area'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Step 4: the plate as arranged, its fields, and Done.
class _ReviewPanel extends StatelessWidget {
  const _ReviewPanel({
    required this.controller,
    required this.onDone,
    required this.onEdit,
  });

  final PlateReaderController controller;
  final VoidCallback onDone;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final issues = c.draftIssues;
    final region = EthiopianRegion.fromCode(c.draftRegionCode);

    return _Card(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The four sections as placed on the plate, with their characters.
          if (c.arrangement != null)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final section in c.arrangement!.sections)
                  Expanded(
                    flex: section.kind == PlateSectionKind.number ? 3 : 2,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: _SectionCard(section: section),
                    ),
                  ),
              ],
            ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        [
                          c.draftCode ?? '–',
                          c.draftRegionCode ?? '–',
                          c.draftSerial ?? '–',
                        ].join('  ·  '),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      issues.isNotEmpty
                          ? issues.map(_issueText).join(' · ')
                          : region == null
                              ? 'Plate read'
                              : '${region.amharicLabel} · ${region.englishName}',
                      style: TextStyle(
                        color: issues.isEmpty
                            ? Colors.white70
                            : Colors.orangeAccent,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: c.canConfirm ? onDone : null,
                style: FilledButton.styleFrom(
                  backgroundColor: _accent,
                  foregroundColor: Colors.black,
                  disabledBackgroundColor: Colors.white24,
                ),
                child: const Text('Done'),
              ),
            ],
          ),
          // Debug builds: what OCR actually read, to diagnose sections.
          if (kDebugMode && c.areaOcr != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'OCR: ${c.areaOcr!.text}'
                '${c.areaOcr!.codeHint == null ? '' : '  · code pass ${c.areaOcr!.codeHint}'}'
                '${c.areaOcr!.regionColumns.isEmpty ? '' : '  · region pass ${c.areaOcr!.regionColumns.map((r) => '${r.letters}/${r.source}').join(', ')}'}',
                style: const TextStyle(color: Colors.white38, fontSize: 11),
              ),
            ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: onEdit, child: const Text('Edit')),
              TextButton(
                onPressed: c.adjustAgain,
                child: const Text('Adjust area'),
              ),
              TextButton(onPressed: c.retake, child: const Text('Retake')),
            ],
          ),
        ],
      ),
    );
  }
}

/// One plate section: its label and the characters read in it. Stacked
/// sections (code aside) list their characters top to bottom.
class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.section});

  final PlateSection section;

  @override
  Widget build(BuildContext context) {
    final color = _sectionColor(section.kind);
    final stacked = section.kind == PlateSectionKind.geezRegion ||
        section.kind == PlateSectionKind.latinRegion;
    final chars = section.chars.isEmpty
        ? [section.value.isEmpty ? '–' : section.value]
        : section.chars.map((ch) => ch.text).toList();
    final style = TextStyle(
      color: section.detected ? color : Colors.white38,
      fontSize: 18,
      fontWeight: FontWeight.w700,
      height: 1.1,
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      decoration: BoxDecoration(
        border: Border.all(
          color: section.detected ? color : Colors.white24,
          width: 1.5,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${section.kind.index + 1} · ${_sectionLabel(section.kind)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white54, fontSize: 10),
          ),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: stacked
                ? Column(
                    children: [for (final t in chars) Text(t, style: style)],
                  )
                : Text(chars.join(), style: style),
          ),
        ],
      ),
    );
  }
}

class _EditPanel extends StatefulWidget {
  const _EditPanel({required this.controller});

  final PlateReaderController controller;

  @override
  State<_EditPanel> createState() => _EditPanelState();
}

class _EditPanelState extends State<_EditPanel> {
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
    final codes = PlateServiceType.values.map((t) => t.code).toList();
    final code = codes.contains(c.draftCode) ? c.draftCode : null;
    final region = EthiopianRegion.fromCode(c.draftRegionCode);
    const fieldStyle = TextStyle(color: Colors.white, fontSize: 18);

    return _Card(
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: _Labeled(
              label: 'Code',
              child: DropdownButton<String>(
                value: code,
                isExpanded: true,
                dropdownColor: const Color(0xFF222222),
                style: fieldStyle,
                items: [
                  for (final t in PlateServiceType.values)
                    DropdownMenuItem(value: t.code, child: Text(t.code)),
                ],
                onChanged: (v) => c.editField(code: v),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 3,
            child: _Labeled(
              label: 'Region',
              child: DropdownButton<EthiopianRegion>(
                value: region,
                isExpanded: true,
                dropdownColor: const Color(0xFF222222),
                style: fieldStyle,
                items: [
                  for (final r in EthiopianRegion.values)
                    DropdownMenuItem(
                      value: r,
                      child: Text('${r.code} ${r.amharicLabel}'),
                    ),
                ],
                onChanged: (v) => c.editField(regionCode: v?.code),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 4,
            child: _Labeled(
              label: 'Serial',
              child: TextField(
                controller: _serial,
                style: fieldStyle,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(isDense: true),
                onChanged: (v) => c.editField(serial: v),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Labeled extends StatelessWidget {
  const _Labeled({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(color: Colors.white60, fontSize: 12),
        ),
        child,
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
            controller.error ?? 'Something went wrong',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70),
          ),
          TextButton(
            onPressed: controller.retake,
            child: const Text('Try again'),
          ),
        ],
      ),
    );
  }
}

class _MessagePanel extends StatelessWidget {
  const _MessagePanel({required this.message, this.onClose});

  final String message;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xEE111111),
      child: SafeArea(
        child: Stack(
          children: [
            if (onClose != null)
              Positioned(
                top: 8,
                left: 8,
                child: _HudIconButton(icon: Icons.close, onPressed: onClose!),
              ),
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 15),
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
      color: const Color(0xD9111111),
      borderRadius: BorderRadius.circular(16),
      child: Padding(padding: const EdgeInsets.all(16), child: child),
    );
  }
}

class _HudIconButton extends StatelessWidget {
  const _HudIconButton({required this.icon, required this.onPressed});

  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0x88000000),
      shape: const CircleBorder(),
      child: IconButton(
        icon: Icon(icon, color: Colors.white),
        onPressed: onPressed,
      ),
    );
  }
}
