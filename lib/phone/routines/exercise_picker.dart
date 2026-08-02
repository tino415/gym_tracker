import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database.dart';
import '../../data/providers.dart';
import '../breakpoints.dart';
import '../exercises/muscle_selector.dart';

/// Shared exercise picker — adding an exercise to a routine or a workout, and
/// adding an alternative. Returns the picked exercise, or null when dismissed.
///
/// Two ways to handle an exercise the caller already has:
/// - [markCounts] flags it (with a ×N suffix past the first) but keeps it
///   selectable. This is what routines and workouts use: repeating an exercise
///   is legitimate, the user just wants to see that it's already in there.
/// - [excludeIds] hides it outright. Only alternatives use this, where a
///   duplicate would be a data error — `swapWorkoutExercise` resolves a variant
///   by `exerciseId` and takes the first match.
///
/// Presentation adapts to the viewport: a centered [AlertDialog] on wide
/// (desktop/web) viewports where a bottom sheet rolling up from the corner reads
/// as awkward, and the roll-up bottom sheet on narrow (phone) widths. Both host
/// the same [_ExercisePickerBody], which offers a name search and muscle
/// filters so a large exercise library stays navigable.
/// Tally exercise ids for [showExercisePicker]'s `markCounts`. Nulls are
/// skipped — a workout exercise can have a null `exerciseId` when its exercise
/// was deleted from the library after the workout was recorded.
Map<String, int> countExerciseIds(Iterable<String?> ids) {
  final counts = <String, int>{};
  for (final id in ids) {
    if (id == null) continue;
    counts[id] = (counts[id] ?? 0) + 1;
  }
  return counts;
}

Future<Exercise?> showExercisePicker(
  BuildContext context,
  WidgetRef ref, {
  Set<String> excludeIds = const {},
  Map<String, int> markCounts = const {},
  String markLabel = 'Already added',
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
            child: _ExercisePickerBody(
              exercises: exercises,
              markCounts: markCounts,
              markLabel: markLabel,
            ),
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
        child: _ExercisePickerBody(
          exercises: exercises,
          markCounts: markCounts,
          markLabel: markLabel,
        ),
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
  const _ExercisePickerBody({
    required this.exercises,
    this.markCounts = const {},
    this.markLabel = 'Already added',
  });

  /// Available exercises (already filtered by the caller's `excludeIds`).
  final List<ExerciseWithMuscles> exercises;

  /// How many times each exercise already appears in the caller's list.
  /// Flagged, not hidden: repeating an exercise in a routine or a workout is
  /// legitimate, the user just wants to see that it's already in there — and
  /// how often.
  final Map<String, int> markCounts;
  final String markLabel;

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
          child: _ExerciseResultList(
            exercises: filtered,
            total: widget.exercises.length,
            markCounts: widget.markCounts,
            markLabel: widget.markLabel,
          ),
        ),
      ],
    );
  }
}

/// The filtered result rows (or the appropriate empty message). [total] is the
/// count of available exercises before search/muscle filtering, so we can tell
/// "no exercises at all" apart from "none match the current filter".
class _ExerciseResultList extends StatelessWidget {
  const _ExerciseResultList({
    required this.exercises,
    required this.total,
    this.markCounts = const {},
    this.markLabel = 'Already added',
  });

  final List<ExerciseWithMuscles> exercises;
  final int total;
  final Map<String, int> markCounts;
  final String markLabel;

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
        final count = markCounts[e.exercise.syncId] ?? 0;
        return ListTile(
          leading: Icon(
            e.exercise.kind == exerciseKindTime
                ? Icons.timer_outlined
                : Icons.repeat,
          ),
          title: Row(
            children: [
              Flexible(child: Text(e.exercise.name)),
              if (count > 0) ...[
                const SizedBox(width: 8),
                _AlreadyAddedTag(label: markLabel, count: count),
              ],
            ],
          ),
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

/// Marks an exercise the caller already has in its list. Deliberately not a
/// disabled state — the row stays tappable, because repeating an exercise in a
/// routine or a workout is a real thing to want.
class _AlreadyAddedTag extends StatelessWidget {
  const _AlreadyAddedTag({required this.label, required this.count});
  final String label;

  /// How many times it's already in the list. Rendered as a ×N suffix past the
  /// first, so the common case stays a plain "already there" mark.
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.check,
            size: 12,
            color: theme.colorScheme.onSecondaryContainer,
          ),
          const SizedBox(width: 3),
          Text(
            count > 1 ? '$label ×$count' : label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSecondaryContainer,
            ),
          ),
        ],
      ),
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
