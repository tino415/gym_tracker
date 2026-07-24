/// The fixed muscle reference set.
///
/// Muscle identity is deterministic — the syncId is derived from the name via
/// [muscleSyncId] — so every install (phone, watch, and the server-backed web
/// build) agrees on muscles without syncing them. This is why muscles need no
/// Firestore collection: the same list, seeded the same way, yields the same
/// syncIds everywhere.
///
/// When user-defined muscles land, this list becomes the seed for a synced
/// `users/{uid}/muscles` collection layered on top.
const muscleSeeds = <String>[
  'Chest',
  'Back',
  'Shoulders',
  'Biceps',
  'Triceps',
  'Forearms',
  'Abs',
  'Quads',
  'Hamstrings',
  'Glutes',
  'Calves',
];

/// Deterministic syncId for a seeded muscle. Derived from the name so all
/// platforms agree on identity without a sync round-trip.
String muscleSyncId(String name) => 'muscle:${name.toLowerCase()}';
