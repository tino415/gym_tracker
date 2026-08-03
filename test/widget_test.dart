import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/data/database.dart';
import 'package:gym_tracker/data/providers.dart';
import 'package:gym_tracker/phone/phone_app.dart';

void main() {
  testWidgets('phone app renders empty routines state', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          routineSummariesStreamProvider.overrideWith(
            (ref) => Stream.value(<RoutineSummary>[]),
          ),
          exercisesStreamProvider.overrideWith(
            (ref) => Stream.value(<Exercise>[]),
          ),
          recentWorkoutsStreamProvider.overrideWith(
            (ref) => Stream.value(<Workout>[]),
          ),
          // The routines page offers to resume an unfinished workout. Without
          // this override the banner reaches the real database provider, which
          // opens a file and leaves a pending timer.
          inProgressWorkoutStreamProvider.overrideWith(
            (ref) => Stream.value(null),
          ),
        ],
        child: const PhoneApp(),
      ),
    );
    await tester.pump();

    expect(find.text('No routines yet'), findsOneWidget);
  });
}
