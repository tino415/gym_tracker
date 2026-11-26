# Contributing

## Pull requests

**Merge only a green PR.** `.github/workflows/ci.yml` runs on every non-draft PR
and on every push to `main` (analyze, both test suites, then codegen + schema +
l10n with `git diff --exit-code`, so a schema change pushed without `just
schema` fails). GitHub Free has no branch protection, so nothing enforces it:
check the run yourself. The Termux deploy button deploys only a `main` commit
whose `ci.yml` run completed green.

**A PR that changes anything visible carries screenshots**, one set per form
factor it touches: phone and watch from the emulators (`just phone-apk-demo`,
then `adb screencap`), web from headless Chromium, a flow as a `screenrecord`
clip or numbered stills, before and after for a visual change. Upload them with
the `pr-images` skill, never commit them. A PR with no visible change says so in
one line.

`just deploy` ships Hosting and `firestore:rules` together, so a rules change is
reviewed once, in its PR.

## Testing

Five traps that cost real time, none guessable from the failure:

1. **Awaiting `.first` on a drift *stream* in a widget test hangs forever.**
   The widget tester's fake clock never advances real-time IO, so the
   subscription never emits and the test sits until the 10-minute timeout with
   no error. Wrap stream reads in `tester.runAsync(...)`. Plain futures
   (`loadFullWorkout`, `createWorkout`, …) are fine awaited directly — it is
   specifically streams. Only applies under `flutter test`: `integration_test/`
   runs on a real binding and real clock, where `.first` is fine.
2. **`integration_test/` files share one browser and one Firebase session.** A
   second `testWidgets` in the same file starts already signed in from the
   first, so it never sees the sign-up form it tries to fill and dies on a
   finder index. Put the extra assertions in one test, or handle both states.
3. **Measuring a dialog's width: scope the finder to *that* dialog.**
   `find.byType(Dialog).first` returns whichever opened first, so a dialog
   opened from another (the exercise picker → "New exercise") silently measures
   the one underneath — a test that passed identically with and without the bug.
   Use `find.ancestor(of: find.text('<title>'), matching: find.byType(Dialog))`,
   and measure the `Material` inside it: the `AlertDialog` render box spans the
   whole route and always reports the viewport width.
4. **Wide layouts only exist in the browser.** Anything gated on
   `masterDetailBreakpoint` — the picker's dialog form, the 3-pane routines view
   — never renders on a phone, and an Android emulator in landscape still takes
   the narrow branch. `just e2e-web-dialogs` is the only place that is checked.
   Plain layout constraints don't need a browser though: a widget test with
   `tester.view.physicalSize` set wide is faster and just as conclusive.
5. **`pumpAndSettle` never settles while a periodic ticker runs.** Any page with
   a rest/hold countdown (`watch_run_page`, `workout_run_page`) keeps a
   `Timer.periodic` alive, so settling times out. Drive those with explicit
   `pump(Duration(...))` calls, and unmount the tree at the end of the test
   (`pumpWidget(const SizedBox())`) or the run ends with a pending-timer
   failure.

### Web-only code paths need `just test-web`

`just test` runs on the VM, where `kIsWeb` is **always false**. Anything gated on
it is compiled but never executed, and a test asserting its absence passes for
the wrong reason. `just test-web` runs a curated subset under
`--platform chrome` so the other branch actually runs; write both directions and
`skip:` the one that doesn't apply (`test/selectable_on_web_test.dart` is the
pattern). Such a test only really passes once **both** recipes have run.

The subset is an explicit list in the `Justfile` because it can't be derived:
anything importing `lib/data/database.dart` pulls drift → sqlite3 → `dart:ffi`,
which a browser lacks, and the run fails to compile rather than skipping.

`just live-build` reads `BUILD_ID` out of the *served* `main.dart.js` and
compares it to HEAD. Unlike the account screen it bypasses the service worker,
so it separates the two failures that look identical: a deploy that didn't take
(mismatch) versus a browser holding a stale bundle (match, app still wrong).

### Schema migrations

`test/migration_test.dart` runs the real migration against a database actually
created at the old version, using drift's schema tooling. The demo seed can't
substitute: it writes through the *current* Drift classes, so it only ever
produces rows already in the new shape.

**After every schema change run `just schema`** (dump + regenerate), or the
tests still validate against the previous version. Then point the existing
`migrateAndValidate` calls at the new version and add the read-back through the
new `DatabaseAtV<n>` — a check-back class one version behind the migrated file
fails with "you've bumped the schema version … didn't provide a strategy",
which reads like a missing migration and is not one.

Three things that bite:

- **Column defaults must be literals.** `schema dump` copies the Dart
  expression verbatim, and the code generated from it imports only drift — so
  `withDefault(const Constant(exerciseKindReps))` compiles in the app and fails
  in the generated schema. Hence `const Constant('reps')` in `Exercises.kind`.
- **Dumping an *older* version needs that version's source.** Check the
  pre-change `database.dart` + `database.g.dart` out of git into place, dump,
  then restore — there's no way to re-derive a schema you never dumped.
- **`isNull` is ambiguous in `migration_test.dart`.** It imports
  `package:drift/drift.dart`, which exports a matcher of that name alongside
  `package:matcher`'s. Assert against plain `null`.
