import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/database.dart';
import '../../data/providers.dart';
import '../run/workout_run_page.dart';
import '../superset_units.dart';
import 'exercise_picker.dart';

class RoutineEditPage extends ConsumerStatefulWidget {
  const RoutineEditPage({
    super.key,
    this.routineId,
    this.embedded = false,
    this.onDeleted,
    this.onCreated,
    this.onSelectExercise,
    this.selectedExerciseId,
  });

  final String? routineId;

  /// When true the page is hosted inside the wide-viewport master-detail pane
  /// rather than pushed as a route. It then has no back stack of its own, so
  /// close/delete are surfaced via [onDeleted] instead of `context.pop()`, and
  /// draft persistence is reported via [onCreated] (see `routines_list_page`).
  final bool embedded;

  /// Called when an embedded editor deletes its routine — the host clears the
  /// selection back to the placeholder. Ignored when not [embedded].
  final VoidCallback? onDeleted;

  /// Called with the new syncId when a draft is persisted, so the host can
  /// track/highlight the freshly created routine. Ignored when not [embedded].
  final ValueChanged<String>? onCreated;

  /// When set (wide master-detail), tapping an exercise row selects it for the
  /// set-editor pane instead of pushing the detail route. Null on narrow.
  final void Function(String routineExerciseId)? onSelectExercise;

  /// The currently selected exercise row (highlighted). Wide master-detail only.
  final String? selectedExerciseId;

  @override
  ConsumerState<RoutineEditPage> createState() => _RoutineEditPageState();
}

class _RoutineEditPageState extends ConsumerState<RoutineEditPage> {
  final _nameController = TextEditingController();
  String _initialName = '';
  String? _routineId;
  bool _initializing = true;
  bool _reorderMode = false;

  @override
  void initState() {
    super.initState();
    _routineId = widget.routineId;
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final db = ref.read(routineRepositoryProvider);
    if (_routineId == null) {
      _initialName = '';
      _nameController.text = '';
    } else {
      final full = await db.loadFullRoutine(_routineId!);
      _initialName = full?.routine.name ?? '';
      _nameController.text = _initialName;
    }
    if (!mounted) return;
    setState(() => _initializing = false);
  }

