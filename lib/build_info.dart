/// Identifies the build this binary came from, shown at the bottom of the
/// account screen.
///
/// Exists because a deployed web bundle and the one a browser is actually
/// running are not the same thing: the generated service worker keeps serving
/// the previous `main.dart.js`, so a fix can be live on the server while the
/// page still shows the old behaviour. Comparing this string against the commit
/// you deployed settles that in a glance, instead of by hashing bundles.
///
/// Set by the Justfile build recipes to `<short-sha>[-dirty]-<yyyymmdd-hhmm>`.
/// A build made without the define — `flutter run`, an IDE launch — reads
/// `dev`, which is itself the useful answer: this is not a release bundle.
const String buildId = String.fromEnvironment('BUILD_ID', defaultValue: 'dev');
