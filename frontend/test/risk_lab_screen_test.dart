import 'package:finguard/screens/risk_lab_screen.dart';
import 'package:finguard/screens/risk_result_screen.dart';
import 'package:finguard/services/app_services.dart';
import 'package:finguard/services/demo_repository.dart';
import 'package:finguard/services/local_store.dart';
import 'package:finguard/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  testWidgets('compares bundled outcomes and opens a view-only result', (
    WidgetTester tester,
  ) async {
    final FakeExternalActions externalActions = FakeExternalActions();
    final AppServices services = AppServices(
      api: FakeApi(),
      store: MemoryLocalStore(),
      externalActions: externalActions,
      demos: const DemoRepository(),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: RiskLabScreen(services: services),
      ),
    );

    expect(find.byKey(const Key('risk_lab_screen')), findsOneWidget);
    expect(find.text('OFFLINE SHOWCASE'), findsOneWidget);
    expect(find.textContaining('never call the API'), findsOneWidget);
    expect(find.text('SAFE'), findsWidgets);
    expect(find.byKey(const Key('risk_lab_score')), findsOneWidget);
    expect(find.text('0'), findsWidgets);
    expect(
      find.text('The bundled policy outcome contains no risk-raising signals.'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('risk_lab_case_marketplace-seller')));
    await tester.pumpAndSettle();

    expect(find.text('CAUTION'), findsWidgets);
    expect(find.text('33'), findsWidgets);
    expect(
      find.text('This is a first-time recipient on this device'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('risk_lab_case_fake-kyc')));
    await tester.pumpAndSettle();

    expect(find.text('HIGH RISK'), findsWidgets);
    expect(find.text('99'), findsWidgets);
    expect(
      find.text('Recipient matches a seeded scam indicator'),
      findsOneWidget,
    );

    final Finder openResult = find.byKey(const Key('risk_lab_open_result'));
    await tester.scrollUntilVisible(
      openResult,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(openResult);
    await tester.pumpAndSettle();

    expect(find.byType(RiskResultScreen), findsOneWidget);
    expect(find.text('SEEDED DEMO DATA'), findsOneWidget);
    expect(
      find.byKey(const Key('payment_handoff_unavailable')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('continue_upi_button')), findsNothing);
    expect(find.byKey(const Key('continue_anyway_button')), findsNothing);
    expect(find.text('Prepare report'), findsNothing);
    expect(find.text('Alert trusted contact'), findsNothing);
    expect(find.byKey(const Key('already_paid_button')), findsNothing);
    expect(externalActions.upiOpenCount, 0);
    expect(externalActions.shareCount, 0);
  });
}
