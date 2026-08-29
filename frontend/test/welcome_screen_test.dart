import 'package:finguard/app.dart';
import 'package:finguard/screens/welcome_screen.dart';
import 'package:finguard/services/app_services.dart';
import 'package:finguard/services/auth_controller.dart';
import 'package:finguard/services/demo_repository.dart';
import 'package:finguard/services/local_store.dart';
import 'package:finguard/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  testWidgets('welcome keeps the primary choices visible on a phone viewport', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final AuthController auth = AuthController(
      api: FakeAuthApi(),
      store: MemoryAuthStore(),
    );
    addTearDown(auth.dispose);
    await tester.pumpWidget(
      FinGuardApp(
        services: AppServices(
          api: FakeApi(),
          store: MemoryLocalStore(),
          externalActions: FakeExternalActions(),
          demos: const DemoRepository(),
          auth: auth,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(WelcomeScreen), findsOneWidget);
    expect(find.text('Check before you pay.'), findsOneWidget);
    expect(find.byKey(const Key('create_account_button')), findsOneWidget);
    expect(find.byKey(const Key('sign_in_button')), findsOneWidget);
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
      AppColors.chrome,
    );
    expect(tester.takeException(), isNull);
  });
}
