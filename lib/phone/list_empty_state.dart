import 'package:flutter/material.dart';

/// Shared "nothing here yet" block for the three top-level lists.
///
/// The icon hangs from a fixed offset below the top of the list body, so
/// Routines / Exercises / Workouts put it at the same height instead of each
/// picking its own padding — and it stays put no matter how many hint [lines] a
/// section adds. (Centering the block instead would push the icon up in
/// whichever section has the most text, which is the misalignment this widget
/// exists to fix.)
class ListEmptyState extends StatelessWidget {
  const ListEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.lines = const [],
  });

  /// Distance from the top of the list body to the top of the icon.
  static const double topOffset = 88;

  final IconData icon;
  final String title;

  /// Secondary hint lines under the title, in order.
  final List<String> lines;

  /// The same block as a sliver, for lists whose empty case still has to be a
  /// scroll view (pull-to-refresh needs a scrollable child).
  Widget asSliver() => SliverToBoxAdapter(child: this);

  @override
  Widget build(BuildContext context) {
    final outline = Theme.of(context).colorScheme.outline;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, topOffset, 24, 24),
      // Claim the full width explicitly: as a sliver child the incoming width
      // is tight and the column would centre itself, but as a plain box child
      // (Exercises) it's loose, and the column would shrink-wrap to the left.
      child: Align(
        alignment: Alignment.topCenter,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 64, color: outline),
            const SizedBox(height: 16),
            Text(
              title,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w500,
              ),
              textAlign: TextAlign.center,
            ),
            for (final line in lines) ...[
              const SizedBox(height: 8),
              Text(
                line,
                style: TextStyle(color: outline),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
