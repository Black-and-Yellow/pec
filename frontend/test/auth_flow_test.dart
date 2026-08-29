import 'package:finguard/app.dart';
import 'package:finguard/screens/auth_form_screen.dart';
import 'package:finguard/screens/home_screen.dart';
import 'package:finguard/screens/welcome_screen.dart';
import 'package:finguard/services/api_service.dart';
import 'package:finguard/services/app_services.dart';
import 'package:finguard/services/auth_controller.dart';
import 'package:finguard/services/demo_repository.dart';
import 'package:finguard/services/local_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

AppServices _services({
  required FakeAuthApi api,
  required MemoryAuthStore store,
}) => AppServices(
  api: FakeApi(),
  store: MemoryLocalStore(),
  externalActions: FakeExternalActions(),
  demos: const DemoRepository(),
  auth: AuthController(api: api, store: store),
);

void main() {
  test(
    'retryable refresh failures preserve the stored session token',
    () async {
      for (final ApiException failure in <ApiException>[
        const ApiException('Offline', retryable: true),
        const ApiException(
          'Service unavailable',
          retryable: true,
          statusCode: 503,
          errorCode: 'INTERNAL_ERROR',
        ),
      ]) {
        final FakeAuthApi api = FakeAuthApi(refreshError: failure);
        final MemoryAuthStore store = MemoryAuthStore()
          ..refreshToken = 'existing-refresh-token-value-that-is-long-enough';
        final AuthController auth = AuthController(api: api, store: store);

        await auth.initialize();

        expect(auth.status, AuthStatus.signedOut);
        expect(auth.busy, isFalse);
        expect(auth.canRetrySessionRestore, isTrue);
        expect(
          store.refreshToken,
          'existing-refresh-token-value-that-is-long-enough',
        );

        api.refreshError = null;
        await auth.initialize();
        expect(auth.status, AuthStatus.authenticated);
        expect(api.refreshCount, 2);
        expect(store.refreshToken, api.session.refreshToken);
        auth.dispose();
      }
    },
  );

  test(
    'definitive invalid-session response clears stored credentials',
    () async {
      final FakeAuthApi api = FakeAuthApi(
        refreshError: const ApiException(
          'Session is invalid',
          statusCode: 401,
          errorCode: 'INVALID_SESSION',
        ),
      );
      final MemoryAuthStore store = MemoryAuthStore()
        ..refreshToken = 'existing-refresh-token-value-that-is-long-enough';
      final AuthController auth = AuthController(api: api, store: store);

      await auth.initialize();

      expect(auth.status, AuthStatus.signedOut);
      expect(auth.busy, isFalse);
      expect(auth.error, isNull);
      expect(store.refreshToken, isNull);
      expect(auth.canRetrySessionRestore, isFalse);
      auth.dispose();
    },
  );

  test(
    'secure-store delete failure exits loading and remains recoverable',
    () async {
      final FakeAuthApi api = FakeAuthApi(
        refreshError: const ApiException(
          'Session is invalid',
          statusCode: 401,
          errorCode: 'INVALID_SESSION',
        ),
      );
      final MemoryAuthStore store = MemoryAuthStore(failClear: true)
        ..refreshToken = 'existing-refresh-token-value-that-is-long-enough';
      final AuthController auth = AuthController(api: api, store: store);

      await auth.initialize();

      expect(auth.status, AuthStatus.signedOut);
      expect(auth.busy, isFalse);
      expect(auth.error, contains('secure session storage'));
      expect(auth.canRetrySessionRestore, isTrue);
      expect(store.refreshToken, isNotNull);
      auth.dispose();
    },
  );

  testWidgets('guest mode remains a deliberate privacy-preserving path', (
    WidgetTester tester,
  ) async {
    final MemoryAuthStore store = MemoryAuthStore();
    await tester.pumpWidget(
      FinGuardApp(
        services: _services(api: FakeAuthApi(), store: store),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(WelcomeScreen), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const Key('continue_guest_button')),
      220,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('continue_guest_button')));
    await tester.pumpAndSettle();
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(store.guestMode, isTrue);

    await tester.tap(find.byTooltip('Guest account and privacy'));
    await tester.pumpAndSettle();
    expect(find.text('Private guest mode'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const Key('leave_guest_button')),
      220,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('leave_guest_button')));
    await tester.pumpAndSettle();
    expect(find.byType(WelcomeScreen), findsOneWidget);
  });

  testWidgets('account registration transitions into the protected app shell', (
    WidgetTester tester,
  ) async {
    final MemoryAuthStore store = MemoryAuthStore();
    await tester.pumpWidget(
      FinGuardApp(
        services: _services(api: FakeAuthApi(), store: store),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('create_account_button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('display_name_field')),
      'Test Person',
    );
    await tester.enterText(
      find.byKey(const Key('email_field')),
      'person@example.com',
    );
    await tester.enterText(
      find.byKey(const Key('password_field')),
      'safe-password-42',
    );
    await tester.enterText(
      find.byKey(const Key('confirm_password_field')),
      'safe-password-42',
    );
    await tester.scrollUntilVisible(
      find.byKey(const Key('submit_auth_button')),
      220,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.byKey(const Key('submit_auth_button')));
    await tester.pumpAndSettle();

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(store.refreshToken, isNotNull);
    expect(find.byTooltip('Account and privacy'), findsOneWidget);
  });

  testWidgets('stored refresh session restores the signed-in account', (
    WidgetTester tester,
  ) async {
    final FakeAuthApi api = FakeAuthApi();
    final MemoryAuthStore store = MemoryAuthStore()
      ..refreshToken = 'existing-refresh-token-value-that-is-long-enough';
    await tester.pumpWidget(
      FinGuardApp(
        services: _services(api: api, store: store),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(api.refreshCount, 1);
    expect(find.byTooltip('Account and privacy'), findsOneWidget);
  });

  testWidgets('secure-store read failure leaves AuthGate recoverable', (
    WidgetTester tester,
  ) async {
    final MemoryAuthStore store = MemoryAuthStore(failReadRefresh: true);
    await tester.pumpWidget(
      FinGuardApp(
        services: _services(api: FakeAuthApi(), store: store),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(WelcomeScreen), findsOneWidget);
    expect(find.text('Restoring your secure session…'), findsNothing);
    expect(find.textContaining('secure session storage'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    final FilledButton createButton = tester.widget<FilledButton>(
      find.byKey(const Key('create_account_button')),
    );
    expect(createButton.onPressed, isNotNull);
  });

  testWidgets('secure-store write failure releases the auth form busy state', (
    WidgetTester tester,
  ) async {
    final MemoryAuthStore store = MemoryAuthStore(failSaveRefresh: true);
    await tester.pumpWidget(
      FinGuardApp(
        services: _services(api: FakeAuthApi(), store: store),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const Key('sign_in_button')),
      220,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('sign_in_button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('email_field')),
      'person@example.com',
    );
    await tester.enterText(
      find.byKey(const Key('password_field')),
      'safe-password-42',
    );
    await tester.tap(find.byKey(const Key('submit_auth_button')));
    await tester.pumpAndSettle();

    expect(find.byType(AuthFormScreen), findsOneWidget);
    expect(find.textContaining('secure session storage'), findsOneWidget);
    final FilledButton submitButton = tester.widget<FilledButton>(
      find.byKey(const Key('submit_auth_button')),
    );
    expect(submitButton.onPressed, isNotNull);
    expect(store.refreshToken, isNull);
  });

  testWidgets('signed-in user can permanently delete the account', (
    WidgetTester tester,
  ) async {
    final FakeAuthApi api = FakeAuthApi();
    final MemoryAuthStore store = MemoryAuthStore()
      ..refreshToken = 'existing-refresh-token-value-that-is-long-enough';
    await tester.pumpWidget(
      FinGuardApp(
        services: _services(api: api, store: store),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Account and privacy'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('delete_account_button')),
      220,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('delete_account_button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('delete_confirmation_field')),
      'DELETE',
    );
    await tester.enterText(
      find.byKey(const Key('delete_password_field')),
      'safe-password-42',
    );
    await tester.tap(find.byKey(const Key('confirm_delete_account_button')));
    await tester.pumpAndSettle();

    expect(api.deleteCount, 1);
    expect(store.refreshToken, isNull);
    expect(find.byType(WelcomeScreen), findsOneWidget);
  });

  testWidgets('account deletion stays open until confirmation is valid', (
    WidgetTester tester,
  ) async {
    final FakeAuthApi api = FakeAuthApi();
    final MemoryAuthStore store = MemoryAuthStore()
      ..refreshToken = 'existing-refresh-token-value-that-is-long-enough';
    await tester.pumpWidget(
      FinGuardApp(
        services: _services(api: api, store: store),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Account and privacy'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('delete_account_button')),
      220,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('delete_account_button')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('delete_confirmation_field')),
      'DELETE?',
    );
    await tester.tap(find.byKey(const Key('confirm_delete_account_button')));
    await tester.pump();
    expect(find.text('Type DELETE exactly to continue.'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('confirm_delete_account_button')),
          )
          .onPressed,
      isNotNull,
    );
    expect(find.text('Delete your account?'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('delete_confirmation_field')),
      'DELETE',
    );
    await tester.enterText(
      find.byKey(const Key('delete_password_field')),
      'safe-password-42',
    );
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('confirm_delete_account_button')),
          )
          .onPressed,
      isNotNull,
    );
    expect(api.deleteCount, 0);
  });
}
