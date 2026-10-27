import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../exceptions/plate_reader_exception.dart';
import '../parsing/plate_service_type.dart';
import '../recognition/plate_camera_preview.dart';
import '../widgets/plate_scanner_options.dart';
import '../widgets/plate_scanner_strings.dart';
import 'patrol_controller.dart';
import 'patrol_tracker.dart';

/// Patrol screen: the camera, the plates in view, a count, the latest
/// vehicles and Finish. Plates are read as they pass, with no taps.
class PatrolView extends StatefulWidget {
  /// Creates the view for [controller] (started here, not disposed).
  const PatrolView({
    super.key,
    required this.controller,
    this.onFinish,
    this.onClose,
    this.strings,
    this.theme,
  });

  /// The patrol.
  final PatrolController controller;

  /// Finish tapped: the vehicles read, newest first.
  final ValueChanged<List<PatrolVehicle>>? onFinish;

  /// Close tapped.
  final VoidCallback? onClose;

  /// Texts; built-in English or Amharic (by locale) when null.
  final PlateScannerStrings? strings;

  /// Colour overrides; the app's theme otherwise.
  final PlateScannerTheme? theme;

  @override
  State<PatrolView> createState() => _PatrolViewState();
}

class _PatrolViewState extends State<PatrolView> {
  int _count = 0;
  bool _torch = false, _finishing = false;

  PatrolController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _c.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) => _c.start());
  }

  void _changed() {
    final n = _c.vehicles.length;
    if (n > _count) HapticFeedback.mediumImpact();
    _count = n;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _c.removeListener(_changed);
    super.dispose();
  }

  Future<void> _finish() async {
    if (_finishing) return;
    _finishing = true;
    final all = await _c.stop();
    widget.onFinish?.call(all);
  }

  @override
  Widget build(BuildContext context) {
    final strings = widget.strings ?? PlateScannerStrings.of(context);
    final colors = ResolvedPlateScannerTheme.of(context, widget.theme);
    final vehicles = _c.vehicles;

    if (_c.errorCode != null || _c.error != null) {
      return _Message(
        strings: strings,
        colors: colors,
        permission: _c.errorCode == PlateReaderErrorCode.permissionDenied,
        message: _c.errorCode == PlateReaderErrorCode.unsupportedDevice
            ? strings.unsupportedDevice
            : _c.error ?? strings.somethingWentWrong,
        onRetry: _c.start,
        onClose: widget.onClose,
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Colors.black),
        PlateCameraPreview(service: _c.service, patrol: true),
        IgnorePointer(
          child: CustomPaint(
            painter: _FocusPainter(_c.focus, colors.accent),
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                _Round(
                  icon: Icons.close,
                  tooltip: strings.close,
                  onPressed: () async {
                    await _c.stop();
                    widget.onClose?.call();
                  },
                ),
                const Spacer(),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0x99000000),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Text.rich(
                      TextSpan(children: [
                        TextSpan(
                          text: '${vehicles.length} ',
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 18,
                          ),
                        ),
                        TextSpan(text: strings.platesRead),
                      ]),
                      style: const TextStyle(color: Colors.white, fontSize: 15),
                    ),
                  ),
                ),
                const Spacer(),
                _Round(
                  icon: _torch
                      ? Icons.flashlight_on_rounded
                      : Icons.flashlight_off_rounded,
                  tooltip: strings.torch,
                  onPressed: () async {
                    final on = await _c.setTorch(!_torch);
                    if (mounted) setState(() => _torch = on);
                  },
                ),
              ],
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_c.focus != null) ...[
                    _NowReading(
                      vehicle: _c.focus!,
                      reading: _c.isReading,
                    ),
                    const SizedBox(height: 10),
                  ],
                  if (vehicles.isEmpty && _c.focus == null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Text(
                        strings.patrolHint,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          shadows: [Shadow(blurRadius: 6, color: Colors.black)],
                        ),
                      ),
                    )
                  else if (vehicles.isNotEmpty)
                    _Recent(
                      vehicles: vehicles,
                      checkLabel: strings.check,
                      isRefined: _c.isRefined,
                    ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: _finish,
                    style: FilledButton.styleFrom(
                      backgroundColor: colors.accent,
                      foregroundColor: colors.onAccent,
                      minimumSize: const Size.fromHeight(52),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: Text(strings.finish),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A box over each plate in view; its number once read.
/// A box over the plate being read, labelled with its reading so far.
class _FocusPainter extends CustomPainter {
  _FocusPainter(this.vehicle, this.accent);

  final PatrolVehicle? vehicle;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final v = vehicle;
    if (v == null) return;
    final b = v.box;
    final r = Rect.fromLTRB(b.left * size.width, b.top * size.height,
            b.right * size.width, b.bottom * size.height)
        .inflate(10);
    canvas.drawRRect(
      RRect.fromRectAndRadius(r, const Radius.circular(12)),
      Paint()
        ..color = accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
    final tp = TextPainter(
      text: TextSpan(
        text: ' ${v.plate} ',
        style: TextStyle(
          color: Colors.black,
          backgroundColor: accent,
          fontSize: 14,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(r.left, r.top - tp.height - 4));
  }

  @override
  bool shouldRepaint(_FocusPainter old) => true;
}

/// The plate being read now: its code, number and region as read so far,
/// and a spinner while its photo is read in full.
class _NowReading extends StatelessWidget {
  const _NowReading({required this.vehicle, required this.reading});

  final PatrolVehicle vehicle;
  final bool reading;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xE6111111),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Transform.scale(
                    scale: 1.25,
                    alignment: Alignment.centerLeft,
                    child: _MiniPlate(vehicle: vehicle),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            if (reading)
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white70,
                ),
              )
            else if (vehicle.complete)
              const Icon(Icons.check_circle_rounded,
                  color: Color(0xFF81C784), size: 22),
          ],
        ),
      ),
    );
  }
}

