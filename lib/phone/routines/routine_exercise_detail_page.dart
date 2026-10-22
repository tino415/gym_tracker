import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/database.dart';
import '../../data/providers.dart';
import '../../l10n/l10n.dart';
import '../number_format.dart';
import 'exercise_picker.dart';
import 'planned_set_row.dart';
import 'set_editor_dialog.dart';

/// How wide a dialog on this page is allowed to get.
///
/// An [AlertDialog] sizes itself to the *intrinsic* width of its content, and a
/// one-line sentence wants to stay on one line — so on a desktop browser the
/// remove-exercise confirmation stretched to 931px at a 1400px viewport.
///
/// Capping only helps where the content's own intrinsic width is what makes the
/// dialog wide. Once the width is settled the dialog stretches its children
/// with *tight* constraints, so wrapping an already-narrow child (a text field,
/// say) in the same cap does nothing.
const double routineDialogMaxWidth = 360;

/// Detail page for a single routine slot. Owns the full per-exercise editor —
/// planned sets, alternatives, rest, kind, circuit toggle, remove. The list
/// page only shows a compact summary; everything write-heavy lives here.
class RoutineExerciseDetailPage extends ConsumerWidget {
  const RoutineExerciseDetailPage({
    super.key,
    required this.routineId,
    required this.routineExerciseId,
    this.embedded = false,
    this.showBack = false,
    this.onClose,
  });

  final String routineId;
  final String routineExerciseId;

  /// Hosted in the Routines wide master-detail (a detail/third pane) rather than
  /// pushed as a route: no back stack, so removal and the deleted-slot auto-pop
  /// report out via [onClose] instead of `context.pop()`.
  final bool embedded;

  /// Show a leading back button (2-pane: returns to the routine editor). In
  /// 3-pane the set editor is a persistent third column, so no back button.
  final bool showBack;

