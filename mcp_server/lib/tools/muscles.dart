import 'package:gym_tracker/data/muscle_seeds.dart';

final _nameById = {for (final name in muscleSeeds) muscleSyncId(name): name};

/// Known muscles only, ordered by name, as the phone exports them.
List<String> knownMuscleIds(Iterable<String> ids) =>
    [
      for (final id in ids.toSet())
        if (_nameById.containsKey(id)) id,
    ]..sort((a, b) => _nameById[a]!.compareTo(_nameById[b]!));

List<String> muscleNames(Iterable<String> ids) => [
  for (final id in knownMuscleIds(ids)) _nameById[id]!,
];

String? muscleIdNamed(String name) {
  for (final seed in muscleSeeds) {
    if (seed.toLowerCase() == name.trim().toLowerCase()) {
      return muscleSyncId(seed);
    }
  }
  return null;
}
