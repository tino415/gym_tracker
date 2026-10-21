import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

/// Makes the text beneath it selectable, on web only.
///
/// Flutter paints text onto a canvas rather than emitting DOM, so on the web
/// build a routine or exercise name cannot be highlighted or copied the way
/// text on any other page can — the browser has nothing to select. A
/// [SelectionArea] restores that for its whole subtree, which is why this wraps
/// the app rather than individual labels: names are the point, but a user who
/// wants to copy one also wants to copy a weight, a date or an error message.
///
/// Web only, deliberately. On touch, [SelectionArea] claims the long-press
/// gesture, and the phone and watch builds have no use for selection anyway.
///
/// Reordering is unaffected: every reorderable list here passes
/// `buildDefaultDragHandles: false` and starts its drag from an explicit
/// [ReorderableDragStartListener] handle, so dragging across a row body was
/// never a reorder gesture and is now a selection one. Taps are untouched —
/// [SelectionArea] only claims drags (and long-press on touch), so buttons,
/// list rows and the navigation rail behave exactly as before.
class SelectableOnWeb extends StatelessWidget {
  const SelectableOnWeb({super.key, required this.child});

  final Widget child;

  // Its own Overlay: wrapping the whole app means sitting in
  // MaterialApp.builder, above the Navigator's.
  @override
  Widget build(BuildContext context) =>
      kIsWeb ? Overlay.wrap(child: SelectionArea(child: child)) : child;
}
