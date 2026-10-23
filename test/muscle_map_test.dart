import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/data/database.dart';
import 'package:gym_tracker/data/muscle_seeds.dart';
import 'package:gym_tracker/data/providers.dart';
import 'package:gym_tracker/phone/exercises/body_regions.dart';
import 'package:gym_tracker/phone/exercises/exercise_edit_page.dart';
import 'package:gym_tracker/phone/exercises/exercises_list_page.dart';
import 'package:gym_tracker/phone/exercises/muscle_map.dart';

void main() {
  group('regionsOf', () {
    test('every seeded muscle lights at least one region', () {
      for (final name in muscleSeeds) {
        expect(regionsOf({muscleSyncId(name)}), isNotEmpty, reason: name);
      }
    });

    test('every region names a seeded muscle', () {
      for (final region in BodyRegion.values) {
        expect(muscleSeeds, contains(region.muscleName), reason: region.name);
      }
    });

    test('Back is lats, traps and lower back', () {
      expect(
        regionsOf({muscleSyncId('Back')}),
        {BodyRegion.lats, BodyRegion.traps, BodyRegion.lowerBack},
      );
    });

    test('Shoulders light both the front and the back view', () {
      expect(
        regionsOf({muscleSyncId('Shoulders')}).map((r) => r.view).toSet(),
        BodyView.values.toSet(),
      );
    });

    test('an unknown muscle id lights nothing', () {
      expect(regionsOf({'muscle:neck'}), isEmpty);
    });
  });

  MuscleMapPainter painterOf(WidgetTester tester, Finder within) {
    final paint = tester.widget<CustomPaint>(
      find.descendant(of: within, matching: find.byType(CustomPaint)),
    );
    return paint.painter! as MuscleMapPainter;
  }

  testWidgets('lights the highlighted muscles in the primary colour', (tester) async {
    final theme = ThemeData(colorSchemeSeed: Colors.teal);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: MuscleMap(highlighted: {muscleSyncId('Chest'), muscleSyncId('Abs')}),
      ),
    );

    final painter = painterOf(tester, find.byType(MuscleMap));
    expect(painter.lit, {BodyRegion.chest, BodyRegion.abs});
    expect(painter.litColor, theme.colorScheme.primary);
  });

  group('with a database', () {
    late AppDatabase db;

    setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    Future<void> disposeTree(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 1));
      }
    }

    Widget app(Widget home) => ProviderScope(
          overrides: [databaseProvider.overrideWithValue(db)],
          child: MaterialApp(home: home),
        );

    testWidgets('the edit page map follows the muscle selection live', (tester) async {
      await tester.pumpWidget(app(const ExerciseEditPage()));
      await tester.pumpAndSettle();
      final map = find.byType(MuscleMap);
      expect(painterOf(tester, map).lit, isEmpty);

      await tester.ensureVisible(find.widgetWithText(FilterChip, 'Calves'));
      await tester.tap(find.widgetWithText(FilterChip, 'Calves'));
      await tester.pump();
      expect(painterOf(tester, map).lit, {BodyRegion.calves});

      await tester.tap(find.widgetWithText(FilterChip, 'Calves'));
      await tester.pump();
      expect(painterOf(tester, map).lit, isEmpty);

      await disposeTree(tester);
    });

    testWidgets('a list row shows its exercise muscles as a thumbnail', (tester) async {
      final row = await db.createExercise('Barbell Row');
      await db.setExerciseMuscles(row.syncId, [muscleSyncId('Back'), muscleSyncId('Biceps')]);
      await db.createExercise('Plank');

      await tester.pumpWidget(app(Scaffold(body: ExercisesListView(onSelect: (_) {}))));
      await tester.pumpAndSettle();

      Finder thumbnailOf(String name) => find.descendant(
            of: find.widgetWithText(ListTile, name),
            matching: find.byType(ExerciseThumbnail),
          );
      expect(
        painterOf(tester, thumbnailOf('Barbell Row')).lit,
        {BodyRegion.lats, BodyRegion.traps, BodyRegion.lowerBack, BodyRegion.biceps},
      );
      expect(painterOf(tester, thumbnailOf('Plank')).lit, isEmpty);
      expect(tester.getSize(thumbnailOf('Plank')), const Size.square(ExerciseThumbnail.size));

      await disposeTree(tester);
    });
  });
}