  /// Called to close the set editor (clear the exercise selection).
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fullAsync = ref.watch(fullRoutineProvider(routineId));
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !embedded,
        leading: (embedded && showBack)
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                tooltip: context.l10n.routineBackToRoutine,
                onPressed: onClose,
              )
            : null,
        title: fullAsync.when(
          loading: () => const Text('…'),
          error: (_, _) => Text(context.l10n.commonErrorShort),
          data: (full) {
            final re = _find(full);
            return Text(re?.exercise.name ?? '');
          },
        ),
      ),
      body: fullAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(context.l10n.commonError('$e'))),
        data: (full) {
          final re = _find(full);
          if (re == null || full == null) {
            // Routine exercise vanished (removed, or a concurrent sync apply).
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (embedded) {
                onClose?.call();
              } else if (context.mounted) {
                context.pop();
              }
            });
            return const SizedBox.shrink();
          }
          return _Body(
            full: full,
            re: re,
            onRemoved: embedded ? onClose : null,
          );
        },
      ),
    );
  }

  FullRoutineExercise? _find(FullRoutine? full) {
    if (full == null) return null;
    for (final e in full.exercises) {
      if (e.routineExercise.syncId == routineExerciseId) return e;
    }
    return null;
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.full, required this.re, this.onRemoved});

  final FullRoutine full;
  final FullRoutineExercise re;

  /// When embedded, called after removing the exercise instead of popping.
  final VoidCallback? onRemoved;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final idx = full.exercises.indexWhere(
      (e) => e.routineExercise.syncId == re.routineExercise.syncId,
    );
    final isFirst = idx == 0;
    final groupedWithPrev = !isFirst &&
        re.routineExercise.circuitGroup != null &&
        re.routineExercise.circuitGroup ==
            full.exercises[idx - 1].routineExercise.circuitGroup;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        Row(
          children: [
            Icon(
              re.kind == exerciseKindTime
                  ? Icons.timer_outlined
                  : Icons.repeat,
              size: 20,
            ),
            const SizedBox(width: 8),
            Chip(
              label: Text(
                re.kind == exerciseKindTime
                    ? context.l10n.commonTime
                    : context.l10n.commonReps,
              ),
              visualDensity: VisualDensity.compact,
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: () => _editRest(context, ref, re.routineExercise),
              icon: const Icon(Icons.timer_outlined, size: 18),
              label: Text(
                re.routineExercise.restSeconds == 0
                    ? context.l10n.routineNoRest
                    : context.l10n.routineRestSeconds(
                        re.routineExercise.restSeconds,
                      ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (!isFirst)
          Align(
            alignment: Alignment.centerLeft,
            child: FilterChip(
              selected: groupedWithPrev,
              onSelected: (_) =>
                  _toggleCircuit(ref, full, re, idx),
              label: Text(context.l10n.routineCircuitWithPrevious),
              avatar: Icon(
                groupedWithPrev ? Icons.link : Icons.link_off,
                size: 16,
              ),
            ),
          ),
        const Divider(height: 24),
        Row(
          children: [
            Text(context.l10n.routineSets, style: theme.textTheme.titleMedium),
            const Spacer(),
            TextButton.icon(
              onPressed: () => _editSetDialog(context, ref, re: re),
              icon: const Icon(Icons.add, size: 18),
              label: Text(context.l10n.routineAddSet),
            ),
          ],
        ),
        if (re.plannedSets.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              context.l10n.routineNoSetsYet,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          )
        else
          for (var i = 0; i < re.plannedSets.length; i++)
            PlannedSetRow(
              key: ValueKey(re.plannedSets[i].syncId),
              setIndex: i,
              plannedSet: re.plannedSets[i],
              kind: re.kind,
              onEdit: () => _editSetDialog(
                context,
                ref,
                re: re,
                existing: re.plannedSets[i],
              ),
              onDelete: () => ref
                  .read(routineRepositoryProvider)
                  .deletePlannedSet(re.plannedSets[i].syncId),
            ),
        const Divider(height: 24),
        Row(
          children: [
            Icon(Icons.swap_horiz, size: 18, color: theme.colorScheme.outline),
            const SizedBox(width: 4),
            Text(context.l10n.routineAlternatives, style: theme.textTheme.titleMedium),
            const Spacer(),
            TextButton.icon(
              onPressed: () => _addAlternative(context, ref, re),
              icon: const Icon(Icons.add, size: 18),
              label: Text(context.l10n.commonAdd),
            ),
          ],
        ),
        if (re.alternatives.isEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 4, top: 4, bottom: 4),
            child: Text(
              context.l10n.routineAlternativesHint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          )
        else
          for (final alt in re.alternatives)
            _AlternativeTile(
              parentKind: re.kind,
              alternative: alt,
              onDelete: () => ref
                  .read(routineRepositoryProvider)
                  .removeRoutineExerciseAlternative(alt.join.syncId),
              onAddSet: () => _editAltSetDialog(context, ref, alt: alt),
              onEditSet: (s) =>
                  _editAltSetDialog(context, ref, alt: alt, existing: s),
              onDeleteSet: (s) => ref
                  .read(routineRepositoryProvider)
                  .deleteAlternativePlannedSet(s.syncId),
            ),
        const Divider(height: 32),
        OutlinedButton.icon(
          onPressed: () =>
              confirmRemoveRoutineExercise(context, ref, re, onRemoved: onRemoved),
          icon: const Icon(Icons.delete_outline),
          label: Text(context.l10n.routineRemoveFromRoutine),
          style: OutlinedButton.styleFrom(
            foregroundColor: theme.colorScheme.error,
          ),
        ),
      ],
    );
  }
}

/// Confirms and removes [re] from its routine. Shared with the routine
/// editor's list rows so both entry points ask the same question and warn
/// about the same thing (past workouts keep their snapshot).
///
/// [onRemoved] runs instead of popping when the caller owns the navigation —
/// the wide master-detail panes have no route to pop.
Future<void> confirmRemoveRoutineExercise(
  BuildContext context,
  WidgetRef ref,
  FullRoutineExercise re, {
  VoidCallback? onRemoved,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(ctx.l10n.routineRemoveExerciseTitle),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: routineDialogMaxWidth),
        child: Text(ctx.l10n.routineRemoveExerciseBody(re.exercise.name)),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(ctx.l10n.commonCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(ctx.l10n.commonRemove),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  await ref.read(routineRepositoryProvider).removeRoutineExercise(re.routineExercise.syncId);
  if (!context.mounted) return;
  if (onRemoved != null) {
    onRemoved();
  } else {
    context.pop();
  }
}

Future<void> _editRest(
  BuildContext context,
  WidgetRef ref,
  RoutineExercise re,
) async {
  final controller = TextEditingController(text: re.restSeconds.toString());
  final result = await showDialog<int>(
    context: context,
    builder: (ctx) => AlertDialog(
      // Names the exercise, not "between sets": in a circuit this is the pause
      // before the *next member*, and 0 makes the next set follow immediately.
      title: Text(ctx.l10n.routineRestAfterTitle),
      content: TextField(
        controller: controller,
        autofocus: true,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(suffixText: ctx.l10n.routineSecondsSuffix),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text(ctx.l10n.commonCancel),
        ),
        FilledButton(
          onPressed: () {
            final parsed = int.tryParse(controller.text.trim());
            Navigator.of(ctx).pop(parsed);
          },
          child: Text(ctx.l10n.commonSave),
        ),
      ],
    ),
  );
  // Guard against the page unmounting during the dialog await (e.g. a
  // concurrent sync bundle-apply pops it): using ref/context afterwards throws.
  //
  // 0 is accepted, and means "no pause, go straight to the next set" — how a
  // classic superset is expressed now that rest follows every set. Only a
  // negative (or unparseable) entry is rejected.
  if (result != null && result >= 0 && context.mounted) {
    await ref.read(routineRepositoryProvider).setRestSeconds(re.syncId, result);
  }
}

Future<void> _toggleCircuit(
  WidgetRef ref,
  FullRoutine full,
  FullRoutineExercise current,
  int idx,
) async {
  if (idx == 0) return; // first slot has no previous to group with
  final db = ref.read(routineRepositoryProvider);
  final prev = full.exercises[idx - 1];
  final currentGroup = current.routineExercise.circuitGroup;
  if (currentGroup != null &&
      currentGroup == prev.routineExercise.circuitGroup) {
    await db.setCircuitGroup(current.routineExercise.syncId, null);
    return;
  }
  int group;
  if (prev.routineExercise.circuitGroup != null) {
    group = prev.routineExercise.circuitGroup!;
  } else {
    var max = 0;
    for (final re in full.exercises) {
      final g = re.routineExercise.circuitGroup;
      if (g != null && g > max) max = g;
    }
    group = max + 1;
    await db.setCircuitGroup(prev.routineExercise.syncId, group);
  }
  await db.setCircuitGroup(current.routineExercise.syncId, group);
}

Future<void> _addAlternative(
  BuildContext context,
  WidgetRef ref,
  FullRoutineExercise re,
) async {
  final excludeIds = <String>{
    re.exercise.syncId,
    ...re.alternatives.map((a) => a.exercise.syncId),
  };
  final picked = await showExercisePicker(
    context,
    ref,
    excludeIds: excludeIds,
  );
  // Guard: the picker await may outlive the page (a concurrent sync
  // bundle-apply can pop it), and ref.read on a defunct ref throws.
  if (picked == null || !context.mounted) return;
  await ref.read(routineRepositoryProvider).addRoutineExerciseAlternative(
        routineExerciseId: re.routineExercise.syncId,
        exerciseId: picked.syncId,
      );
}

void _editSetDialog(
  BuildContext context,
  WidgetRef ref, {
  required FullRoutineExercise re,
  PlannedSet? existing,
}) {
  final db = ref.read(routineRepositoryProvider);
  final reId = re.routineExercise.syncId;
  showDialog<void>(
    context: context,
    builder: (_) => SetEditorDialog(
      kind: re.kind,
      existingId: existing?.syncId,
      initialReps: existing?.targetReps,
      initialWeightKg: existing?.targetWeightKg,
      initialSeconds: existing?.targetSeconds,
      onAdd: (v) => db.addPlannedSet(
        routineExerciseId: reId,
        targetReps: v.reps,
        targetWeightKg: v.weightKg,
        targetSeconds: v.seconds,
      ),
      onUpdate: (id, v) => db.updatePlannedSet(
        id: id,
        targetReps: v.reps,
        targetWeightKg: v.weightKg,
        targetSeconds: v.seconds,
      ),
    ),
  );
}

void _editAltSetDialog(
  BuildContext context,
  WidgetRef ref, {
  required RoutineAlternative alt,
  AlternativePlannedSet? existing,
}) {
  final db = ref.read(routineRepositoryProvider);
  final altId = alt.join.syncId;
  showDialog<void>(
    context: context,
    builder: (_) => SetEditorDialog(
      kind: alt.exercise.kind,
      existingId: existing?.syncId,
      initialReps: existing?.targetReps,
      initialWeightKg: existing?.targetWeightKg,
      initialSeconds: existing?.targetSeconds,
      onAdd: (v) => db.addAlternativePlannedSet(
        alternativeId: altId,
        targetReps: v.reps,
        targetWeightKg: v.weightKg,
        targetSeconds: v.seconds,
      ),
      onUpdate: (id, v) => db.updateAlternativePlannedSet(
        id: id,
        targetReps: v.reps,
        targetWeightKg: v.weightKg,
        targetSeconds: v.seconds,
      ),
    ),
  );
}

class _AlternativeTile extends StatelessWidget {
  const _AlternativeTile({
    required this.parentKind,
    required this.alternative,
    required this.onDelete,
    required this.onAddSet,
    required this.onEditSet,
    required this.onDeleteSet,
  });

  final String parentKind;
  final RoutineAlternative alternative;
  final VoidCallback onDelete;
  final VoidCallback onAddSet;
  final void Function(AlternativePlannedSet) onEditSet;
  final void Function(AlternativePlannedSet) onDeleteSet;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ex = alternative.exercise;
    final ps = alternative.plannedSets;
    final hint = ps.isEmpty
        ? context.l10n.routineUsesPrimaryTargets
        : context.l10n.routineSetCount(ps.length);
    return Theme(
      data: theme.copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 4),
        leading: Icon(
          ex.kind == exerciseKindTime ? Icons.timer_outlined : Icons.repeat,
          size: 18,
        ),
        title: Text(ex.name, style: theme.textTheme.bodyLarge),
        subtitle: Text(
          hint,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
        trailing: IconButton(
          onPressed: onDelete,
          icon: const Icon(Icons.delete_outline, size: 18),
          tooltip: context.l10n.routineRemoveAlternative,
        ),
        childrenPadding: const EdgeInsets.only(left: 12, right: 4, bottom: 8),
        children: [
          for (var i = 0; i < ps.length; i++)
            _AlternativePlannedSetRow(
              index: i,
              kind: ex.kind,
              set: ps[i],
              onEdit: () => onEditSet(ps[i]),
              onDelete: () => onDeleteSet(ps[i]),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: onAddSet,
              icon: const Icon(Icons.add, size: 18),
              label: Text(context.l10n.routineAddSet),
            ),
          ),
        ],
      ),
    );
  }
}

