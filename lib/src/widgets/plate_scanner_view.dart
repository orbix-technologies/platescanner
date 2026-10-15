import 'package:flutter/material.dart';

import '../controller/plate_reader_controller.dart';
import '../models/ocr_frame.dart';
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
      final record = await widget.controller.confirmCurrent();
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

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final guide = PlateScannerView.guideRect(size);
        // Read only what is inside the drawn box. The preview fills this
        // widget, so view-normalized = preview-normalized coordinates.
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
              _GuideFrame(rect: guide, controller: controller),
              if (widget.overlayBuilder != null)
                widget.overlayBuilder!(context, controller)
              else
                _DefaultOverlay(
                  controller: controller,
                  guide: guide,
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

/// Dims everything outside the guide box and outlines it.
class _GuideFrame extends StatelessWidget {
  const _GuideFrame({required this.rect, required this.controller});

  final Rect rect;
  final PlateReaderController controller;

  @override
  Widget build(BuildContext context) {
    final live = controller.liveCandidate;
    final color = switch (controller.phase) {
      ScanPhase.locked || ScanPhase.confirmed => _good,
      _ when live?.isValid ?? false => _accent,
      _ => Colors.white70,
    };
    return IgnorePointer(
      child: CustomPaint(painter: _GuidePainter(rect, color)),
    );
  }
}

class _GuidePainter extends CustomPainter {
  _GuidePainter(this.rect, this.color);

  final Rect rect;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final box = RRect.fromRectAndRadius(rect, const Radius.circular(14));
    final outside = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRRect(box);
    canvas.drawPath(outside, Paint()..color = const Color(0x8C000000));
    canvas.drawRRect(
      box,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
  }

  @override
  bool shouldRepaint(_GuidePainter old) =>
      old.rect != rect || old.color != color;
}

class _DefaultOverlay extends StatefulWidget {
  const _DefaultOverlay({
    required this.controller,
    required this.guide,
    required this.onConfirm,
    required this.onClose,
  });

  final PlateReaderController controller;
  final Rect guide;
  final VoidCallback onConfirm;
  final VoidCallback onClose;

  @override
  State<_DefaultOverlay> createState() => _DefaultOverlayState();
}

class _DefaultOverlayState extends State<_DefaultOverlay> {
  bool _editing = false;

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final phase = controller.phase;
    if (phase != ScanPhase.locked) _editing = false;

    return Stack(
      children: [
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                _HudIconButton(icon: Icons.close, onPressed: widget.onClose),
                const Spacer(),
                _HudIconButton(
                  icon: controller.torchOn ? Icons.flash_on : Icons.flash_off,
                  onPressed: controller.toggleTorch,
                ),
              ],
            ),
          ),
        ),
        if (phase == ScanPhase.scanning || phase == ScanPhase.locked)
          Positioned(
            top: widget.guide.bottom + 12,
            left: widget.guide.left,
            width: widget.guide.width,
            child: _ReadingBar(
              controller: controller,
              onDone: widget.onConfirm,
              onEdit: () => setState(() => _editing = !_editing),
            ),
          ),
        if (_editing || phase == ScanPhase.error)
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: SafeArea(
              top: false,
              child: phase == ScanPhase.error
                  ? _ErrorPanel(controller: controller)
                  : _EditPanel(controller: controller),
            ),
          ),
      ],
    );
  }
}

String _issueText(PlateIssue issue) => switch (issue) {
      PlateIssue.missingCode => 'Code not read',
      PlateIssue.unknownCode => 'Unknown code',
      PlateIssue.missingRegion => 'Region not read',
      PlateIssue.missingSerial => 'Serial must be 5 digits (optional letter)',
    };

/// The detected plate with its Done button, right under the guide box.
class _ReadingBar extends StatelessWidget {
  const _ReadingBar({
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
    final locked = c.phase == ScanPhase.locked;
    final live = c.liveCandidate;

    if (!locked && live == null) {
      return const _Card(
        child: Text(
          'Fit the plate inside the box',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white70, fontSize: 14),
        ),
      );
    }

    final code = locked ? c.draftCode : live!.code;
    final region = locked ? c.draftRegionCode : live!.regionCode;
    final serial = locked ? c.draftSerial : live!.serial;
    final issues = locked ? c.draftIssues : live!.issues;
    final canDone = issues.isEmpty;
    final reading = [code ?? '–', region ?? '–', serial ?? '–'].join('  ·  ');
    final status = issues.isNotEmpty
        ? _issueText(issues.first)
        : locked
            ? 'Plate detected'
            : 'Hold steady…';

    return _Card(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
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
                        reading,
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
                      status,
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
                onPressed: canDone ? onDone : null,
                style: FilledButton.styleFrom(
                  backgroundColor: _accent,
                  foregroundColor: Colors.black,
                  disabledBackgroundColor: Colors.white24,
                ),
                child: const Text('Done'),
              ),
            ],
          ),
          if (!locked) ...[
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: c.lockProgress,
              color: _accent,
              backgroundColor: Colors.white12,
            ),
          ] else
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(onPressed: onEdit, child: const Text('Edit')),
                TextButton(onPressed: c.rescan, child: const Text('Rescan')),
              ],
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
            onPressed: controller.rescan,
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