  /// Persist the routine if we're still in draft state. Returns the routine
  /// id (creating one if needed). Empty names short-circuit with null.
  Future<String?> _ensurePersisted() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) return null;
    if (_routineId != null) {
      if (_nameDirty) {
        await ref.read(routineRepositoryProvider).renameRoutine(_routineId!, name);
        _initialName = name;
      }
      return _routineId;
    }
    final created = await ref.read(routineRepositoryProvider).createRoutine(name);
    _initialName = name;
    setState(() => _routineId = created.syncId);
    widget.onCreated?.call(created.syncId);
    return created.syncId;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  bool get _nameDirty => _nameController.text.trim() != _initialName.trim();

  bool get _canSave =>
      _nameController.text.trim().isNotEmpty && (_routineId == null || _nameDirty);

  Future<void> _saveName() async {
    await _ensurePersisted();
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _delete() async {
    if (_routineId == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete routine?'),
        content: Text(
          'Delete "${_nameController.text}"? Past workouts will keep their own copy and remain in History.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await ref.read(routineRepositoryProvider).deleteRoutine(_routineId!);
    if (!mounted) return;
    if (widget.embedded) {
      widget.onDeleted?.call();
    } else {
      context.pop();
    }
  }

  Future<void> _pickExerciseToAdd() async {
    final routineId = await _ensurePersisted();
    if (routineId == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Give the routine a name first')),
      );
      return;
    }
    if (!mounted) return;
    // Flag what's already in the routine rather than hiding it — a routine can
    // legitimately repeat an exercise (e.g. a second, lighter block).
    final current = ref.read(fullRoutineProvider(routineId)).valueOrNull;
    final picked = await showExercisePicker(
      context,
      ref,
      markCounts: countExerciseIds(
        (current?.exercises ?? const <FullRoutineExercise>[])
            .map((e) => e.routineExercise.exerciseId),
      ),
      markLabel: 'In this routine',
    );
    if (picked == null || _routineId == null || !mounted) return;
    await ref.read(routineRepositoryProvider).addExerciseToRoutine(
          routineId: _routineId!,
          exerciseId: picked.syncId,
        );
  }

  @override
  Widget build(BuildContext context) {
    if (_initializing) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final isDraft = _routineId == null;
    final fullAsync = isDraft
        ? const AsyncValue<FullRoutine?>.data(null)
        : ref.watch(fullRoutineProvider(_routineId!));
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        // Embedded in the master-detail pane there's no route to pop; the
        // nearest navigator is the root, so an implied back arrow would pop the
        // whole shell.
        automaticallyImplyLeading: !widget.embedded,
        backgroundColor:
            _reorderMode ? theme.colorScheme.primaryContainer : null,
        title: Text(isDraft ? 'New routine' : 'Edit routine'),
        actions: [
          if (!_reorderMode) ...[
            // Embedded (wide master-detail) has no bottom FAB, so surface
            // "Add exercise" here where it's reachable next to the other actions.
            if (widget.embedded && !isDraft)
              IconButton(
                onPressed: _pickExerciseToAdd,
                icon: const Icon(Icons.add),
                tooltip: 'Add exercise',
              ),
            IconButton(
              onPressed: _canSave ? _saveName : null,
              icon: const Icon(Icons.check),
              tooltip: 'Save',
            ),
            if (!isDraft)
              IconButton(
                onPressed: () => setState(() => _reorderMode = true),
                icon: const Icon(Icons.swap_vert),
                tooltip: 'Reorder',
              ),
            if (!isDraft)
              IconButton(
                onPressed: _delete,
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Delete routine',
              ),
          ] else
            IconButton(
              onPressed: () => setState(() => _reorderMode = false),
              icon: const Icon(Icons.done),
              tooltip: 'Done',
            ),
        ],
      ),
      // Narrow pushes this page and uses the FAB; the wide pane hosts it
      // embedded and puts "Add exercise" in the app bar instead (reachable).
      floatingActionButton: (_reorderMode || isDraft || widget.embedded)
          ? null
          : FloatingActionButton.extended(
              onPressed: _pickExerciseToAdd,
              icon: const Icon(Icons.add),
              label: const Text('Add exercise'),
            ),
      body: fullAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (full) {
          final exercises = full?.exercises ?? const <FullRoutineExercise>[];
          final units = _buildUnits(exercises);
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
            children: [
              TextField(
                controller: _nameController,
                enabled: !_reorderMode,
                autofocus: isDraft,
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  labelText: 'Name',
                  border: const OutlineInputBorder(),
                  helperText: isDraft
                      ? 'Press Enter (or ✓) to save and start adding exercises'
                      : 'Press Enter (or ✓) to save changes',
                ),
                onChanged: (_) => setState(() {}),
                // Enter saves — creates the routine from a draft, or commits a
                // rename — so keyboard-first desktop entry doesn't need the ✓.
                onSubmitted: (_) {
                  if (_canSave) _saveName();
                },
              ),
              const SizedBox(height: 16),
              // The discoverable way to start a workout. It used to be an icon
              // on the routines list row, a thumb-width from the row's own tap
              // target, so opening a routine often started one instead. Here it
              // is unmissable but can only be hit deliberately; swiping a list
              // row left is the shortcut once you know it. Hidden while the
              // routine is a draft or empty — there is nothing to run — and on
              // web, which doesn't offer the run flow.
              if (!isDraft && exercises.isNotEmpty && runFlowAvailable) ...[
                FilledButton.icon(
                  onPressed: () => context.push('/run/$_routineId'),
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Start workout'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                ),
                const SizedBox(height: 16),
              ],
              if (isDraft)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Center(
                    child: Text(
                      'Save the routine first to add exercises.',
                      style: TextStyle(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ),
                )
              else if (exercises.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 32),
                  child: Center(
                    child: Text(
                      'No exercises in this routine yet.',
                      style: TextStyle(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ),
                ),
              if (!isDraft && exercises.isNotEmpty)
                ReorderableListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  buildDefaultDragHandles: false,
                  itemCount: units.length,
                  itemBuilder: (context, idx) {
                    final unit = units[idx];
                    return Padding(
                      // Prefixed so a single and a group starting with the
                      // same exercise get distinct keys — grouping one changes
                      // the tile's shape, and reusing the element across that
                      // would keep the old layout.
                      key: ValueKey(
                        '${unit.isGroup ? 'g' : 's'}-'
                        '${unit.first.routineExercise.syncId}',
                      ),
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _UnitTile(
                        outerIndex: idx,
                        unit: unit,
                        routineId: _routineId!,
                        reorderMode: _reorderMode,
                        onSelectExercise: widget.onSelectExercise,
                        selectedExerciseId: widget.selectedExerciseId,
                        onInnerReorder: (oldIdx, newIdx) =>
                            _reorderWithinGroup(units, idx, oldIdx, newIdx),
                      ),
                    );
                  },
                  onReorder: (oldIdx, newIdx) =>
                      _reorderUnits(units, oldIdx, newIdx),
                ),
            ],
          );
        },
      ),
    );
  }

  List<SupersetUnit<FullRoutineExercise>> _buildUnits(
    List<FullRoutineExercise> exercises,
  ) => buildSupersetUnits<FullRoutineExercise>(
    exercises,
    (e) => e.routineExercise.supersetGroup,
  );

  Future<void> _reorderUnits(
    List<SupersetUnit<FullRoutineExercise>> units,
    int oldIndex,
    int newIndex,
  ) async {
    final routineId = _routineId;
    if (routineId == null) return;
    await ref.read(routineRepositoryProvider).reorderRoutineExercises(
          routineId: routineId,
          orderedIds: reorderUnits(
            units,
            oldIndex,
            newIndex,
            (e) => e.routineExercise.syncId,
          ),
        );
  }

  Future<void> _reorderWithinGroup(
    List<SupersetUnit<FullRoutineExercise>> units,
    int unitIdx,
    int oldIndex,
    int newIndex,
  ) async {
    final routineId = _routineId;
    if (routineId == null) return;
    await ref.read(routineRepositoryProvider).reorderRoutineExercises(
          routineId: routineId,
          orderedIds: reorderWithinUnit(
            units,
            unitIdx,
            oldIndex,
            newIndex,
            (e) => e.routineExercise.syncId,
          ),
        );
  }
}