/// Every vehicle read, newest on top; scrolls once it fills its space.
class _Recent extends StatelessWidget {
  const _Recent({
    required this.vehicles,
    required this.checkLabel,
    required this.isRefined,
  });

  final List<PatrolVehicle> vehicles;
  final String checkLabel;
  final bool Function(PatrolVehicle) isRefined;

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.sizeOf(context).height * 0.36;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xCC111111),
          borderRadius: BorderRadius.circular(18),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: ListView.separated(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(vertical: 6),
            itemCount: vehicles.length,
            separatorBuilder: (_, __) => const Divider(
                height: 1, indent: 14, endIndent: 14, color: Color(0x22FFFFFF)),
            itemBuilder: (context, i) {
              final v = vehicles[i];
              return Padding(
                key: ValueKey(v.id),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: _MiniPlate(vehicle: v),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (v.needsCheck || !v.complete || v.noPlateSeen)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0x33FFA726),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          checkLabel,
                          style: const TextStyle(
                            color: Color(0xFFFFB74D),
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      )
                    else
                      const Icon(
                        Icons.check_circle_rounded,
                        color: Color(0xFF81C784),
                        size: 20,
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Code, number and region on one line.
class _MiniPlate extends StatelessWidget {
  const _MiniPlate({required this.vehicle});

  final PatrolVehicle vehicle;

  @override
  Widget build(BuildContext context) {
    final v = vehicle;
    final numeric = v.code != null && int.tryParse(v.code!) != null;
    const white = Colors.white;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (v.code != null) ...[
          numeric
              ? Container(
                  width: 24,
                  height: 24,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: white, width: 1.5),
                  ),
                  child: Text(
                    v.code!,
                    style: const TextStyle(
                        color: white,
                        fontSize: 12,
                        fontWeight: FontWeight.w700),
                  ),
                )
              : Text(
                  v.code == 'CD' && v.embassy != null
                      ? v.embassy!
                      : PlateServiceType.fromCode(v.code)?.amharicLabel ??
                          v.code!,
                  style: TextStyle(
                    color: white,
                    fontSize: v.embassy != null ? 18 : 13,
                    fontWeight:
                        v.embassy != null ? FontWeight.w800 : FontWeight.w400,
                  ),
                ),
          const SizedBox(width: 10),
        ],
        Text(
          v.serial ?? '—',
          style: const TextStyle(
            color: white,
            fontSize: 20,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.5,
          ),
        ),
        if (v.regionCode != null) ...[
          const SizedBox(width: 10),
          Text(
            v.regionCode!,
            style: const TextStyle(
                color: white, fontSize: 14, fontWeight: FontWeight.w700),
          ),
        ],
      ],
    );
  }
}

class _Round extends StatelessWidget {
  const _Round({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Material(
        color: const Color(0x88000000),
        shape: const CircleBorder(),
        child: IconButton(
          icon: Icon(icon, color: Colors.white),
          tooltip: tooltip,
          onPressed: onPressed,
        ),
      );
}

class _Message extends StatelessWidget {
  const _Message({
    required this.strings,
    required this.colors,
    required this.permission,
    required this.message,
    required this.onRetry,
    this.onClose,
  });

  final PlateScannerStrings strings;
  final ResolvedPlateScannerTheme colors;
  final bool permission;
  final String message;
  final VoidCallback onRetry;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFF111111),
      child: SafeArea(
        child: Stack(
          children: [
            if (onClose != null)
              Positioned(
                top: 8,
                left: 8,
                child: _Round(
                    icon: Icons.close,
                    tooltip: strings.close,
                    onPressed: onClose!),
              ),
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      permission ? strings.permissionTitle : message,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w600),
                    ),
                    if (permission) ...[
                      const SizedBox(height: 8),
                      Text(
                        strings.permissionMessage,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ],
                    const SizedBox(height: 20),
                    Wrap(
                      spacing: 12,
                      alignment: WrapAlignment.center,
                      children: [
                        if (permission)
                          FilledButton(
                            onPressed: openAppSettings,
                            style: FilledButton.styleFrom(
                              backgroundColor: colors.accent,
                              foregroundColor: colors.onAccent,
                            ),
                            child: Text(strings.openSettings),
                          ),
                        TextButton(
                          onPressed: onRetry,
                          child: Text(strings.tryAgain),
                        ),
                      ],
                    ),
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
