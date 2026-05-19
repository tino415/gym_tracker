import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/database.dart';
import '../../data/providers.dart';
import 'exercise_picker.dart';

class RoutineEditPage extends ConsumerStatefulWidget {
  const RoutineEditPage({super.key, this.routineId});

  final int? routineId;

  @override
  ConsumerState<RoutineEditPage> createState() => _RoutineEditPageState();
}

class _RoutineEditPageState extends ConsumerState<RoutineEditPage> {
  final _nameController = TextEditingController();
  String _initialName = '';
  int? _routineId;
  bool _initializing = true;
  bool _reorderMode = false;

  @override
  void initState() {
    super.initState();
    _routineId = widget.routineId;
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final db = ref.read(databaseProvider);
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
  Future<int?> _ensurePersisted() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) return null;
    if (_routineId != null) {
      if (_nameDirty) {
        await ref.read(databaseProvider).renameRoutine(_routineId!, name);
        _initialName = name;
      }
      return _routineId;
    }
    final created = await ref.read(databaseProvider).createRoutine(name);
    _initialName = name;
    setState(() => _routineId = created.id);
    return created.id;
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
    if (confirmed != true) return;
    await ref.read(databaseProvider).deleteRoutine(_routineId!);
    if (!mounted) return;
    context.pop();
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
    final picked = await showExercisePicker(context, ref);
    if (picked == null || _routineId == null) return;
    await ref.read(databaseProvider).addExerciseToRoutine(
          routineId: _routineId!,
          exerciseId: picked.id,
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
        backgroundColor:
            _reorderMode ? theme.colorScheme.primaryContainer : null,
        title: Text(isDraft ? 'New routine' : 'Edit routine'),
        actions: [
          if (!_reorderMode) ...[
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
      floatingActionButton: (_reorderMode || isDraft)
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
                decoration: InputDecoration(
                  labelText: 'Name',
                  border: const OutlineInputBorder(),
                  helperText: isDraft
                      ? 'Tap ✓ to save and start adding exercises'
                      : 'Tap ✓ to save changes',
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 16),
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
                      key: ValueKey(unit.key),
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _UnitTile(
                        outerIndex: idx,
                        unit: unit,
                        routineId: _routineId!,
                        reorderMode: _reorderMode,
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

  List<_RoutineUnit> _buildUnits(List<FullRoutineExercise> exercises) {
    final units = <_RoutineUnit>[];
    var i = 0;
    while (i < exercises.length) {
      final cur = exercises[i];
      final g = cur.routineExercise.supersetGroup;
      if (g == null) {
        units.add(_SingleUnit(cur));
        i++;
        continue;
      }
      var j = i + 1;
      while (j < exercises.length &&
          exercises[j].routineExercise.supersetGroup == g) {
        j++;
      }
      if (j - i == 1) {
        units.add(_SingleUnit(cur));
      } else {
        units.add(_GroupUnit(exercises.sublist(i, j)));
      }
      i = j;
    }
    return units;
  }

  Future<void> _reorderUnits(
    List<_RoutineUnit> units,
    int oldIndex,
    int newIndex,
  ) async {
    final routineId = _routineId;
    if (routineId == null) return;
    final list = List<_RoutineUnit>.from(units);
    var insertAt = newIndex;
    if (newIndex > oldIndex) insertAt -= 1;
    final moved = list.removeAt(oldIndex);
    list.insert(insertAt, moved);
    final orderedIds = <int>[
      for (final u in list)
        for (final m in u.members) m.routineExercise.id,
    ];
    await ref
        .read(databaseProvider)
        .reorderRoutineExercises(routineId: routineId, orderedIds: orderedIds);
  }

  Future<void> _reorderWithinGroup(
    List<_RoutineUnit> units,
    int unitIdx,
    int oldIndex,
    int newIndex,
  ) async {
    final routineId = _routineId;
    if (routineId == null) return;
    final unit = units[unitIdx];
    if (unit is! _GroupUnit) return;
    final reordered = List<FullRoutineExercise>.from(unit.members);
    var insertAt = newIndex;
    if (newIndex > oldIndex) insertAt -= 1;
    final moved = reordered.removeAt(oldIndex);
    reordered.insert(insertAt, moved);
    final orderedIds = <int>[];
    for (var i = 0; i < units.length; i++) {
      if (i == unitIdx) {
        for (final m in reordered) {
          orderedIds.add(m.routineExercise.id);
        }
      } else {
        for (final m in units[i].members) {
          orderedIds.add(m.routineExercise.id);
        }
      }
    }
    await ref
        .read(databaseProvider)
        .reorderRoutineExercises(routineId: routineId, orderedIds: orderedIds);
  }
}

sealed class _RoutineUnit {
  List<FullRoutineExercise> get members;
  String get key;
}

class _SingleUnit extends _RoutineUnit {
  _SingleUnit(this.member);
  final FullRoutineExercise member;
  @override
  List<FullRoutineExercise> get members => [member];
  @override
  String get key => 's-${member.routineExercise.id}';
}

class _GroupUnit extends _RoutineUnit {
  _GroupUnit(this._members);
  final List<FullRoutineExercise> _members;
  @override
  List<FullRoutineExercise> get members => _members;
  @override
  String get key => 'g-${_members.first.routineExercise.id}';
}

class _UnitTile extends StatelessWidget {
  const _UnitTile({
    required this.outerIndex,
    required this.unit,
    required this.routineId,
    required this.reorderMode,
    required this.onInnerReorder,
  });

  final int outerIndex;
  final _RoutineUnit unit;
  final int routineId;
  final bool reorderMode;
  final void Function(int oldIdx, int newIdx) onInnerReorder;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isGroup = unit is _GroupUnit;
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
      final single = unit as _SingleUnit;
      return Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (reorderMode) outerHandle,
          Expanded(
            child: _ExerciseRow(
              fullExercise: single.member,
              routineId: routineId,
              reorderMode: reorderMode,
            ),
          ),
        ],
      );
    }
    final group = unit as _GroupUnit;
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
            itemCount: group.members.length,
            itemBuilder: (context, innerIdx) {
              final m = group.members[innerIdx];
              return Padding(
                key: ValueKey('m-${m.routineExercise.id}'),
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
  });

  final FullRoutineExercise fullExercise;
  final int routineId;
  final bool reorderMode;

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
    final tile = ListTile(
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
      onTap: reorderMode
          ? null
          : () => context.push(
                '/routines/$routineId/exercises/${fullExercise.routineExercise.id}',
              ),
    );
    return Card(
      margin: EdgeInsets.zero,
      child: tile,
    );
  }
}
