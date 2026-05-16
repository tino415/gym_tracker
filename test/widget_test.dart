import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/data/database.dart';
import 'package:gym_tracker/data/providers.dart';
import 'package:gym_tracker/phone/phone_app.dart';

void main() {
  testWidgets('phone app renders empty workouts state', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          workoutSummariesStreamProvider.overrideWith(
            (ref) => Stream.value(<WorkoutSummary>[]),
          ),
          exercisesStreamProvider.overrideWith(
            (ref) => Stream.value(<Exercise>[]),
          ),
          recentSessionsStreamProvider.overrideWith(
            (ref) => Stream.value(<Session>[]),
          ),
        ],
        child: const PhoneApp(),
      ),
    );
    await tester.pump();

    expect(find.text('No workouts yet'), findsOneWidget);
  });
}
