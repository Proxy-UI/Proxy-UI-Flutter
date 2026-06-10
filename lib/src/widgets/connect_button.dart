import 'dart:math' as math;

import 'package:flutter/material.dart';

// Component-specific animation cadences (visual identity of this widget,
// intentionally not shared app-wide constants).
const Duration _pulsePeriod = Duration(milliseconds: 2400);
const Duration _spinPeriod = Duration(milliseconds: 1100);
const Duration _fillTransition = Duration(milliseconds: 350);

/// Animated hero connect button for the proxy page.
///
/// Visual states:
/// - idle: neutral fill with a thin outlined ring
/// - busy (starting/stopping): a rotating comet-tail arc around the button
/// - connected: gradient fill with a soft glow and expanding pulse rings
class ConnectButton extends StatefulWidget {
  final bool isRunning;
  final bool isBusy;
  final bool enabled;
  final VoidCallback? onPressed;

  /// Outer bounding box size; the button itself is drawn smaller so the
  /// pulse rings have room to expand without clipping.
  final double size;

  const ConnectButton({
    super.key,
    required this.isRunning,
    required this.isBusy,
    required this.enabled,
    this.onPressed,
    this.size = 220,
  });

  @override
  State<ConnectButton> createState() => _ConnectButtonState();
}

class _ConnectButtonState extends State<ConnectButton>
    with TickerProviderStateMixin {
  late final AnimationController _pulse;
  late final AnimationController _spin;
  bool _pressed = false;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(vsync: this, duration: _pulsePeriod);
    _spin = AnimationController(vsync: this, duration: _spinPeriod);
    _syncAnimations();
  }

  @override
  void didUpdateWidget(ConnectButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isRunning != widget.isRunning ||
        oldWidget.isBusy != widget.isBusy) {
      _syncAnimations();
    }
  }

  void _syncAnimations() {
    if (widget.isBusy) {
      _spin.repeat();
    } else {
      _spin.stop();
      _spin.value = 0;
    }
    if (widget.isRunning && !widget.isBusy) {
      _pulse.repeat();
    } else {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    _spin.dispose();
    super.dispose();
  }

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final connected = widget.isRunning;
    final interactive = widget.enabled && widget.onPressed != null;
    final buttonSize = widget.size * 0.62;

    final fillGradient = connected
        ? LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [scheme.primary, scheme.secondary],
          )
        : null;
    final glow = connected
        ? [
            BoxShadow(
              color: scheme.primary.withValues(alpha: 0.45),
              blurRadius: 42,
              spreadRadius: 6,
            ),
            BoxShadow(
              color: scheme.secondary.withValues(alpha: 0.22),
              blurRadius: 18,
              spreadRadius: 2,
            ),
          ]
        : const <BoxShadow>[];

    return Semantics(
      button: true,
      enabled: interactive,
      label: connected ? 'Disconnect proxy' : 'Connect proxy',
      child: MouseRegion(
        cursor: interactive
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        child: GestureDetector(
          onTapDown: interactive ? (_) => _setPressed(true) : null,
          onTapUp: interactive ? (_) => _setPressed(false) : null,
          onTapCancel: interactive ? () => _setPressed(false) : null,
          onTap: interactive ? widget.onPressed : null,
          child: SizedBox(
            width: widget.size,
            height: widget.size,
            child: AnimatedBuilder(
              animation: Listenable.merge([_pulse, _spin]),
              builder: (context, child) {
                return CustomPaint(
                  painter: _RingPainter(
                    pulse: _pulse.value,
                    spin: _spin.value,
                    connected: connected,
                    busy: widget.isBusy,
                    primary: scheme.primary,
                    secondary: scheme.secondary,
                    busyColor: scheme.tertiary,
                    outline: scheme.outlineVariant,
                    buttonRadius: buttonSize / 2,
                  ),
                  child: child,
                );
              },
              child: Center(
                child: AnimatedScale(
                  scale: _pressed ? 0.93 : 1.0,
                  duration: const Duration(milliseconds: 120),
                  curve: Curves.easeOut,
                  child: AnimatedOpacity(
                    opacity: interactive || connected ? 1.0 : 0.55,
                    duration: _fillTransition,
                    child: AnimatedContainer(
                      duration: _fillTransition,
                      curve: Curves.easeOutCubic,
                      width: buttonSize,
                      height: buttonSize,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: fillGradient,
                        color: connected
                            ? null
                            : scheme.surfaceContainerHighest,
                        border: connected
                            ? null
                            : Border.all(color: scheme.outlineVariant),
                        boxShadow: glow,
                      ),
                      child: Icon(
                        Icons.power_settings_new_rounded,
                        size: buttonSize * 0.42,
                        color: connected
                            ? scheme.onPrimary
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Paints the decorative rings around the button:
/// pulse ripples when connected, a rotating comet arc when busy,
/// and a quiet static ring when idle.
class _RingPainter extends CustomPainter {
  final double pulse;
  final double spin;
  final bool connected;
  final bool busy;
  final Color primary;
  final Color secondary;
  final Color busyColor;
  final Color outline;
  final double buttonRadius;

  const _RingPainter({
    required this.pulse,
    required this.spin,
    required this.connected,
    required this.busy,
    required this.primary,
    required this.secondary,
    required this.busyColor,
    required this.outline,
    required this.buttonRadius,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final maxRadius = size.shortestSide / 2;
    final ringRadius = buttonRadius + 10;

    if (busy) {
      // Rotating comet-tail arc.
      final rect = Rect.fromCircle(center: center, radius: ringRadius);
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round
        ..shader = SweepGradient(
          colors: [busyColor.withValues(alpha: 0), busyColor],
          transform: GradientRotation(spin * 2 * math.pi),
        ).createShader(rect);
      canvas.drawCircle(center, ringRadius, paint);
      return;
    }

    if (connected) {
      // Two expanding, fading ripples half a phase apart, alternating
      // between the theme's primary and secondary accents.
      for (final (phase, color) in [(0.0, primary), (0.5, secondary)]) {
        final t = (pulse + phase) % 1.0;
        final radius = ringRadius + t * (maxRadius - ringRadius - 2);
        final paint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = color.withValues(alpha: (1 - t) * 0.35);
        canvas.drawCircle(center, radius, paint);
      }
      // Steady halo hugging the button.
      canvas.drawCircle(
        center,
        ringRadius - 4,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = primary.withValues(alpha: 0.55),
      );
      return;
    }

    // Idle: a single quiet ring.
    canvas.drawCircle(
      center,
      ringRadius - 4,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = outline,
    );
  }

  @override
  bool shouldRepaint(_RingPainter oldDelegate) {
    return pulse != oldDelegate.pulse ||
        spin != oldDelegate.spin ||
        connected != oldDelegate.connected ||
        busy != oldDelegate.busy ||
        primary != oldDelegate.primary ||
        secondary != oldDelegate.secondary ||
        busyColor != oldDelegate.busyColor ||
        outline != oldDelegate.outline ||
        buttonRadius != oldDelegate.buttonRadius;
  }
}
