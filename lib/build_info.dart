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

const List<String> _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// Splits [id] into the commit part and a readable build time.
///
/// The timestamp is already in [buildId] — the Justfile appends
/// `yyyymmdd-hhmm` — but `6d2e263-dirty-20260810-1942` reads as one opaque
/// token, and the whole point of the stamp is being able to tell at a glance
/// whether a browser is running the bundle you just deployed. So it comes back
/// as `('6d2e263-dirty', '10 Aug 2026 19:42')`.
///
/// Returns a null [when] rather than guessing when there is no parseable
/// timestamp: `dev` builds have none, and a future change to the Justfile's
/// format should degrade to showing the raw id, never to a wrong date. The
/// commit part is always passed through verbatim so nothing is lost from a bug
/// report.
({String commit, String? when}) parseBuildId(String id) {
  // Trailing `-yyyymmdd-hhmm`; anything before it is the commit, dirty flag
  // included.
  final m = RegExp(r'^(.*)-(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})$').firstMatch(id);
  if (m == null) return (commit: id, when: null);
  final month = int.parse(m.group(3)!);
  if (month < 1 || month > 12) return (commit: id, when: null);
  final day = int.parse(m.group(4)!);
  return (
    commit: m.group(1)!,
    when: '$day ${_months[month - 1]} ${m.group(2)} '
        '${m.group(5)}:${m.group(6)}',
  );
}
