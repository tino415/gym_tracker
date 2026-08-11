import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/build_info.dart';

/// The build stamp is what settles "is the browser running the bundle I just
/// deployed?", so a wrong or missing date is worse than a raw id.
void main() {
  test('splits a clean build into commit and readable time', () {
    final r = parseBuildId('6d2e263-20260810-1942');

    expect(r.commit, '6d2e263');
    expect(r.when, '10 Aug 2026 19:42');
  });

  test('the dirty flag stays with the commit', () {
    // It qualifies the commit, not the time — a bug report needs to show the
    // build did not come from a clean tree.
    final r = parseBuildId('6d2e263-dirty-20260810-1942');

    expect(r.commit, '6d2e263-dirty');
    expect(r.when, '10 Aug 2026 19:42');
  });

  test('a dev build has no time and keeps its id', () {
    final r = parseBuildId('dev');

    expect(r.commit, 'dev');
    expect(r.when, isNull);
  });

  test('an unrecognised format degrades to the raw id', () {
    // If the Justfile's format ever changes, showing the whole id is right;
    // inventing a date from a partial match is not.
    for (final id in ['nogit', '6d2e263-2026081-1942', '6d2e263-20260810']) {
      final r = parseBuildId(id);
      expect(r.commit, id, reason: id);
      expect(r.when, isNull, reason: id);
    }
  });

  test('a nonsense month is refused rather than guessed', () {
    final r = parseBuildId('6d2e263-20261310-1942');

    expect(r.commit, '6d2e263-20261310-1942');
    expect(r.when, isNull);
  });

  test('single-digit days lose the leading zero, months keep their name', () {
    expect(parseBuildId('abc-20260101-0005').when, '1 Jan 2026 00:05');
    expect(parseBuildId('abc-20261231-2359').when, '31 Dec 2026 23:59');
  });
}
