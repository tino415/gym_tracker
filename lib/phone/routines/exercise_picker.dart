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
                final created = await showCreateExerciseDialog(ctx);
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

Future<Exercise?> showCreateExerciseDialog(BuildContext context) =>
    showDialog<Exercise>(
      context: context,
      builder: (_) => const _NewExerciseDialog(),
    );

/// New-exercise dialog. A [StatefulWidget] (not a function-scoped controller +
/// StatefulBuilder) so the [TextEditingController] is owned by the element and
/// disposed in [State.dispose] — i.e. after the route detaches. Disposing it
/// synchronously right after `showDialog` returned tore it down while the
/// dialog's `TextField` was still animating out, which threw
/// "TextEditingController was used after being disposed" on every create.
class _NewExerciseDialog extends ConsumerStatefulWidget {
  const _NewExerciseDialog();

  @override
  ConsumerState<_NewExerciseDialog> createState() => _NewExerciseDialogState();
}

class _NewExerciseDialogState extends ConsumerState<_NewExerciseDialog> {
  final _controller = TextEditingController();
  String _kind = exerciseKindReps;
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name = _controller.text.trim();
    if (name.isEmpty) return;
    setState(() => _busy = true);
    try {
      final created = await ref
          .read(exerciseRepositoryProvider)
          .createExercise(name, kind: _kind);
      if (!mounted) return;
      Navigator.of(context).pop(created);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not create: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New exercise'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Name'),
            onSubmitted: (_) => _busy ? null : _create(),
          ),
          const SizedBox(height: 12),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: exerciseKindReps, label: Text('Reps')),
              ButtonSegment(value: exerciseKindTime, label: Text('Time')),
            ],
            selected: {_kind},
            onSelectionChanged: (s) => setState(() => _kind = s.first),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _create,
          child: const Text('Create'),
        ),
      ],
    );
  }
}
