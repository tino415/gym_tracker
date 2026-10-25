import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('sync_dtos.dart imports nothing that needs Flutter or the database', () {
    final imports = File('lib/sync/sync_dtos.dart')
        .readAsLinesSync()
        .where((l) => l.startsWith('import '))
        .toList();

    expect(imports, ["import '../data/exercise_kind.dart';"]);
  });

  test('exercise_kind.dart has no imports', () {
    final source = File('lib/data/exercise_kind.dart').readAsStringSync();

    expect(source, isNot(contains('import ')));
  });
}
