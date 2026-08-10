import 'package:finguard/screens/context_screen.dart';
import 'package:finguard/services/app_services.dart';
import 'package:finguard/services/demo_repository.dart';
import 'package:finguard/services/local_store.dart';
import 'package:finguard/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  testWidgets('local fallback remains usable when Gemini is unavailable', (
    WidgetTester tester,
  ) async {
    final AppServices services = AppServices(
      api: FakeApi(contextAvailable: false),
      store: MemoryLocalStore(),
      externalActions: FakeExternalActions(),
      demos: const DemoRepository(),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: ContextScreen(services: services),
      ),
    );

    await tester.enterText(
      find.byKey(const Key('suspicious_message_field')),
      'Urgent: update KYC now or your account will be blocked.',
    );
    await tester.scrollUntilVisible(
      find.byKey(const Key('analyze_message_button')),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('analyze_message_button')));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('Local fallback signals'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Local fallback signals'), findsOneWidget);
    expect(find.text('Urgent or pressuring language'), findsOneWidget);
    expect(
      find.text('Check a UPI request with this context'),
      findsOneWidget,
    );
  });
}
