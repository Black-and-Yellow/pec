import 'package:finguard/screens/account_screen.dart';
import 'package:finguard/screens/paste_screen.dart';
import 'package:finguard/services/app_services.dart';
import 'package:finguard/services/auth_controller.dart';
import 'package:finguard/services/demo_repository.dart';
import 'package:finguard/services/local_store.dart';
import 'package:finguard/services/threat_environment.dart';
import 'package:finguard/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  group('call activity reporting', () {
    test('a platform value FinGuard does not know degrades to no call', () {
      expect(CallActivity.fromPlatform('SOMETHING_NEW'), CallActivity.none);
      expect(CallActivity.fromPlatform(null), CallActivity.none);
    });

    test('a ringing call is not treated as an active one', () {
      expect(CallActivity.ringing.isActive, isFalse);
      expect(CallActivity.cellular.isActive, isTrue);
      expect(CallActivity.voiceOverIp.isActive, isTrue);
      expect(CallActivity.unknown.isActive, isTrue);
      expect(CallActivity.none.isActive, isFalse);
    });

    test('the no-op environment reports nothing on unsupported platforms', () async {
      const NoopThreatEnvironment environment = NoopThreatEnvironment();
      expect(await environment.callActivity(), CallActivity.none);
      expect(await environment.hasCallStatePermission(), isFalse);
    });
  });

  testWidgets('a check reports the live call state to the risk service', (
    WidgetTester tester,
  ) async {
    final FakeApi api = FakeApi();
    final AppServices services = AppServices(
      api: api,
      store: MemoryLocalStore(),
      externalActions: FakeExternalActions(),
      demos: const DemoRepository(),
      threatEnvironment: FakeThreatEnvironment(
        call: CallActivity.voiceOverIp,
        tools: const <String>['ANYDESK'],
      ),
    );

    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.light, home: PasteScreen(services: services)),
    );
    await tester.enterText(
      find.byKey(const Key('upi_uri_field')),
      'upi://pay?pa=merchant%40upi&pn=Merchant&am=100&cu=INR',
    );
    await tester.tap(find.byKey(const Key('analyze_payment_button')));
    await tester.pumpAndSettle();

    expect(api.lastCallActivity, CallActivity.voiceOverIp);
    expect(api.lastRemoteAccessTools, <String>['ANYDESK']);
  });

  testWidgets('a check with no call reports none rather than omitting it', (
    WidgetTester tester,
  ) async {
    final FakeApi api = FakeApi();
    final AppServices services = AppServices(
      api: api,
      store: MemoryLocalStore(),
      externalActions: FakeExternalActions(),
      demos: const DemoRepository(),
      threatEnvironment: FakeThreatEnvironment(),
    );

    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.light, home: PasteScreen(services: services)),
    );
    await tester.enterText(
      find.byKey(const Key('upi_uri_field')),
      'upi://pay?pa=merchant%40upi&pn=Merchant&am=100&cu=INR',
    );
    await tester.tap(find.byKey(const Key('analyze_payment_button')));
    await tester.pumpAndSettle();

    expect(api.lastCallActivity, CallActivity.none);
  });

  testWidgets('the telephony permission is requested from settings, not mid-check', (
    WidgetTester tester,
  ) async {
    final FakeThreatEnvironment environment = FakeThreatEnvironment();
    final AppServices services = AppServices(
      api: FakeApi(),
      store: MemoryLocalStore(),
      externalActions: FakeExternalActions(),
      demos: const DemoRepository(),
      threatEnvironment: environment,
      auth: AuthController(api: FakeAuthApi(), store: MemoryAuthStore()),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: AccountScreen(services: services),
      ),
    );
    await tester.pumpAndSettle();

    expect(environment.permissionRequestCount, 0);
    expect(find.byKey(const Key('call_detection_card')), findsOneWidget);

    await tester.tap(find.byKey(const Key('enable_call_detection_button')));
    await tester.pumpAndSettle();

    expect(environment.permissionRequestCount, 1);
    expect(
      find.byKey(const Key('enable_call_detection_button')),
      findsNothing,
      reason: 'a granted permission should stop offering itself',
    );
  });

  testWidgets('declining the permission keeps the feature usable', (
    WidgetTester tester,
  ) async {
    final FakeThreatEnvironment environment = FakeThreatEnvironment(
      grantOnRequest: false,
    );
    final AppServices services = AppServices(
      api: FakeApi(),
      store: MemoryLocalStore(),
      externalActions: FakeExternalActions(),
      demos: const DemoRepository(),
      threatEnvironment: environment,
      auth: AuthController(api: FakeAuthApi(), store: MemoryAuthStore()),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: AccountScreen(services: services),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('enable_call_detection_button')));
    await tester.pumpAndSettle();

    expect(find.textContaining('still detects internet calls'), findsOneWidget);
  });
}