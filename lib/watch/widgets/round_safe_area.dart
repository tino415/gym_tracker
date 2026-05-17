import 'package:flutter/material.dart';

/// Whether the watch face is round. Widgets read this to decide whether to
/// add bezel-aware padding around content that lives near the screen edges.
class WatchShapeScope extends InheritedWidget {
  const WatchShapeScope({
    super.key,
    required this.isRound,
    required super.child,
  });

  final bool isRound;

  static bool of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<WatchShapeScope>();
    return scope?.isRound ?? false;
  }

  @override
  bool updateShouldNotify(WatchShapeScope old) => old.isRound != isRound;
}

/// Wraps `child` in `SafeArea` plus extra padding sized to the round
/// inscribed circle when running on a round watch. On a square watch this is
/// just a plain `SafeArea`.
class RoundSafeArea extends StatelessWidget {
  const RoundSafeArea({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final isRound = WatchShapeScope.of(context);
    return SafeArea(
      child: isRound
          ? Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: child,
            )
          : child,
    );
  }
}

