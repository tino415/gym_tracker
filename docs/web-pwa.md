# Web / PWA

`flutter build web` produces an installable PWA (Flutter generates the service
worker).

The web build is **Firestore-direct**: `firestoreDirectProvider`
(`lib/data/providers.dart`) is `kIsWeb && syncBackendEnabled`, so every
repository reads and writes Firestore and the Drift DB is never opened on web.
Every web build therefore passes `--dart-define=SYNC_BACKEND=firestore` (`just
web`, `just deploy`, `just e2e-web`); a build without it falls through to the
unsupported Drift web path in `database.dart` (`DriftWebOptions` → the
committed `web/sqlite3.wasm` + `web/drift_worker.js`, both now vestigial).

**Which bundle am I actually running?** The account screen ends with
`Build <sha>[-dirty]-<yyyymmdd-hhmm>`, stamped by every Justfile build recipe
(`BUILD_ID`). Compare it against the commit you deployed before believing a fix
didn't work — that is usually the whole story, per the next paragraph. `dev`
means the build didn't come from the Justfile at all. It identifies the *Dart*
bundle only: a stale `index.html` or `flutter_bootstrap.js` loads before any
Dart runs and won't be caught by it.

**Service-worker stale cache while iterating.** The generated service worker
serves the *previous* `main.dart.js` across reloads (it also serves its own
old `flutter_service_worker.js`, so the new version is never detected, and
`flutter_bootstrap.js` re-registers it every load) — a rebuilt bundle looks
like it never took effect. To test a fresh build: unregister the SW + clear
caches + reload in a *fresh tab* (the old active worker keeps controlling
existing clients until they close), or just build with `--pwa-strategy=none`
during dev iteration. Firestore's offline cache (IndexedDB) survives cache
clears; it's separate from the SW app-shell cache.

**This bit production, and the fix is in `firebase.json`.** Hosting's default is
`Cache-Control: max-age=3600` for every file, which included
`flutter_service_worker.js` and `flutter_bootstrap.js` — so the worker's own
update check was answered from the HTTP cache, and each time it was, the
cache-first worker re-served the shell it already had. The loop has no upper
bound: a three-day-old bundle survived repeated hard reloads. The `headers`
block now sends `no-cache` for **every** file, so a deploy propagates on the
next load.

It says `**` rather than a list because **Flutter content-hashes nothing in
`build/web`** — `canvaskit/canvaskit.wasm`, `flutter.js` and everything under
`assets/` have fixed names too. The first version of that block listed only the
six shell files and left the rest on `max-age=3600`, on the mistaken belief that
`assets/` and `canvaskit/` were hashed. That let a client pair a fresh
`main.dart.js` with an hour-old CanvasKit runtime — an engine talking to a
renderer it wasn't built against, which is a candidate cause of the WebGL
cross-context errors seen on desktop. `no-cache` is revalidation, not
no-storage, so an unchanged `canvaskit.wasm` still costs a 304 and no bytes.

Also: `web.app` and `firebaseapp.com` are separate *origins* of the same site, so
each keeps its own worker and cache — clearing one leaves the other stale, and
`just live-build` only ever checks `web.app`.
