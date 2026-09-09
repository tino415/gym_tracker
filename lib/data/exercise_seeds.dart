import 'database.dart' show CatalogExercise, exerciseKindReps, exerciseKindTime;
import 'muscle_seeds.dart';
import 'repositories.dart';

/// One starter exercise: display name, the muscles it targets (names from
/// [muscleSeeds]), its kind, and the id it is seeded under.
class ExerciseSeed {
  const ExerciseSeed(
    this.name,
    this.muscles, {
    required this.id,
    this.kind = exerciseKindReps,
  });

  /// Identity, fixed forever. Two installs seeding this entry must agree on it,
  /// which is what stops a second device writing a duplicate document for a
  /// name the account already has.
  ///
  /// Never derive it from [name] and never edit it when a name is corrected.
  /// Most are the ids the source library already used, so a device seeding into
  /// that account upserts onto the documents it already has instead of creating
  /// new ones; the rest were generated once for entries the source lacked.
  final String id;

  final String name;
  final List<String> muscles;
  final String kind;
}

/// Whether this build seeds the starter library at all. On unless built with
/// `--dart-define=SEED_STARTER=false` (`just SEED_STARTER=false phone-apk`).
///
/// It no longer guards against what it was written for. Seeding used to mint a
/// fresh uuid per entry, so a device that seeded and then signed in wrote the
/// whole library again as new documents. [ExerciseSeed.id] and the version
/// guard on the exercise push closed that: a seeded device now writes the ids
/// the account already holds, at version 1, and loses arbitration to anything
/// the account has edited.
///
/// It still matters for one case. An account whose library was created by the
/// *old* uuid-minting seed holds different ids for the same names, so a device
/// seeding into it duplicates by name however well the ids are chosen. Until
/// such an account has been reconciled, build with the seed off and let sync
/// populate it.
const bool seedStarterEnabled =
    bool.fromEnvironment('SEED_STARTER', defaultValue: true);

