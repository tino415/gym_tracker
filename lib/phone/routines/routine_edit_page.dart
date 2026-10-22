import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/database.dart';
import '../../data/providers.dart';
import '../../l10n/l10n.dart';
import '../number_format.dart';
import '../run/workout_run_page.dart';
import '../circuit_units.dart';
import 'exercise_picker.dart';
import 'routine_exercise_detail_page.dart';

class RoutineEditPage extends ConsumerStatefulWidget {
  const RoutineEditPage({
    super.key,
    this.routineId,
    this.embedded = false,
    this.onDeleted,
    this.onCreated,
    this.onSelectExercise,
    this.selectedExerciseId,
    this.onExerciseRemoved,
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

  /// Called when the row currently in [selectedExerciseId] is removed from the
  /// list, so the host can clear the set-editor pane. Wide master-detail only.
  final VoidCallback? onExerciseRemoved;

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
        title: Text(ctx.l10n.routineDeleteTitle),
        content: Text(ctx.l10n.routineDeleteBody(_nameController.text)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(ctx.l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(ctx.l10n.commonDelete),
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
        SnackBar(content: Text(context.l10n.routineNameFirst)),
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
      markLabel: context.l10n.routineInThisRoutine,
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
        title: Text(isDraft ? context.l10n.routineNew : context.l10n.routineEdit),
        actions: [
          if (!_reorderMode) ...[
            // Embedded (wide master-detail) has no bottom FAB, so surface
            // "Add exercise" here where it's reachable next to the other actions.
            if (widget.embedded && !isDraft)
              IconButton(
                onPressed: _pickExerciseToAdd,
                icon: const Icon(Icons.add),
                tooltip: context.l10n.routineAddExercise,
              ),
            IconButton(
              onPressed: _canSave ? _saveName : null,
              icon: const Icon(Icons.check),
              tooltip: context.l10n.commonSave,
            ),
            if (!isDraft)
              IconButton(
                onPressed: () => setState(() => _reorderMode = true),
                icon: const Icon(Icons.swap_vert),
                tooltip: context.l10n.routineReorder,
              ),
            if (!isDraft)
              IconButton(
                onPressed: _delete,
                icon: const Icon(Icons.delete_outline),
                tooltip: context.l10n.routineDelete,
              ),
          ] else
            IconButton(
              onPressed: () => setState(() => _reorderMode = false),
              icon: const Icon(Icons.done),
              tooltip: context.l10n.commonDone,
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
              label: Text(context.l10n.routineAddExercise),
            ),
      body: fullAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(context.l10n.commonError('$e'))),
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
                  labelText: context.l10n.commonName,
                  border: const OutlineInputBorder(),
                  helperText: isDraft
                      ? context.l10n.routineNameHelperDraft
                      : context.l10n.routineNameHelperEdit,
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
                  label: Text(context.l10n.routineStartWorkout),
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
                      context.l10n.routineSaveFirst,
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
                      context.l10n.routineNoExercises,
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
                        onExerciseRemoved: widget.onExerciseRemoved,
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

  List<CircuitUnit<FullRoutineExercise>> _buildUnits(
    List<FullRoutineExercise> exercises,
  ) => buildCircuitUnits<FullRoutineExercise>(
    exercises,
    (e) => e.routineExercise.circuitGroup,
  );

  Future<void> _reorderUnits(
    List<CircuitUnit<FullRoutineExercise>> units,
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
    List<CircuitUnit<FullRoutineExercise>> units,
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
    this.onExerciseRemoved,
  });

  final int outerIndex;
  final CircuitUnit<FullRoutineExercise> unit;
  final String routineId;
  final bool reorderMode;
  final void Function(int oldIdx, int newIdx) onInnerReorder;
  final void Function(String routineExerciseId)? onSelectExercise;
  final String? selectedExerciseId;
  final VoidCallback? onExerciseRemoved;

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
              onExerciseRemoved: onExerciseRemoved,
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
                context.l10n.routineCircuit,
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
                        onExerciseRemoved: onExerciseRemoved,
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
class _ExerciseRow extends ConsumerWidget {
  const _ExerciseRow({
    required this.fullExercise,
    required this.routineId,
    required this.reorderMode,
    this.onSelectExercise,
    this.selectedExerciseId,
    this.onExerciseRemoved,
  });

  final FullRoutineExercise fullExercise;
  final String routineId;
  final bool reorderMode;
  final void Function(String routineExerciseId)? onSelectExercise;
  final String? selectedExerciseId;

  /// Called after removing the row that was currently selected, so the
  /// detail pane stops pointing at a row that no longer exists.
  final VoidCallback? onExerciseRemoved;

    String _summary(BuildContext context) {
    final l10n = context.l10n;
    final ps = fullExercise.plannedSets;
    if (ps.isEmpty) return l10n.routineNoSetsSummary;
    final last = ps.last;
    final rest = fullExercise.routineExercise.restSeconds;
    final core = fullExercise.kind == exerciseKindTime
        ? _fmtTime(context, last)
        : _fmtReps(context, last);
    final restLabel =
        rest == 0 ? l10n.routineNoRest : l10n.routineRestSeconds(rest);
    return l10n.routineExerciseSummary(
      l10n.routineSetCount(ps.length),
      core,
      restLabel,
    );
  }

  String _fmtTime(BuildContext context, PlannedSet s) {
    final l10n = context.l10n;
    final secs = s.targetSeconds;
    final w = s.targetWeightKg;
    if (secs == null) return l10n.routineTapToEdit;
    if (w != null && w > 0) {
      return l10n.routineSecondsWithWeight(secs, formatKg(context, w));
    }
    return l10n.routineSecondsShort(secs);
  }

  String _fmtReps(BuildContext context, PlannedSet s) {
    final l10n = context.l10n;
    final r = s.targetReps;
    final w = s.targetWeightKg;
    if (r == null && w == null) return l10n.routineTapToEdit;
    if (r == null) return l10n.commonWeightKg(formatKg(context, w!));
    if (w == null) return l10n.routineRepsCount(r);
    return l10n.routineRepsTimesWeight(r, formatKg(context, w));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final altsCount = fullExercise.alternatives.length;
    final ex = fullExercise.exercise;
    final reId = fullExercise.routineExercise.syncId;
    final selected = reId == selectedExerciseId;
    // Removing from the row itself is the wide/web affordance: there the
    // detail pane is a sibling, so "select it, scroll to the bottom, press
    // Remove" is three moves for what a pointer can do in one. Narrow keeps
    // the single button on the pushed detail page — a trailing delete next
    // to a full-width tap target is a mis-tap waiting to happen on a thumb.
    // `onSelectExercise != null` is exactly "rendered in the wide panes".
    final showDelete = onSelectExercise != null && !reorderMode;
    final altsBadge = altsCount > 0
        ? Badge.count(
            count: altsCount,
            child: Icon(Icons.swap_horiz, color: theme.colorScheme.outline),
          )
        : null;
    final tile = ListTile(
      selected: selected,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      leading: Icon(
        ex.kind == exerciseKindTime ? Icons.timer_outlined : Icons.repeat,
      ),
      title: Text(ex.name, overflow: TextOverflow.ellipsis),
      subtitle: Text(_summary(context)),
      trailing: showDelete
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (altsBadge != null) ...[
                  altsBadge,
                  const SizedBox(width: 8),
                ],
                IconButton(
                  tooltip: context.l10n.routineRemoveFromRoutine,
                  icon: const Icon(Icons.delete_outline),
                  color: theme.colorScheme.error,
                  // Always non-null: a null onRemoved makes the helper pop,
                  // and in an embedded pane the nearest route is the shell.
                  onPressed: () => confirmRemoveRoutineExercise(
                    context,
                    ref,
                    fullExercise,
                    onRemoved: () {
                      if (selected) onExerciseRemoved?.call();
                    },
                  ),
                ),
              ],
            )
          : altsBadge,
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
