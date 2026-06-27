import 'package:flutter/material.dart';

/// Shows a transient message on the watch. A default [SnackBar] spans edge to
/// edge and gets clipped by the round bezel, so this uses a floating pill
/// pulled in from the sides and lifted off the narrow bottom chord into the
/// wider middle band, with centred text that can wrap to two lines.
void showWatchSnack(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 36),
      shape: const StadiumBorder(),
      content: Text(
        message,
        textAlign: TextAlign.center,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      duration: const Duration(seconds: 2),
    ),
  );
}