class _UnitTile extends StatelessWidget {
  const _UnitTile({
    required this.outerIndex,
    required this.unit,
    required this.routineId,
    required this.reorderMode,
    required this.onInnerReorder,
    this.onSelectExercise,
    this.selectedExerciseId,
  });

  final int outerIndex;
  final SupersetUnit<FullRoutineExercise> unit;
  final String routineId;
  final bool reorderMode;
  final void Function(int oldIdx, int newIdx) onInnerReorder;
  final void Function(String routineExerciseId)? onSelectExercise;
  final String? selectedExerciseId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isGroup = unit.isGroup;
    final outerHandle = ReorderableDragStartListener(
      index: outerIndex,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Icon(
          Icons.drag_indicator,
          color: theme.colorScheme.outline,
        ),
      ),
    );
    if (!isGroup) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (reorderMode) outerHandle,
          Expanded(
            child: _ExerciseRow(
              fullExercise: unit.first,
              routineId: routineId,
              reorderMode: reorderMode,
              onSelectExercise: onSelectExercise,
              selectedExerciseId: selectedExerciseId,
            ),
          ),
        ],
      );
    }
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.primary, width: 2),
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (reorderMode) outerHandle,
              const SizedBox(width: 4),
              Icon(
                Icons.link,
                size: 16,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 4),
              Text(
                'Superset',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            itemCount: unit.members.length,
            itemBuilder: (context, innerIdx) {
              final m = unit.members[innerIdx];
              return Padding(
                key: ValueKey('m-${m.routineExercise.syncId}'),
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    if (reorderMode)
                      ReorderableDragStartListener(
                        index: innerIdx,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Icon(
                            Icons.drag_handle,
                            size: 18,
                            color: theme.colorScheme.outline,
                          ),
                        ),
                      ),
                    Expanded(
                      child: _ExerciseRow(
                        fullExercise: m,
                        routineId: routineId,
                        reorderMode: reorderMode,
                        onSelectExercise: onSelectExercise,
                        selectedExerciseId: selectedExerciseId,
                      ),
                    ),
                  ],
                ),
              );
            },
            onReorder: onInnerReorder,
          ),
        ],
      ),
    );
  }
}

