import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('sync_dtos.dart imports nothing that needs Flutter or the database', () {
    final imports = File('lib/sync/sync_dtos.dart')
        .readAsLinesSync()
        .where((l) => RegExp(r'^\s*(import|export|part)\b').hasMatch(l))
        .toList();

    expect(imports, [
      "import '../data/exercise_kind.dart';",
      "import '../data/exercise_params.dart';",
    ]);
  });

  test('exercise_params.dart imports only the Dart core', () {
    final imports = File('lib/data/exercise_params.dart')
        .readAsLinesSync()
        .where((l) => l.startsWith('import '))
        .toList();

    expect(imports, ["import 'dart:convert';"]);
  });

  test('exercise_kind.dart has no imports', () {
    final source = File('lib/data/exercise_kind.dart').readAsStringSync();

    expect(source, isNot(contains('import ')));
  });
}
