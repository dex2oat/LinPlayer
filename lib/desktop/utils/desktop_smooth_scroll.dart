import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Desktop-focused scroll controller that smooths mouse-wheel scrolling.
class DesktopSmoothScrollController extends ScrollController {
  DesktopSmoothScrollController({
    super.initialScrollOffset,
    super.keepScrollOffset,
    super.debugLabel,
    this.duration = const Duration(milliseconds: 220),
    this.curve = Curves.easeOutCubic,
  });

  final Duration duration;
  final Curve curve;

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    return _DesktopSmoothScrollPosition(
      physics: physics,
      context: context,
      oldPosition: oldPosition,
      initialPixels: initialScrollOffset,
      keepScrollOffset: keepScrollOffset,
      debugLabel: debugLabel,
      duration: duration,
      curve: curve,
    );
  }
}

class _DesktopSmoothScrollPosition extends ScrollPositionWithSingleContext {
  _DesktopSmoothScrollPosition({
    required super.physics,
    required super.context,
    super.initialPixels,
    super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
    required this.duration,
    required this.curve,
  });

  final Duration duration;
  final Curve curve;

  double? _pointerScrollTarget;

  @override
  void pointerScroll(double delta) {
    if (delta == 0) {
      goBallistic(0);
      return;
    }

    final target = math.min(
      maxScrollExtent,
      math.max(
        minScrollExtent,
        (_pointerScrollTarget ?? pixels) + delta,
      ),
    );

    if (target == pixels) {
      return;
    }

    _pointerScrollTarget = target;
    animateTo(target, duration: duration, curve: curve).whenComplete(() {
      if (_pointerScrollTarget == target) {
        _pointerScrollTarget = null;
      }
    });
  }
}

/// Convenience wrapper for pages that need a dedicated smooth scroll controller.
class DesktopSmoothScrollBuilder extends StatefulWidget {
  const DesktopSmoothScrollBuilder({
    super.key,
    required this.builder,
    this.duration = const Duration(milliseconds: 220),
    this.curve = Curves.easeOutCubic,
  });

  final Widget Function(BuildContext context, ScrollController controller) builder;
  final Duration duration;
  final Curve curve;

  @override
  State<DesktopSmoothScrollBuilder> createState() =>
      _DesktopSmoothScrollBuilderState();
}

class _DesktopSmoothScrollBuilderState extends State<DesktopSmoothScrollBuilder> {
  late final DesktopSmoothScrollController _controller;

  @override
  void initState() {
    super.initState();
    _controller = DesktopSmoothScrollController(
      duration: widget.duration,
      curve: widget.curve,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.builder(context, _controller);
  }
}
