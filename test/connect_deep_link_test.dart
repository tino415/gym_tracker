import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/data/providers.dart';
import 'package:gym_tracker/main.dart';
import 'package:gym_tracker/phone/phone_app.dart';
import 'package:gym_tracker/phone/sign_in_screen.dart';
import 'package:gym_tracker/sync/auth_service.dart';
import 'package:gym_tracker/sync/connect_gateway.dart';
import 'package:gym_tracker/sync/firestore_backend.dart';

import '../integration_test/support/connect_request.dart';

class _SignedInUser implements User {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _UnusedGateway implements ConnectGateway {
  @override
  Future<Uri> decide(String request, ConnectDecision decision) =>
      throw UnimplementedError();
}

void main() {
  testWidgets(
    'the launch route survives the boot screen and sign-in, then asks for consent',
    (tester) async {
      final connectRoute = '/connect?request=${fakeConnectRequest('Claude')}';
      final reportedUris = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.navigation,
        (call) async {
          if (call.method == 'routeInformationUpdated') {
            reportedUris.add((call.arguments as Map)['uri'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.navigation,
          null,
        ),
      );
      final firebaseReady = Completer<bool>();
      final authState = StreamController<User?>();
      addTearDown(authState.close);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            launchRouteProvider.overrideWithValue(connectRoute),
            firestoreDirectProvider.overrideWithValue(true),
            firebaseReadyProvider.overrideWith((ref) => firebaseReady.future),
            authStateProvider.overrideWith((ref) => authState.stream),
            connectGatewayProvider.overrideWithValue(_UnusedGateway()),
          ],
          child: const GymTrackerRoot(isWatch: false),
        ),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      firebaseReady.complete(true);
      authState.add(null);
      await tester.pumpAndSettle();
      expect(find.byType(SignInScreen), findsOneWidget);

      authState.add(_SignedInUser());
      await tester.pumpAndSettle();
      expect(find.text('Connect Claude to GymTracker?'), findsOneWidget);
      expect(reportedUris, isNotEmpty);
      expect(reportedUris, everyElement(connectRoute));
    },
  );

  testWidgets('the boot screen moves from waiting to the backend failure', (
    tester,
  ) async {
    final firebaseReady = Completer<bool>();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          firestoreDirectProvider.overrideWithValue(true),
          firebaseReadyProvider.overrideWith((ref) => firebaseReady.future),
        ],
        child: const GymTrackerRoot(isWatch: false),
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    firebaseReady.complete(false);
    await tester.pumpAndSettle();
    expect(find.text('Cloud backend unavailable.'), findsOneWidget);
  });
}