/// The `createdAt` every seeded row gets, fixed rather than `DateTime.now()`.
///
/// It has to be a constant or two installs seeding the same entry produce DTOs
/// that differ in `createdAtMs` alone. `_upsertOneExercise` never writes
/// `createdAt` on an update, so neither device could ever adopt the other's
/// value, and the two would rewrite all 87 documents against each other on
/// every cold start, forever. Lists order by name, so nothing user-visible
/// depends on it.
final catalogueEpoch = DateTime.utc(2026, 1, 1);

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
///
/// Every entry carries an [ExerciseSeed.id]. Read the note there before adding
/// or editing one: the ids are identity, not decoration.
const exerciseSeeds = <ExerciseSeed>[
  // -- Chest ---------------------------------------------------------------
  ExerciseSeed('Bench press', ['Chest', 'Triceps', 'Shoulders'], id: 'bd70c034-c732-4672-b103-b4b642f9560b'),
  ExerciseSeed('Incline bench press', ['Chest', 'Shoulders'], id: '2a664154-c337-4ec9-a44b-ab0570752e66'),
  ExerciseSeed('Dumbbell bench press', ['Chest'], id: 'aea8d5c9-a64e-4143-b3c1-23fbce2e4c0a'),
  ExerciseSeed('Dumbbell chest fly', ['Chest'], id: '2c9c6e58-cfea-4437-a1fe-60a9c07f1bcb'),
  ExerciseSeed('Mild incline dumbbell bench press', ['Chest', 'Shoulders'], id: '2a2bb0f0-e2e2-4ddf-a1e6-437fe0a9ea3f'),
  ExerciseSeed('Push up', ['Chest', 'Triceps'], id: '838d0ea9-e8f1-446c-90b9-cafe7abf948b'),
  ExerciseSeed('Decline wide push up', ['Chest'], id: '9bc038a7-4f19-46ef-9715-bea24e1dd7b6'),
  ExerciseSeed('Parallel bars dips', ['Chest', 'Triceps'], id: '4f0303e6-8bf6-4d9b-9801-734d8c61a49b'),
  ExerciseSeed('Cable chest fly', ['Chest'], id: 'a7381128-895b-478e-80f6-976b8ca69177'),
  ExerciseSeed('Dumbbell pullover', ['Chest', 'Back'], id: '68ad3fe1-7136-4fe9-8f63-7ddc8dc8c261'),

  // -- Back ----------------------------------------------------------------
  ExerciseSeed('Pull up', ['Back'], id: '9194a380-4f21-4093-8e75-d4c67ed8072e'),
  ExerciseSeed('Chin up', ['Back', 'Biceps'], id: 'ea542f6f-e8a6-44a7-ae24-55af7bcd0d90'),
  ExerciseSeed('Pull up neutral grip', ['Back', 'Biceps'], id: 'dca635a8-e638-48f0-a84e-0445accc68b2'),
  ExerciseSeed('Barbell row', ['Back', 'Biceps'], id: 'ce3931f4-4400-475d-a825-fb66af4825f0'),
  ExerciseSeed('Dumbbell row', ['Back', 'Biceps'], id: 'f790e3d8-cbd3-4476-8da3-4c349850f81c'),
  ExerciseSeed('Chest supported dumbbell row', ['Back', 'Biceps'], id: 'c31ce6c7-bf68-4a8a-be8f-145ad31b85bc'),
  ExerciseSeed('Cable lat pull down', ['Back'], id: 'e105fd21-cd30-49ba-91a5-ba68ea18ea5f'),
  ExerciseSeed('Narrow MAG cable lat pull down', ['Back'], id: 'c561d9f3-4031-48b1-a7d8-141043ea925b'),
  ExerciseSeed('Wide MAG cable lat pull down', ['Back'], id: '21cd13d1-5e37-4455-8b99-c8105878c8e3'),
  ExerciseSeed('Straight arm lat pull down', ['Back'], id: '22dba14b-3529-4c27-926e-5eecebb9c2eb'),
  // "Seated" on all three, not just the plain one: the standing cable row is a
  // common variant in its own right, so the word disambiguates against the
  // world rather than against whatever this list currently happens to contain —
  // and adding a standing row later shouldn't force renaming three entries.
  ExerciseSeed('Seated cable row', ['Back', 'Biceps'], id: '2afb40d4-a538-4584-9313-0efa382d1ec6'),
  ExerciseSeed('Seated wide grip cable row', ['Back', 'Biceps'], id: '0f17c6bd-b446-443a-817e-b9630092679e'),
  ExerciseSeed('Seated wide MAG cable row', ['Back', 'Biceps'], id: 'c9da715b-33ce-42f8-9e88-87b9431922d2'),

  // -- Shoulders -----------------------------------------------------------
  ExerciseSeed('Overhead press', ['Shoulders', 'Triceps'], id: '89e28b79-35ed-4c74-8306-cccd0d06cb16'),
  ExerciseSeed('Shoulder press machine', ['Shoulders'], id: '8eec37fa-e972-40f7-b83b-39bd934f4060'),
  ExerciseSeed('Seated dumbbell lateral raise', ['Shoulders'], id: 'b56c9b50-a840-41b9-9bb7-772fe02f10fe'),
  ExerciseSeed('Face pull', ['Shoulders', 'Back'], id: 'a9c64e10-41f1-4bb3-a698-0d34126f3b2f'),
  ExerciseSeed('Barbell shrug', ['Shoulders', 'Back'], id: '869d70fc-9e7b-463a-a41e-d63d0da80e69'),

  // -- Arms ----------------------------------------------------------------
  ExerciseSeed('Cable biceps curl', ['Biceps'], id: 'eda04b53-dce7-4349-9f19-cd193a2166a6'),
  ExerciseSeed('Dumbbell hammer curl', ['Biceps'], id: '46c6d0a1-abc5-4cf6-b82a-efec6e65e311'),
  ExerciseSeed('Barbell curl', ['Biceps', 'Forearms'], id: '1277b39d-b73a-4fca-bac9-efcf2adb0388'),
  ExerciseSeed('Dumbbell skull crusher', ['Triceps'], id: 'f0ae1f30-2cf7-424c-a35f-46f06abee833'),
  ExerciseSeed('Overhead cable triceps extension', ['Triceps'], id: '22efb320-83ff-4636-8695-96e09fafb304'),
  ExerciseSeed('Seated overhead dumbbell extension', ['Triceps'], id: '7884b8b7-690d-4f8e-9be5-d35578d0745b'),
  ExerciseSeed('Triceps push down', ['Triceps'], id: 'e0bf42c4-8a5d-4c8a-a5fa-5e50ba4e3f7c'),
  ExerciseSeed('Bench dips', ['Triceps', 'Chest'], id: '4cab971b-7df1-43f8-bf4b-6c6787b922b1'),

  // -- Legs ----------------------------------------------------------------
  ExerciseSeed('Back squat', ['Quads', 'Glutes'], id: 'c6beb1bd-0529-47c6-9494-7167a8ecce36'),
  ExerciseSeed('Front squat', ['Quads'], id: '2a0a37a9-d818-4071-b87d-f059a3a859d1'),
  ExerciseSeed('Leg press', ['Quads', 'Glutes'], id: '9c0c6889-56e4-4877-ade3-3ea74c4d6fc6'),
  ExerciseSeed('Hack squat', ['Quads', 'Glutes'], id: '65ad1798-452a-46c2-ae02-66c57be1cfc8'),
  ExerciseSeed('Leg extension machine', ['Quads'], id: 'e9b5f569-5bd8-4b35-9ca5-44778bd345bb'),
  ExerciseSeed('Lying leg curl machine', ['Hamstrings'], id: '8cbadf0b-f514-4802-90dc-e392588ec976'),
  ExerciseSeed('Deadlift', ['Hamstrings', 'Glutes', 'Back'], id: 'a049709b-5b29-4b56-a568-294d3d99f1d6'),
  ExerciseSeed('Romanian deadlift', ['Hamstrings', 'Glutes'], id: '840c9051-fb9f-4b22-8ea0-455799838cb4'),
  ExerciseSeed('Dumbbell Romanian deadlift', ['Hamstrings', 'Glutes'], id: '82a17c9b-ba19-4688-ad35-04087fa68bcd'),
  ExerciseSeed('Hip thrust', ['Glutes'], id: '323cc733-a736-4461-b4e3-1da670681b6c'),
  ExerciseSeed('Walking lunge', ['Quads', 'Glutes'], id: '7f73526e-dff8-47c7-aa0e-d872c9e253e3'),
  ExerciseSeed('Bulgarian split squat', ['Quads', 'Hamstrings'], id: '2d8901cf-3d29-4f84-a34e-6af818155612'),
  ExerciseSeed('Bulgarian split squat left', ['Quads', 'Hamstrings'], id: '272be082-6636-4482-aabd-71a09dcbadee'),
  ExerciseSeed('Bulgarian split squat right', ['Quads', 'Hamstrings'], id: 'c5339658-fc16-4912-8754-434c2661ca21'),
  ExerciseSeed('Calves extension machine on Hack', ['Calves'], id: '579773aa-0b63-42f1-9abb-d35fc2fd151e'),
  ExerciseSeed('Calves extension on Smith Machine', ['Calves'], id: '9458211e-9c30-4ed2-bbe8-a36df320fbba'),
  ExerciseSeed('Single leg calf raise', ['Calves'], id: '843ccf27-2ab9-4c34-aea9-5f202da7368b'),
  ExerciseSeed('Single leg calf raise left', ['Calves'], id: 'a0354315-d4c8-4f03-9844-4019a1b32c8c'),
  ExerciseSeed('Single leg calf raise right', ['Calves'], id: 'b8e2c538-de8b-4f52-ac6d-8e5d9167ad5e'),

  // -- Core ----------------------------------------------------------------
  ExerciseSeed('Plank', ['Abs'], id: '32399f22-834d-446b-9eb4-2e88cd78667d', kind: exerciseKindTime),
  ExerciseSeed('Side plank', ['Abs'], id: '91daa723-8970-4fed-b4f8-8d06046be9dc', kind: exerciseKindTime),
  ExerciseSeed('Side plank left', ['Abs'], id: 'fda828ad-1e71-4217-af8e-3fc46d636614', kind: exerciseKindTime),
  ExerciseSeed('Side plank right', ['Abs'], id: '8338c91d-8ae9-4b51-bac7-10bf7c489052', kind: exerciseKindTime),
  ExerciseSeed('Hanging leg raise', ['Abs'], id: '698c4ab0-8a4c-41bc-b66e-fa796fff166c'),
  ExerciseSeed("Captain's chair straight leg raise", ['Abs'], id: '65ea24ae-3b5d-4262-97ec-48d36052b94d'),
  ExerciseSeed('Reverse crunch', ['Abs'], id: '287817a2-c38a-4b89-91a0-e0dfe46b4df5'),
  ExerciseSeed('Weighted decline sit-up', ['Abs'], id: '772e735b-3f30-4669-853d-dcf6ead81b22'),
  ExerciseSeed('Dead bug', ['Abs'], id: '831e5949-dbe6-4181-99d2-289ccc43fd9c'),

  // -- TRX / suspension ----------------------------------------------------
  ExerciseSeed('TRX Biceps curl', ['Biceps'], id: '8e5380ec-43a9-4f47-8fd5-e7cf6e6e085f'),
  ExerciseSeed('TRX Triceps extension', ['Triceps'], id: 'aa8ee3f8-c7e4-4d33-b140-a0137acd103f'),
  ExerciseSeed('TRX Face pull', ['Back', 'Shoulders'], id: '7c1c7009-a725-4f5d-a80c-3359958f7d3f'),
  ExerciseSeed('TRX Fallout', ['Abs', 'Chest', 'Shoulders'], id: '8d67c0a9-6bcd-4377-99c7-8b20ada143cb'),
  ExerciseSeed('TRX High row', ['Back', 'Biceps'], id: 'ef857baf-464f-4934-9ebe-c56b92310267'),
  ExerciseSeed('TRX Low row', ['Back', 'Biceps'], id: '8b5aa84c-1d92-406c-9408-3652376d239e'),
  ExerciseSeed('TRX Pike', ['Abs'], id: 'dc72c53a-7bf9-4d2a-af15-5848c4ad4c27'),
  ExerciseSeed('TRX Suspended push-up', ['Chest', 'Shoulders'], id: 'ac1e0107-69d6-4df3-9708-300f48f7ac01'),
  ExerciseSeed('TRX Bulgarian split squat', ['Quads'], id: 'f460e2b4-a8e4-49f6-a907-f6a4b9f774a5'),
  ExerciseSeed('TRX Bulgarian split squat left', ['Quads'], id: '740c47ff-3c89-4bf6-af87-15d5356c943f'),
  ExerciseSeed('TRX Bulgarian split squat right', ['Quads'], id: '2de0032e-359a-403a-bb71-dd7a055767fc'),
  ExerciseSeed('TRX Pistol squat', ['Quads'], id: '03e47606-0b15-4bfd-837a-130af6f174c8'),
  ExerciseSeed('TRX Pistol squat left', ['Quads'], id: '78e73ca3-883f-480e-96ad-8a1c2422a470'),
  ExerciseSeed('TRX Pistol squat right', ['Quads'], id: 'd0be3db9-cd9a-4f16-8b7b-b2b924452762'),
  ExerciseSeed('TRX Single leg Romanian deadlift', ['Hamstrings'], id: '4bfb5724-45d7-47d6-a9d3-c68049d7ae69'),
  ExerciseSeed('TRX Single leg Romanian deadlift left', ['Hamstrings'], id: '756d1ce7-a160-47eb-b13c-a19007332f17'),
  ExerciseSeed('TRX Single leg Romanian deadlift right', ['Hamstrings'], id: '916bafa9-47dc-43bd-9216-5dd3ce477f44'),

  // -- Conditioning (time-kind) --------------------------------------------
  ExerciseSeed(
    'Burpees',
    ['Chest', 'Quads', 'Shoulders', 'Hamstrings', 'Glutes'], id: 'ba0e059b-ed5e-4e6d-b8d2-599c5c2f74b4',
    kind: exerciseKindTime,
  ),
  ExerciseSeed('Jumping jacks', ['Calves', 'Quads', 'Shoulders'], id: 'b985b9f8-f4c6-463c-8997-c56fe61ea1a8',
      kind: exerciseKindTime),
  ExerciseSeed('March in place', ['Quads', 'Calves'], id: 'ff2c5a32-8386-45ac-b57c-8d4e48a708d9',
      kind: exerciseKindTime),
  ExerciseSeed('Mountain climbers', ['Abs', 'Quads'], id: '60803563-d74d-422a-9185-e84b870259d5',
      kind: exerciseKindTime),
  ExerciseSeed('Rowing machine', ['Back', 'Quads', 'Glutes', 'Biceps'],
      id: '8101da57-2748-4f85-92aa-7552df161c84', kind: exerciseKindTime),
  ExerciseSeed('Stationary bike', ['Quads', 'Glutes', 'Hamstrings'],
      id: '01da3032-d625-4506-bcdc-0a2b40f9db09', kind: exerciseKindTime),
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
  // One call, all or nothing. The emptiness check above happens once and the
  // write that follows is interleaved with whatever sync delivers, so entries
  // whose id or name has been taken meanwhile are skipped inside rather than
  // reconciled: a row under an id the catalogue does not own is worse than a
  // missing one.
  final written = await exercises.writeCatalogExercises([
    for (final seed in exerciseSeeds)
      CatalogExercise(
        syncId: seed.id,
        name: seed.name,
        kind: seed.kind,
        muscleSyncIds: [for (final m in seed.muscles) muscleSyncId(m)],
        createdAt: catalogueEpoch,
      ),
  ]);
  // Whether it wrote, not whether it ran. Every entry can be skipped when the
  // library stopped being pristine between the check above and the write, and
  // reporting that as a write would be a lie the callers act on.
  return written > 0;
}
