import 'package:flutter/material.dart';

import '../controller/plate_reader_controller.dart';
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

    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Colors.black),
        if (controller.isSupported)
          PlateCameraPreview(key: _previewKey, service: controller.service),
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
          _MessagePanel(message: controller.error!, onClose: widget.onCancel)
        else if (controller.isSupported && widget.overlayBuilder != null)
          widget.overlayBuilder!(context, controller)
        else if (controller.isSupported)
          _DefaultOverlay(
            controller: controller,
            onConfirm: _confirm,
            onClose: () async {
              await controller.cancelSession();
              widget.onCancel?.call();
            },
          ),
      ],
    );
  }
}

const _accent = Color(0xFFF5C518);
const _good = Color(0xFF4CAF50);

class _DefaultOverlay extends StatelessWidget {
  const _DefaultOverlay({
    required this.controller,
    required this.onConfirm,
    required this.onClose,
  });

  final PlateReaderController controller;
  final VoidCallback onConfirm;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final live = controller.liveCandidate;
    final phase = controller.phase;
    final frameColor = switch (phase) {
      ScanPhase.locked || ScanPhase.confirmed => _good,
      _ when live?.isValid ?? false => _accent,
      _ => Colors.white70,
    };

    return SafeArea(
      child: Stack(
        children: [
          Positioned(
            top: 8,
            left: 8,
            right: 8,
            child: Row(
              children: [
                _HudIconButton(icon: Icons.close, onPressed: onClose),
                const Spacer(),
                _HudIconButton(
                  icon: controller.torchOn ? Icons.flash_on : Icons.flash_off,
                  onPressed: controller.toggleTorch,
                ),
              ],
            ),
          ),
          Align(
            alignment: const Alignment(0, -0.2),
            child: FractionallySizedBox(
              widthFactor: 0.86,
              child: AspectRatio(
                aspectRatio: 2.2,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: frameColor, width: 3),
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: switch (phase) {
              ScanPhase.scanning => _ScanningPanel(
                  controller: controller,
                  candidate: live,
                ),
              ScanPhase.locked => _LockedPanel(
                  controller: controller,
                  onConfirm: onConfirm,
                ),
              ScanPhase.error => _ErrorPanel(controller: controller),
              _ => const SizedBox.shrink(),
            },
          ),
        ],
      ),
    );
  }
}

String _issueText(PlateIssue issue) => switch (issue) {
      PlateIssue.missingCode => 'Code not read',
      PlateIssue.unknownCode => 'Unknown code',
      PlateIssue.missingRegion => 'Region not read',
      PlateIssue.missingSerial => 'Serial must be 5 digits (optional letter)',
    };

class _ScanningPanel extends StatelessWidget {
  const _ScanningPanel({required this.controller, required this.candidate});

  final PlateReaderController controller;
  final PlateCandidate? candidate;

  @override
  Widget build(BuildContext context) {
    final c = candidate;
    final reading = c == null
        ? null
        : [c.code ?? '–', c.regionCode ?? '–', c.serial ?? '–'].join('  ·  ');
    return _Card(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            c == null
                ? 'Fit the plate inside the box'
                : c.isValid
                    ? 'Hold steady…'
                    : _issueText(c.issues.first),
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 14),
          ),
          if (reading != null) ...[
            const SizedBox(height: 8),
            Text(
              reading,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: controller.lockProgress,
              color: _accent,
              backgroundColor: Colors.white12,
            ),
            TextButton(
              onPressed: controller.lockCurrent,
              child: const Text('Use this reading'),
            ),
          ],
        ],
      ),
    );
  }
}

class _LockedPanel extends StatefulWidget {
  const _LockedPanel({required this.controller, required this.onConfirm});

  final PlateReaderController controller;
  final VoidCallback onConfirm;

  @override
  State<_LockedPanel> createState() => _LockedPanelState();
}

class _LockedPanelState extends State<_LockedPanel> {
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
    final issues = c.draftIssues;
    final codes = PlateServiceType.values.map((t) => t.code).toList();
    final code = codes.contains(c.draftCode) ? c.draftCode : null;
    final region = EthiopianRegion.fromCode(c.draftRegionCode);
    const fieldStyle = TextStyle(color: Colors.white, fontSize: 18);

    return _Card(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
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
          if (issues.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              issues.map(_issueText).join(' · '),
              style: const TextStyle(color: Colors.orangeAccent, fontSize: 13),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: c.rescan,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('Rescan'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: c.canConfirm ? widget.onConfirm : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: _accent,
                    foregroundColor: Colors.black,
                  ),
                  child: const Text('Done'),
                ),
              ),
            ],
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
