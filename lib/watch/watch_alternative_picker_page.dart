import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/providers.dart';
import 'widgets/round_safe_area.dart';

/// Mid-workout exercise swap. Shows the routine slot's other variants —
/// primary + alternatives, minus the active one — so the user can swap with a
/// single tap. Closes itself on selection; the run page's stream picks up the
/// change automatically.
class WatchAlternativePickerPage extends ConsumerStatefulWidget {
  const WatchAlternativePickerPage({super.key, required this.workoutExerciseId});

  final int workoutExerciseId;

  @override
  ConsumerState<WatchAlternativePickerPage> createState() =>
      _WatchAlternativePickerPageState();
}

class _WatchAlternativePickerPageState
    extends ConsumerState<WatchAlternativePickerPage> {
  late Future<List<Exercise>> _altsFuture;

  @override
  void initState() {
    super.initState();
    _altsFuture = ref
        .read(databaseProvider)
        .loadAlternativesForWorkoutExercise(widget.workoutExerciseId);
  }

  Future<void> _pick(Exercise ex) async {
    await ref.read(databaseProvider).swapWorkoutExercise(
          workoutExerciseId: widget.workoutExerciseId,
          newExerciseId: ex.id,
        );
    if (!mounted) return;
    // Pop with `true` so the run page knows to reload the active set's
    // targets (the stream invalidates the snapshot but, by design, does not
    // touch the in-memory stepper values).
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: RoundSafeArea(
        child: FutureBuilder<List<Exercise>>(
          future: _altsFuture,
          builder: (context, snap) {
            if (!snap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final alts = snap.data!;
            if (alts.isEmpty) return const _EmptyState();
            final isRound = WatchShapeScope.of(context);
            final vGap = isRound ? 36.0 : 8.0;
            return ListView.builder(
              padding: EdgeInsets.fromLTRB(16, vGap, 16, vGap),
              itemCount: alts.length,
              itemBuilder: (context, i) {
                final ex = alts[i];
                return InkWell(
                  onTap: () => _pick(ex),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: 12,
                      horizontal: 12,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Text(
                          ex.name,
                          style: Theme.of(context).textTheme.titleMedium,
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          ex.kind == exerciseKindTime ? 'Time' : 'Reps',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          'No alternatives.\nAdd some in the routine on the phone.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ),
    );
  }
}
