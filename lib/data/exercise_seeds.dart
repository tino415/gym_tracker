import 'database.dart' show exerciseKindReps, exerciseKindTime;
import 'muscle_seeds.dart';
import 'repositories.dart';

/// One starter exercise: display name, the muscles it targets (names from
/// [muscleSeeds]), and its kind.
class ExerciseSeed {
  const ExerciseSeed(
    this.name,
    this.muscles, {
    this.kind = exerciseKindReps,
  });

  final String name;
  final List<String> muscles;
  final String kind;
}

/// The library a new install starts with.
///
/// Sourced from the exercise set collected in the production project — a real,
/// used library rather than an invented one — with obvious typos corrected,
/// missing muscle tags filled in from each movement's two-sided base, and
/// common barbell/machine basics added that the source happened not to contain.
///
/// Left/right variants are kept: they are the honest model for single-sided
/// work, since each side carries its own load and progresses separately, and
/// pairing them in a circuit is what the per-exercise rest is for.
///
/// Muscle names must match [muscleSeeds] exactly — [seedStarterExercises]
/// resolves them through [muscleSyncId], and an unknown name would silently
/// tag nothing.
const exerciseSeeds = <ExerciseSeed>[
  // -- Chest ---------------------------------------------------------------
  ExerciseSeed('Barbell bench press', ['Chest', 'Triceps', 'Shoulders']),
  ExerciseSeed('Incline barbell bench press', ['Chest', 'Shoulders']),
  ExerciseSeed('Bench press dumbbell', ['Chest']),
  ExerciseSeed('Chest fly dumbbell', ['Chest']),
  ExerciseSeed('Push up', ['Chest', 'Triceps']),
  ExerciseSeed('Decline wide push up', ['Chest']),
  ExerciseSeed('Parallel bars dips', ['Chest', 'Triceps']),
  ExerciseSeed('Cable chest fly', ['Chest']),

  // -- Back ----------------------------------------------------------------
  ExerciseSeed('Pull up', ['Back']),
  ExerciseSeed('Chin up', ['Back', 'Biceps']),
  ExerciseSeed('Barbell row', ['Back', 'Biceps']),
  ExerciseSeed('Dumbbell row', ['Back']),
  ExerciseSeed('Cable lat pull down', ['Back']),
  ExerciseSeed('Narrow MAG cable pull down', ['Back']),
  ExerciseSeed('Wide MAG cable lat pull down', ['Back']),
  ExerciseSeed('Straight arm lat pull down', ['Back']),
  ExerciseSeed('Wide grip cable row', ['Back']),
  ExerciseSeed('Wide MAG cable row', ['Back']),
  ExerciseSeed('Seated cable row', ['Back', 'Biceps']),

  // -- Shoulders -----------------------------------------------------------
  ExerciseSeed('Overhead press', ['Shoulders', 'Triceps']),
  ExerciseSeed('Shoulder press machine', ['Shoulders']),
  ExerciseSeed('Seated dumbbell lateral raise', ['Shoulders']),
  ExerciseSeed('Face pull', ['Shoulders', 'Back']),
  ExerciseSeed('Barbell shrug', ['Shoulders', 'Back']),

  // -- Arms ----------------------------------------------------------------
  ExerciseSeed('Cable biceps curl', ['Biceps']),
  ExerciseSeed('Dumbbell hammer curl', ['Biceps']),
  ExerciseSeed('Barbell curl', ['Biceps', 'Forearms']),
  ExerciseSeed('Skull crusher dumbbell', ['Triceps']),
  ExerciseSeed('Overhead cable triceps extension', ['Triceps']),
  ExerciseSeed('Seated overhead dumbbell extension', ['Triceps']),
  ExerciseSeed('Triceps push down', ['Triceps']),

  // -- Legs ----------------------------------------------------------------
  ExerciseSeed('Barbell back squat', ['Quads', 'Glutes']),
  ExerciseSeed('Front squat', ['Quads']),
  ExerciseSeed('Leg press', ['Quads', 'Glutes']),
  ExerciseSeed('Leg extension machine', ['Quads']),
  ExerciseSeed('Lying leg curl machine', ['Hamstrings']),
  ExerciseSeed('Deadlift', ['Hamstrings', 'Glutes', 'Back']),
  ExerciseSeed('Romanian deadlift', ['Hamstrings', 'Glutes']),
  ExerciseSeed('Romanian deadlift with dumbbell', ['Hamstrings', 'Glutes']),
  ExerciseSeed('Hip thrust', ['Glutes']),
  ExerciseSeed('Walking lunge', ['Quads', 'Glutes']),
  ExerciseSeed('Bulgarian split squat', ['Quads', 'Hamstrings']),
  ExerciseSeed('Bulgarian split squat left', ['Quads', 'Hamstrings']),
  ExerciseSeed('Bulgarian split squat right', ['Quads', 'Hamstrings']),
  ExerciseSeed('Calves extension machine on Hack', ['Calves']),
  ExerciseSeed('Calves extension on Smith Machine', ['Calves']),
  ExerciseSeed('Single leg calf raise', ['Calves']),
  ExerciseSeed('Single leg calf raise left', ['Calves']),
  ExerciseSeed('Single leg calf raise right', ['Calves']),

  // -- Core ----------------------------------------------------------------
  ExerciseSeed('Plank', ['Abs'], kind: exerciseKindTime),
  ExerciseSeed('Side plank', ['Abs'], kind: exerciseKindTime),
  ExerciseSeed('Side plank left', ['Abs'], kind: exerciseKindTime),
  ExerciseSeed('Side plank right', ['Abs'], kind: exerciseKindTime),
  ExerciseSeed('Hanging leg raise', ['Abs']),
  ExerciseSeed("Captain's chair straight leg raise", ['Abs']),
  ExerciseSeed('Reverse crunch', ['Abs']),
  ExerciseSeed('Weighted decline sit-up', ['Abs']),
  ExerciseSeed('Dead bug', ['Abs']),

  // -- TRX / suspension ----------------------------------------------------
  ExerciseSeed('TRX Biceps curl', ['Biceps']),
  ExerciseSeed('TRX Triceps extension', ['Triceps']),
  ExerciseSeed('TRX Face pull', ['Back', 'Shoulders']),
  ExerciseSeed('TRX Fallout', ['Abs', 'Chest', 'Shoulders']),
  ExerciseSeed('TRX High row', ['Back']),
  ExerciseSeed('TRX Low row', ['Back']),
  ExerciseSeed('TRX Pike', ['Abs']),
  ExerciseSeed('TRX Suspended push-up', ['Chest', 'Shoulders']),
  ExerciseSeed('TRX Bulgarian split squat', ['Quads']),
  ExerciseSeed('TRX Bulgarian split squat left', ['Quads']),
  ExerciseSeed('TRX Bulgarian split squat right', ['Quads']),
  ExerciseSeed('TRX Pistol squat', ['Quads']),
  ExerciseSeed('TRX Pistol squat left', ['Quads']),
  ExerciseSeed('TRX Pistol squat right', ['Quads']),
  ExerciseSeed('TRX Single leg Romanian deadlift', ['Hamstrings']),
  ExerciseSeed('TRX Single leg Romanian deadlift left', ['Hamstrings']),
  ExerciseSeed('TRX Single leg Romanian deadlift right', ['Hamstrings']),

  // -- Conditioning (time-kind) --------------------------------------------
  ExerciseSeed(
    'Burpees',
    ['Chest', 'Quads', 'Shoulders', 'Hamstrings', 'Glutes'],
    kind: exerciseKindTime,
  ),
  ExerciseSeed('Jumping jacks', ['Calves', 'Quads', 'Shoulders'],
      kind: exerciseKindTime),
  ExerciseSeed('March in place', ['Quads', 'Calves'],
      kind: exerciseKindTime),
  ExerciseSeed('Mountain climbers', ['Abs', 'Quads'],
      kind: exerciseKindTime),
];

/// Fills a pristine library with [exerciseSeeds]. Returns whether it wrote.
///
/// Refuses on *any* existing exercise row, tombstones included — which is what
/// keeps it from resurrecting exercises the user deleted. That guard matters
/// because [ExerciseRepository.createExercise] reconciles by name and revives a
/// tombstone rather than failing on the UNIQUE name, so seeding into a library
/// someone had already pruned would quietly bring their deletions back.
///
/// Goes through the repository seam, so it behaves the same on the Drift
/// (phone/watch) and Firestore-direct (web) backends.
Future<bool> seedStarterExercises({
  required ExerciseRepository exercises,
}) async {
  if (await exercises.hasAnyExercise()) return false;
  for (final seed in exerciseSeeds) {
    final created = await exercises.createExercise(seed.name, kind: seed.kind);
    if (seed.muscles.isEmpty) continue;
    await exercises.setExerciseMuscles(
      created.syncId,
      [for (final m in seed.muscles) muscleSyncId(m)],
    );
  }
  return true;
}
