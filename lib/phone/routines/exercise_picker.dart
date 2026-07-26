import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database.dart';
import '../../data/providers.dart';
import '../breakpoints.dart';
import '../exercises/muscle_selector.dart';

/// Shared exercise picker. Used both for adding an exercise to a routine and for
/// adding an alternative. [excludeIds] hides anything already in the slot to
/// avoid duplicates. Returns the picked exercise, or null when dismissed.
///
/// Presentation adapts to the viewport: a centered [AlertDialog] on wide
/// (desktop/web) viewports where a bottom sheet rolling up from the corner reads
/// as awkward, and the roll-up bottom sheet on narrow (phone) widths. Both host
/// the same [_ExercisePickerBody], which offers a name search and muscle
/// filters so a large exercise library stays navigable.
Future<Exercise?> showExercisePicker(
  BuildContext context,
  WidgetRef ref, {
  Set<String> excludeIds = const {},
}) async {
  final db = ref.read(exerciseRepositoryProvider);
  final all = await db.watchExercisesWithMuscles().first;
  final exercises = excludeIds.isEmpty
      ? all
      : all.where((e) => !excludeIds.contains(e.exercise.syncId)).toList();
  if (!context.mounted) return null;

  final wide = MediaQuery.sizeOf(context).width >= masterDetailBreakpoint;
  if (wide) {
    return showDialog<Exercise>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add exercise'),
        contentPadding: const EdgeInsets.symmetric(vertical: 8),
        content: SizedBox(
          width: 420,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 420),
            child: _ExercisePickerBody(exercises: exercises),
          ),
        ),
      ),
    );
  }
  return showModalBottomSheet<Exercise>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      // Bound the sheet so the pinned header + [Expanded] list have a finite
      // height to lay out against (the sheet is `isScrollControlled`, i.e.
      // otherwise unbounded).
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(ctx).height * 0.75,
        ),
        child: _ExercisePickerBody(exercises: exercises),
      ),
    ),
  );
}

/// The picker's body — pinned header (name search + muscle filter chips) and
/// "Create new exercise" tile over a scrolling, filtered exercise list. Shared
/// by the wide dialog and the narrow bottom sheet.
///
/// A [StatefulWidget] (not a function + StatefulBuilder) so the search
/// [TextEditingController] is owned by the element and disposed after the route
/// detaches — see [_NewExerciseDialog] for the disposed-too-early pitfall.
class _ExercisePickerBody extends StatefulWidget {
  const _ExercisePickerBody({required this.exercises});

  /// Available exercises (already filtered by the caller's `excludeIds`).
  final List<ExerciseWithMuscles> exercises;

  @override
  State<_ExercisePickerBody> createState() => _ExercisePickerBodyState();
}

class _ExercisePickerBodyState extends State<_ExercisePickerBody> {
  final _searchController = TextEditingController();
  String _query = '';
  final Set<String> _selectedMuscleIds = <String>{};

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Muscles present on at least one available exercise, de-duplicated by
  /// syncId and sorted by name — so the filter never offers a muscle that would
  /// match nothing.
  List<Muscle> get _availableMuscles {
    final byId = <String, Muscle>{};
    for (final e in widget.exercises) {
      for (final m in e.muscles) {
        byId[m.syncId] = m;
      }
    }
    final list = byId.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return list;
  }

  List<ExerciseWithMuscles> get _filtered {
    final q = _query.trim().toLowerCase();
    return widget.exercises.where((e) {
      if (q.isNotEmpty && !e.exercise.name.toLowerCase().contains(q)) {
        return false;
      }
      // OR semantics: match if the exercise carries any selected muscle.
      if (_selectedMuscleIds.isNotEmpty &&
          !e.muscles.any((m) => _selectedMuscleIds.contains(m.syncId))) {
        return false;
      }
      return true;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final muscles = _availableMuscles;
    final filtered = _filtered;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // -- Pinned header: search + muscle filters --
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: TextField(
            controller: _searchController,
            autofocus: true,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search exercises',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        if (muscles.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final m in muscles)
                    FilterChip(
                      label: Text(m.name),
                      selected: _selectedMuscleIds.contains(m.syncId),
                      onSelected: (_) => setState(() {
                        if (!_selectedMuscleIds.add(m.syncId)) {
                          _selectedMuscleIds.remove(m.syncId);
                        }
                      }),
                    ),
                ],
              ),
            ),
          ),
        // -- "Create new exercise" (stays pinned above the scrolling list) --
        ListTile(
          leading: const Icon(Icons.add),
          title: const Text('Create new exercise'),
          onTap: () async {
            final created = await showCreateExerciseDialog(context);
            if (created != null && context.mounted) {
              Navigator.of(context).pop(created);
            }
          },
        ),
        const Divider(height: 1),
        // -- Scrolling filtered list --
        Expanded(
          child: _ExerciseResultList(exercises: filtered, total: widget.exercises.length),
        ),
      ],
    );
  }
}

/// The filtered result rows (or the appropriate empty message). [total] is the
/// count of available exercises before search/muscle filtering, so we can tell
/// "no exercises at all" apart from "none match the current filter".
class _ExerciseResultList extends StatelessWidget {
  const _ExerciseResultList({required this.exercises, required this.total});

  final List<ExerciseWithMuscles> exercises;
  final int total;

  @override
  Widget build(BuildContext context) {
    if (exercises.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          total == 0 ? 'No exercises available.' : 'No exercises match.',
          textAlign: TextAlign.center,
        ),
      );
    }
    return ListView.builder(
      itemCount: exercises.length,
      itemBuilder: (context, i) {
        final e = exercises[i];
        return ListTile(
          leading: Icon(
            e.exercise.kind == exerciseKindTime
                ? Icons.timer_outlined
                : Icons.repeat,
          ),
          title: Text(e.exercise.name),
          subtitle: e.muscles.isEmpty
              ? null
              : Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      for (final m in e.muscles) _MuscleTag(name: m.name),
                    ],
                  ),
                ),
          onTap: () => Navigator.of(context).pop(e.exercise),
        );
      },
    );
  }
}

/// Small muscle-name chip shown under an exercise row — mirrors the tag style in
/// the exercises registry list.
class _MuscleTag extends StatelessWidget {
  const _MuscleTag({required this.name});
  final String name;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        name,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: scheme.onSecondaryContainer,
            ),
      ),
    );
  }
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
  final Set<String> _selectedMuscleIds = <String>{};
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
      final repo = ref.read(exerciseRepositoryProvider);
      final created = await repo.createExercise(name, kind: _kind);
      // Only write muscles when some were picked, so creating an exercise whose
      // name reconciles to an existing one (see createExercise) doesn't wipe its
      // muscles with an empty selection.
      if (_selectedMuscleIds.isNotEmpty) {
        await repo.setExerciseMuscles(
          created.syncId,
          _selectedMuscleIds.toList(),
        );
      }
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
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
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
              const SizedBox(height: 16),
              MuscleSelector(
                selectedIds: _selectedMuscleIds,
                onToggled: (id) => setState(() {
                  if (!_selectedMuscleIds.add(id)) {
                    _selectedMuscleIds.remove(id);
                  }
                }),
              ),
            ],
          ),
        ),
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
