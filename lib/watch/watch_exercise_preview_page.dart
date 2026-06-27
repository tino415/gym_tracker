import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../data/database.dart';
import 'set_target_format.dart';
import 'widgets/round_safe_area.dart';

/// Read-only preview of a single exercise on the watch: its name, kind, rest
/// interval, and the list of planned sets. Reached by tapping an exercise in
/// the run page's list view. Does not touch the active set cursor or any
/// timer — opening it is safe at any phase, including while the rest timer
/// is running.
class WatchExercisePreviewPage extends StatelessWidget {
  const WatchExercisePreviewPage._({
    required this.name,
    required this.kind,
    required this.restSeconds,
    required this.supersetGroup,
    required List<_PreviewSet> sets,
    required this.activeMode,
    this.restCountdown,
    this.onSwitchActive,
  }) : _sets = sets;

  factory WatchExercisePreviewPage.fromRoutine(FullRoutineExercise re) {
    return WatchExercisePreviewPage._(
      name: re.exercise.name,
      kind: re.kind,
      restSeconds: re.routineExercise.restSeconds,
      supersetGroup: re.routineExercise.supersetGroup,
      sets: [
        for (var i = 0; i < re.plannedSets.length; i++)
          _PreviewSet(
            index: i,
            targetReps: re.plannedSets[i].targetReps,
            targetWeightKg: re.plannedSets[i].targetWeightKg,
            targetSeconds: re.plannedSets[i].targetSeconds,
            completed: false,
          ),
      ],
      activeMode: false,
    );
  }

  factory WatchExercisePreviewPage.fromWorkout(
    FullWorkoutExercise we, {
    ValueListenable<int>? restCountdown,
    VoidCallback? onSwitchActive,
  }) {
    return WatchExercisePreviewPage._(
      name: we.workoutExercise.exerciseName,
      kind: we.kind,
      restSeconds: we.workoutExercise.restSeconds,
      supersetGroup: we.workoutExercise.supersetGroup,
      sets: [
        for (var i = 0; i < we.sets.length; i++)
          _PreviewSet(
            index: i,
            targetReps: we.sets[i].workoutSet.targetReps,
            targetWeightKg: we.sets[i].workoutSet.targetWeightKg,
            targetSeconds: we.sets[i].workoutSet.targetSeconds,
            completed: we.sets[i].completion != null,
          ),
      ],
      activeMode: true,
      restCountdown: restCountdown,
      onSwitchActive: onSwitchActive,
    );
  }

  final String name;
  final String kind;
  final int restSeconds;
  final int? supersetGroup;
  final List<_PreviewSet> _sets;
  final bool activeMode;
  final ValueListenable<int>? restCountdown;
  final VoidCallback? onSwitchActive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isRound = WatchShapeScope.of(context);
    final hInset = isRound ? 12.0 : 8.0;
    return Scaffold(
      body: RoundSafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (restCountdown != null)
              _RestPill(
                countdown: restCountdown!,
                onTap: () => Navigator.of(context).pop(),
              ),
            Expanded(
              child: ListView(
                padding: EdgeInsets.symmetric(
                  horizontal: hInset,
                  vertical: 4,
                ),
                children: [
                  Text(
                    name,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      height: 1.15,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      _MetaChip(
                        icon: kind == exerciseKindTime
                            ? Icons.timer_outlined
                            : Icons.repeat,
                        label: kind == exerciseKindTime ? 'Time' : 'Reps',
                      ),
                      _MetaChip(
                        icon: Icons.hourglass_bottom,
                        label: 'rest ${restSeconds}s',
                      ),
                      if (supersetGroup != null)
                        _MetaChip(
                          icon: Icons.link,
                          label: 'superset',
                          color: theme.colorScheme.primary,
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  if (_sets.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        'No planned sets.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                    )
                  else
                    for (final s in _sets)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: _SetLine(
                          set: s,
                          kind: kind,
                          activeMode: activeMode,
                        ),
                      ),
                ],
              ),
            ),
            if (onSwitchActive != null)
              Padding(
                padding: EdgeInsets.fromLTRB(hInset, 4, hInset, isRound ? 20 : 8),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: onSwitchActive,
                    icon: const Icon(Icons.play_arrow, size: 16),
                    label: const Text('Switch to this'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(32),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PreviewSet {
  const _PreviewSet({
    required this.index,
    required this.targetReps,
    required this.targetWeightKg,
    required this.targetSeconds,
    required this.completed,
  });

  final int index;
  final int? targetReps;
  final double? targetWeightKg;
  final int? targetSeconds;
  final bool completed;
}

class _SetLine extends StatelessWidget {
  const _SetLine({
    required this.set,
    required this.kind,
    required this.activeMode,
  });

  final _PreviewSet set;
  final String kind;
  final bool activeMode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.outline;
    final color = activeMode && !set.completed ? muted : null;
    return Row(
      children: [
        SizedBox(
          width: 18,
          child: activeMode && set.completed
              ? Icon(
                  Icons.check,
                  size: 14,
                  color: theme.colorScheme.primary,
                )
              : Text(
                  '${set.index + 1}.',
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                ),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            _formatTarget(set, kind),
            style: theme.textTheme.bodyMedium?.copyWith(color: color),
          ),
        ),
      ],
    );
  }

  static String _formatTarget(_PreviewSet s, String kind) => formatSetTarget(
        kind: kind,
        reps: s.targetReps,
        weightKg: s.targetWeightKg,
        seconds: s.targetSeconds,
      );
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.icon, required this.label, this.color});

  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = color ?? theme.colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: c),
          const SizedBox(width: 3),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(color: c),
          ),
        ],
      ),
    );
  }
}

class _RestPill extends StatelessWidget {
  const _RestPill({required this.countdown, required this.onTap});

  final ValueListenable<int> countdown;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<int>(
      valueListenable: countdown,
      builder: (context, seconds, _) {
        if (seconds <= 0) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.fromLTRB(8, 2, 8, 4),
          child: Material(
            color: scheme.primaryContainer,
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 4,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.hourglass_bottom,
                      size: 12,
                      color: scheme.onPrimaryContainer,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'Rest ${seconds}s',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.onPrimaryContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
