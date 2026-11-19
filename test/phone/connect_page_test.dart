import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gym_tracker/l10n/l10n.dart';
import 'package:gym_tracker/phone/connect/connect_page.dart';
import 'package:gym_tracker/sync/connect_gateway.dart';

import '../../integration_test/support/connect_request.dart';

class _FakeGateway implements ConnectGateway {
  _FakeGateway({
    this.refuse = false,
    this.redirect = 'https://claude.ai/cb?code=c',
  });

  final bool refuse;
  final String redirect;
  final decisions = <ConnectDecision>[];

  @override
  Future<Uri> decide(String request, ConnectDecision decision) async {
    decisions.add(decision);
    if (refuse) throw ConnectRefused(400);
    return Uri.parse(redirect);
  }
}

Future<void> _pump(
  WidgetTester tester, {
  required String? request,
  ConnectGateway? gateway,
  List<Uri>? redirects,
}) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        connectGatewayProvider.overrideWithValue(gateway),
        connectRedirectProvider.overrideWithValue((uri) async {
          redirects?.add(uri);
        }),
      ],
      child: MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: ConnectPage(request: request),
      ),
    ),
  );
}

void main() {
  testWidgets('names the assistant and warns before anything is allowed', (
    tester,
  ) async {
    await _pump(
      tester,
      request: fakeConnectRequest('Claude'),
      gateway: _FakeGateway(),
    );

    expect(find.text('Connect Claude to GymTracker?'), findsOneWidget);
    expect(find.byKey(const Key('connect-warning')), findsOneWidget);
    expect(find.textContaining('Claude'), findsWidgets);
  });

  testWidgets('allow sends the user on to the address the server returned', (
    tester,
  ) async {
    final gateway = _FakeGateway();
    final redirects = <Uri>[];
    await _pump(
      tester,
      request: fakeConnectRequest('Claude'),
      gateway: gateway,
      redirects: redirects,
    );

    await tester.tap(find.byKey(const Key('connect-allow')));
    await tester.pump();

    expect(gateway.decisions, [ConnectDecision.allow]);
    expect(redirects, [Uri.parse('https://claude.ai/cb?code=c')]);
  });

  testWidgets('deny reports the decision and follows the redirect', (
    tester,
  ) async {
    final gateway = _FakeGateway(
      redirect: 'https://claude.ai/cb?error=access_denied',
    );
    final redirects = <Uri>[];
    await _pump(
      tester,
      request: fakeConnectRequest('Claude'),
      gateway: gateway,
      redirects: redirects,
    );

    await tester.tap(find.byKey(const Key('connect-deny')));
    await tester.pump();

    expect(gateway.decisions, [ConnectDecision.deny]);
    expect(redirects.single.queryParameters['error'], 'access_denied');
  });

  testWidgets('a refusal stays on the page and says so', (tester) async {
    final redirects = <Uri>[];
    await _pump(
      tester,
      request: fakeConnectRequest('Claude'),
      gateway: _FakeGateway(refuse: true),
      redirects: redirects,
    );

    await tester.tap(find.byKey(const Key('connect-allow')));
    await tester.pump();

    expect(find.byKey(const Key('connect-failed')), findsOneWidget);
    expect(redirects, isEmpty);
  });

  testWidgets('a redirect that is not http(s) is never followed', (
    tester,
  ) async {
    final redirects = <Uri>[];
    await _pump(
      tester,
      request: fakeConnectRequest('Claude'),
      gateway: _FakeGateway(redirect: 'javascript:alert(1)'),
      redirects: redirects,
    );

    await tester.tap(find.byKey(const Key('connect-allow')));
    await tester.pump();

    expect(redirects, isEmpty);
    expect(find.byKey(const Key('connect-failed')), findsOneWidget);
  });

  testWidgets(
    'no request, unreadable request or no server shows the invalid link',
    (tester) async {
      await _pump(tester, request: null, gateway: _FakeGateway());
      expect(find.byKey(const Key('connect-invalid')), findsOneWidget);

      await _pump(tester, request: 'garbage', gateway: _FakeGateway());
      expect(find.byKey(const Key('connect-invalid')), findsOneWidget);

      await _pump(tester, request: fakeConnectRequest('Claude'), gateway: null);
      expect(find.byKey(const Key('connect-invalid')), findsOneWidget);
      expect(find.byKey(const Key('connect-allow')), findsNothing);
    },
  );
}