/// Compact one-row rendering of a routine exercise. In normal mode the whole
/// row is tappable and pushes the detail page. In reorder mode the tap is a
/// no-op (the drag handles supplied by `_UnitTile` handle gestures).
class _ExerciseRow extends StatelessWidget {
  const _ExerciseRow({
    required this.fullExercise,
    required this.routineId,
    required this.reorderMode,
    this.onSelectExercise,
    this.selectedExerciseId,
  });

  final FullRoutineExercise fullExercise;
  final String routineId;
  final bool reorderMode;
  final void Function(String routineExerciseId)? onSelectExercise;
  final String? selectedExerciseId;

  String _summary() {
    final ps = fullExercise.plannedSets;
    if (ps.isEmpty) return 'No sets · tap to edit';
    final last = ps.last;
    final rest = fullExercise.routineExercise.restSeconds;
    final core = fullExercise.kind == exerciseKindTime
        ? _fmtTime(last)
        : _fmtReps(last);
    return '${ps.length} ${ps.length == 1 ? 'set' : 'sets'} · last $core · ${rest}s rest';
  }

  String _fmtTime(PlannedSet s) {
    final secs = s.targetSeconds;
    final w = s.targetWeightKg;
    if (secs == null) return 'tap to edit';
    if (w != null && w > 0) return '${secs}s · ${_fmtKg(w)} kg';
    return '${secs}s';
  }

  String _fmtReps(PlannedSet s) {
    final r = s.targetReps;
    final w = s.targetWeightKg;
    if (r == null && w == null) return 'tap to edit';
    if (r == null) return '${_fmtKg(w!)} kg';
    if (w == null) return '$r reps';
    return '$r × ${_fmtKg(w)} kg';
  }

  String _fmtKg(double w) =>
      w == w.roundToDouble() ? w.toStringAsFixed(0) : w.toStringAsFixed(1);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final altsCount = fullExercise.alternatives.length;
    final ex = fullExercise.exercise;
    final reId = fullExercise.routineExercise.syncId;
    final selected = reId == selectedExerciseId;
    final tile = ListTile(
      selected: selected,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      leading: Icon(
        ex.kind == exerciseKindTime ? Icons.timer_outlined : Icons.repeat,
      ),
      title: Text(ex.name, overflow: TextOverflow.ellipsis),
      subtitle: Text(_summary()),
      trailing: altsCount > 0
          ? Badge.count(
              count: altsCount,
              child: Icon(
                Icons.swap_horiz,
                color: theme.colorScheme.outline,
              ),
            )
          : null,
      // Wide master-detail selects the row for the set-editor pane; narrow
      // pushes the detail route.
      onTap: reorderMode
          ? null
          : () {
              if (onSelectExercise != null) {
                onSelectExercise!(reId);
              } else {
                context.push('/routines/$routineId/exercises/$reId');
              }
            },
    );
    return Card(
      margin: EdgeInsets.zero,
      color: selected ? theme.colorScheme.primaryContainer : null,
      child: tile,
    );
  }
}
