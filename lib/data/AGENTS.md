# lib/data

Read `docs/data-model.md` before changing a file here, and `CONTRIBUTING.md`
"Schema migrations" before a schema change.

- `PRAGMA foreign_keys = ON` lives in `beforeOpen`; a migration that needs it off
  sets `OFF` itself.
- History, sync export and the run pages read the workout's snapshot, never the
  routine.
- A migration that recreates a table also recreates or checks every table whose
  FK targets it.
- `customStatement` does not notify streams: use `customUpdate` with `updates`.
- A column default is a literal, such as `const Constant('reps')`.
- Every workout mutator calls `_bumpWorkoutVersion`; `startWorkout` and
  `createWorkout` do not.
- Every read for the UI hides tombstones (`deletedAt` set) of workouts, routines
  and exercises; the sync export carries them.
- `firestore_repositories.dart` is the web repository and follows
  `lib/sync/AGENTS.md`: `stripHealthData` in its writes, `allowHealthUpload`
  false when unwired, read-modify-write and never `runTransaction`.
- After a schema change run `just schema`.
