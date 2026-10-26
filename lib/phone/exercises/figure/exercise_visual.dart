import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/database.dart';
import '../../../data/providers.dart';
import '../muscle_map.dart';
import 'figure_painter.dart';
import 'figure_poses.dart';

/// The exercise's figure when it has a pose, otherwise the body map.
class ExerciseVisual extends StatelessWidget {
  const ExerciseVisual({super.key, required this.exerciseId, required this.highlighted});

  final String? exerciseId;
  final Set<String> highlighted;

  @override
  Widget build(BuildContext context) {
    final placement = figureFor(exerciseId);
    if (placement == null) return MuscleMap(highlighted: highlighted);
    return ExerciseFigure(placement: placement);
  }
}

final _exerciseMusclesProvider = FutureProvider.autoDispose.family<List<Muscle>, String>(
  (ref, exerciseId) => ref.watch(exerciseRepositoryProvider).musclesForExercise(exerciseId),
);

/// [ExerciseVisual] for a place that only knows the exercise id.
class ExerciseVisualById extends ConsumerWidget {
  const ExerciseVisualById({super.key, required this.exerciseId});

  final String? exerciseId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = exerciseId;
    if (id == null) return const SizedBox.shrink();
    final placement = figureFor(id);
    if (placement != null) return ExerciseFigure(placement: placement);
    final muscles = ref.watch(_exerciseMusclesProvider(id)).value ?? const [];
    return MuscleMap(highlighted: {for (final m in muscles) m.syncId});
  }
}

class ExerciseThumbnail extends StatelessWidget {
  const ExerciseThumbnail({super.key, required this.exerciseId, required this.muscles});

  static const size = 44.0;

  final String exerciseId;
  final List<Muscle> muscles;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: Center(
            child: ExerciseVisual(
              exerciseId: exerciseId,
              highlighted: {for (final m in muscles) m.syncId},
            ),
          ),
        ),
      ),
    );
  }
}