class _AlternativePlannedSetRow extends StatelessWidget {
  const _AlternativePlannedSetRow({
    required this.index,
    required this.kind,
    required this.set,
    required this.onEdit,
    required this.onDelete,
  });

  final int index;
  final String kind;
  final AlternativePlannedSet set;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  String _describe(BuildContext context) {
    final l10n = context.l10n;
    if (kind == exerciseKindTime) {
      final s = set.targetSeconds;
      final w = set.targetWeightKg;
      if (s == null && w == null) return '—';
      final parts = <String>[];
      if (s != null) parts.add(l10n.routineSecondsShort(s));
      if (w != null && w > 0) parts.add(l10n.commonWeightKg(formatKg(context, w)));
      return parts.join(' · ');
    }
    final r = set.targetReps;
    final w = set.targetWeightKg;
    if (r == null && w == null) return '—';
    final parts = <String>[];
    if (r != null) parts.add(l10n.routineRepsCount(r));
    if (w != null) parts.add(l10n.commonWeightKg(formatKg(context, w)));
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onEdit,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
        child: Row(
          children: [
            SizedBox(
              width: 28,
              child: Text(
                '${index + 1}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.outline,
                    ),
              ),
            ),
            Expanded(child: Text(_describe(context))),
            IconButton(
              onPressed: onDelete,
              icon: const Icon(Icons.close, size: 16),
              tooltip: context.l10n.routineRemoveSet,
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      ),
    );
  }
}
