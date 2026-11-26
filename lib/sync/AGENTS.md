# lib/sync

Read `docs/sync.md` before changing a file here; each line below is argued there.

- Never bring back the `voo_watch` plugin; the Wear bridge stays hand-rolled.
- `SyncRepository` never calls an `AppDatabase` workout mutator.
- `applyWorkoutCompleted` assigns the DTO's version verbatim, never incrementing.
- An apply never clobbers a live local session, one with `endedAt` null.
- The watch never pushes routines.
- A Firestore push is upsert-only: no doc is deleted for being absent locally.
- A deletion is a versioned tombstone; its Firestore doc is rewritten, not removed.
- `start()` drains the pending queue before it sends the `syncRequest`.
- `stripHealthData` gates at the transport and in the web repository, never at
  `exportWorkout`.
- `allowHealthUpload` defaults to false, and a withdrawn consent deletes what was
  uploaded.
- The web repository writes read-modify-write, not `runTransaction`.
- `_serverWorkouts` is written before the `set` completes.
- The local schema is never partitioned by uid; the owner marker is the answer.
- `FIREBASE_USE_EMULATOR` defaults off.
- `sync_codec.dart` keeps reading the pre-v15 `supersetGroup` key.
