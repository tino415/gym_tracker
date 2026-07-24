import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database.dart';
import '../../data/providers.dart';

/// Shared bottom-sheet exercise picker. Used both for adding an exercise to a
/// routine and for adding an alternative. [excludeIds] hides anything already
/// in the slot to avoid duplicates. Returns the picked exercise, or null when
/// the sheet is dismissed.
Future<Exercise?> showExercisePicker(
  BuildContext context,
  WidgetRef ref, {
  Set<String> excludeIds = const {},
}) async {
  final db = ref.read(exerciseRepositoryProvider);
  final all = await db.watchExercises().first;
  final exercises = excludeIds.isEmpty
      ? all
      : all.where((e) => !excludeIds.contains(e.syncId)).toList();
  if (!context.mounted) return null;
  return showModalBottomSheet<Exercise>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) {
      return SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('Create new exercise'),
              onTap: () async {
                final created = await showCreateExerciseDialog(ctx, ref);
                if (created != null && ctx.mounted) {
                  Navigator.of(ctx).pop(created);
                }
              },
            ),
            const Divider(height: 1),
            if (exercises.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No exercises available.',
                  textAlign: TextAlign.center,
                ),
              )
            else
              for (final e in exercises)
                ListTile(
                  leading: Icon(
                    e.kind == exerciseKindTime
                        ? Icons.timer_outlined
                        : Icons.repeat,
                  ),
                  title: Text(e.name),
                  onTap: () => Navigator.of(ctx).pop(e),
                ),
          ],
        ),
      );
    },
  );
}

Future<Exercise?> showCreateExerciseDialog(
  BuildContext context,
  WidgetRef ref,
) async {
  final controller = TextEditingController();
  String kind = exerciseKindReps;
  final result = await showDialog<Exercise>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        title: const Text('New exercise'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 12),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: exerciseKindReps, label: Text('Reps')),
                ButtonSegment(value: exerciseKindTime, label: Text('Time')),
              ],
              selected: {kind},
              onSelectionChanged: (s) => setLocal(() => kind = s.first),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              final name = controller.text.trim();
              if (name.isEmpty) return;
              try {
                final db = ref.read(exerciseRepositoryProvider);
                final created = await db.createExercise(name, kind: kind);
                if (!ctx.mounted) return;
                Navigator.of(ctx).pop(created);
              } catch (e) {
                if (!ctx.mounted) return;
                ScaffoldMessenger.of(ctx).showSnackBar(
                  SnackBar(content: Text('Could not create: $e')),
                );
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    ),
  );
  controller.dispose();
  return result;
}
