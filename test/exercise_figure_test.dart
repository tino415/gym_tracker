import 'dart:math';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:gym_tracker/data/database.dart';
import 'package:gym_tracker/data/drift_repositories.dart';
import 'package:gym_tracker/data/exercise_seeds.dart';
import 'package:gym_tracker/data/providers.dart';
import 'package:gym_tracker/phone/exercises/exercise_edit_page.dart';
import 'package:gym_tracker/phone/exercises/exercises_list_page.dart';
import 'package:gym_tracker/phone/exercises/figure/exercise_visual.dart';
import 'package:gym_tracker/phone/exercises/figure/figure_painter.dart';
import 'package:gym_tracker/phone/exercises/figure/figure_poses.dart';
import 'package:gym_tracker/phone/exercises/figure/figure_spec.dart';
import 'package:gym_tracker/phone/exercises/figure/equipment.dart';
import 'package:gym_tracker/phone/exercises/figure/skeleton.dart';
import 'package:gym_tracker/phone/exercises/muscle_map.dart';
import 'package:gym_tracker/phone/run/workout_run_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

String idOf(String name) => exerciseSeeds.firstWhere((s) => s.name == name).id;

void main() {
  group('poses', () {
    test('every seed resolves to a figure', () {
      for (final seed in exerciseSeeds) {
        expect(figureFor(seed.id), isNotNull, reason: seed.name);
      }
    });

    test('the left and right seeds of a movement mirror one base pose', () {
      for (final base in [
        'Bulgarian split squat',
        'Single leg calf raise',
        'Side plank',
        'TRX Bulgarian split squat',
        'TRX Pistol squat',
        'TRX Single leg Romanian deadlift',
      ]) {
        final left = figureFor(idOf('$base left'))!;
        final right = figureFor(idOf('$base right'))!;
        expect(left.spec, same(right.spec), reason: base);
        expect(left.mirrored, isNot(right.mirrored), reason: base);
      }
    });

    test('an unknown or missing id has no figure', () {
      expect(figureFor('made-by-the-user'), isNull);
      expect(figureFor(null), isNull);
    });
  });

  group('skeleton', () {
    final placement = figureFor(idOf('Back squat'))!;

    double gap(Offset a, Offset b) => (a - b).distance;

    test('limb lengths are the skeleton lengths whatever the angles', () {
      for (final placement in figurePlacements.values) {
        final joints = placement.joints;
        for (var i = 0; i < joints.arms.length; i++) {
          expect(gap(joints.armRoots[i], joints.arms[i].elbow), closeTo(upperArmLength, 1e-9));
          expect(gap(joints.arms[i].elbow, joints.arms[i].wrist), closeTo(forearmLength, 1e-9));
        }
        for (var i = 0; i < joints.legs.length; i++) {
          expect(gap(joints.legRoots[i], joints.legs[i].knee), closeTo(thighLength, 1e-9));
          expect(gap(joints.legs[i].knee, joints.legs[i].ankle), closeTo(shinLength, 1e-9));
        }
        expect(gap(joints.hip, joints.shoulder), closeTo(torsoLength, 1e-9));
      }
    });

    test('mirroring flips x about the canvas centre and keeps y', () {
      final base = FigurePlacement(placement.spec).joints;
      final mirrored = FigurePlacement(placement.spec, mirrored: true).joints;
      expect(mirrored.hip.dx, figureCanvasSize.width - base.hip.dx);
      expect(mirrored.hip.dy, base.hip.dy);
      expect(mirrored.legs.single.toe.dx, figureCanvasSize.width - base.legs.single.toe.dx);
      expect(mirrored.arms.single.wrist.dy, base.arms.single.wrist.dy);
    });

    test('equipment anchors mirror along with the figure', () {
      const anchor = Anchor.at(Joint.wrist, dx: 7, dy: 5);
      final base = FigurePlacement(placement.spec).resolve(anchor);
      final mirrored = FigurePlacement(placement.spec, mirrored: true).resolve(anchor);
      expect(mirrored, Offset(figureCanvasSize.width - base.dx, base.dy));
      const fixed = Anchor.canvas(160, 14);
      expect(
        FigurePlacement(placement.spec, mirrored: true).resolve(fixed),
        const Offset(40, 14),
      );
    });

    test('a front view carries both limb pairs, apart', () {
      final joints = figureFor(idOf('Seated dumbbell lateral raise'))!.joints;
      expect(joints.arms, hasLength(2));
      expect(joints.legs, hasLength(2));
      expect(joints.armRoots[0].dx, lessThan(joints.armRoots[1].dx));
      expect(joints.arms[0].wrist.dx, lessThan(joints.shoulder.dx));
      expect(joints.arms[1].wrist.dx, greaterThan(joints.shoulder.dx));
    });

    test('a pair of limbs in profile shares one root', () {
      final joints = figureFor(idOf('Walking lunge'))!.joints;
      expect(joints.legs, hasLength(2));
      expect(joints.legRoots[0], joints.legRoots[1]);
    });

    test('a pose can be rooted at the ankle or the wrist it rests on', () {
      const angles = (
        arms: [ArmAngles(upper: 30, fore: 70)],
        legs: [LegAngles(thigh: 80, shin: 100, foot: 0)],
      );
      const point = Offset(100, 150);

      final fromAnkle = poseJoints(
        Pose.fromAnkle(point, torso: -90, head: -90, arms: angles.arms, legs: angles.legs),
      );
      final fromWrist = poseJoints(
        Pose.fromWrist(point, torso: -90, head: -90, arms: angles.arms, legs: angles.legs),
      );

      expect(gap(fromAnkle.legs.first.ankle, point), closeTo(0, 1e-9));
      expect(gap(fromWrist.arms.first.wrist, point), closeTo(0, 1e-9));
    });

    test('a pose rooted at the wrist of a spread pair still lands that wrist on the point', () {
      const point = Offset(60, 30);
      final joints = poseJoints(
        Pose.fromWrist(
          point,
          torso: -90,
          head: -90,
          arms: const [ArmAngles(upper: 200, fore: -100), ArmAngles(upper: -20, fore: -80)],
          legs: const [LegAngles(thigh: 90, shin: 90, foot: 0)],
        ),
      );
      expect(gap(joints.arms.first.wrist, point), closeTo(0, 1e-9));
    });

    test('a ghost pose mirrors along with its figure', () {
      final placement = figureFor(idOf('Burpees'))!;
      final mirrored = FigurePlacement(placement.spec, mirrored: true);
      expect(mirrored.ghost!.joints.hip.dx, figureCanvasSize.width - placement.ghost!.joints.hip.dx);
    });

    test('a side view draws the near limb only', () {
      final joints = figureFor(idOf('TRX Low row'))!.joints;
      expect(joints.arms, hasLength(1));
      expect(joints.legs, hasLength(1));
    });
  });

  group('placements', () {
    late AppDatabase db;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      db = AppDatabase.forTesting(NativeDatabase.memory());
    });
    tearDown(() => db.close());

    Widget app(Widget home) => ProviderScope(
          overrides: [databaseProvider.overrideWithValue(db)],
          child: MaterialApp(theme: ThemeData(colorSchemeSeed: Colors.teal), home: home),
        );

    Future<void> disposeTree(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 1));
      }
    }

    Future<void> loadFromDatabase(WidgetTester tester) async {
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
        await tester.pump(const Duration(milliseconds: 20));
      }
    }

    Future<void> seed(WidgetTester tester) => tester.runAsync(
          () => seedStarterExercises(exercises: DriftExerciseRepository(db)),
        );

    testWidgets('the edit page shows the figure of a posed exercise', (tester) async {
      await seed(tester);
      await tester.pumpWidget(app(ExerciseEditPage(exerciseId: idOf('Back squat'))));
      await loadFromDatabase(tester);

      expect(find.byType(ExerciseFigure), findsOneWidget);
      expect(find.byType(MuscleMap), findsNothing);
      final painter = tester.widget<CustomPaint>(
        find.descendant(of: find.byType(ExerciseFigure), matching: find.byType(CustomPaint)),
      ).painter! as FigurePainter;
      expect(painter.figureColor, Theme.of(tester.element(find.byType(ExerciseFigure))).colorScheme.primary);

      await disposeTree(tester);
    });

    testWidgets('the edit page falls back to the body map for a user-made exercise',
        (tester) async {
      final mine = await tester.runAsync(() => db.createExercise('My own lift'));
      await tester.pumpWidget(app(ExerciseEditPage(exerciseId: mine!.syncId)));
      await loadFromDatabase(tester);

      expect(find.byType(MuscleMap), findsOneWidget);
      expect(find.byType(ExerciseFigure), findsNothing);

      await disposeTree(tester);
    });

    testWidgets('a new exercise shows the body map', (tester) async {
      await tester.pumpWidget(app(const ExerciseEditPage()));
      await tester.pumpAndSettle();

      expect(find.byType(MuscleMap), findsOneWidget);
      expect(find.byType(ExerciseFigure), findsNothing);

      await disposeTree(tester);
    });

    testWidgets('the list thumbnail is the figure for a posed row, the map otherwise',
        (tester) async {
      await seed(tester);
      await tester.runAsync(() => db.createExercise('My own lift'));
      tester.view.physicalSize = const Size(800, 20000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(app(Scaffold(body: ExercisesListView(onSelect: (_) {}))));
      await loadFromDatabase(tester);

      Finder thumbnailOf(String name, Type content) => find.descendant(
            of: find.descendant(
              of: find.widgetWithText(ListTile, name),
              matching: find.byType(ExerciseThumbnail),
            ),
            matching: find.byType(content),
          );
      expect(thumbnailOf('Back squat', ExerciseFigure), findsOneWidget);
      expect(thumbnailOf('Back squat', MuscleMap), findsNothing);
      expect(thumbnailOf('My own lift', MuscleMap), findsOneWidget);
      expect(thumbnailOf('My own lift', ExerciseFigure), findsNothing);

      await disposeTree(tester);
    });

    Future<void> runExercise(WidgetTester tester, String name) async {
      final routine = await tester.runAsync(() async {
        final exercise = (await db.watchExercises().first).firstWhere((e) => e.name == name);
        final r = await db.createRoutine('Day');
        final re = await db.addExerciseToRoutine(routineId: r.syncId, exerciseId: exercise.syncId);
        await db.addPlannedSet(routineExerciseId: re.syncId, targetReps: 5, targetWeightKg: 20);
        return r;
      });
      final router = GoRouter(
        initialLocation: '/run/${routine!.syncId}',
        routes: [
          GoRoute(
            path: '/run/:routineId',
            builder: (_, state) => WorkoutRunPage(routineId: state.pathParameters['routineId']!),
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [databaseProvider.overrideWithValue(db)],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await loadFromDatabase(tester);
    }

    testWidgets('the run page shows the figure of a posed exercise', (tester) async {
      await seed(tester);
      await runExercise(tester, 'Back squat');

      expect(find.byType(ExerciseFigure), findsOneWidget);
      expect(find.byType(MuscleMap), findsNothing);

      await disposeTree(tester);
    });

    testWidgets('the run page falls back to the body map for a user-made exercise',
        (tester) async {
      await tester.runAsync(() => db.createExercise('My own lift'));
      await runExercise(tester, 'My own lift');

      expect(find.byType(MuscleMap), findsOneWidget);
      expect(find.byType(ExerciseFigure), findsNothing);

      await disposeTree(tester);
    });
  });

  test('every posed exercise paints without leaving the canvas', () {
    for (final placement in figurePlacements.values) {
      final joints = placement.joints;
      final points = [
        joints.headCentre,
        for (final leg in joints.legs) ...[leg.knee, leg.ankle, leg.toe],
        for (final arm in joints.arms) ...[arm.elbow, arm.wrist],
      ];
      for (final p in points) {
        expect(p.dx, inInclusiveRange(0, figureCanvasSize.width));
        expect(p.dy, inInclusiveRange(0, figureFloorY + 1));
      }
      expect(max(joints.legs.first.ankle.dy, 0), lessThanOrEqualTo(figureFloorY));
    }
  });
}
