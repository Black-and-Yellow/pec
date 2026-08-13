import 'package:finguard/app.dart';
import 'package:finguard/screens/home_screen.dart';
import 'package:finguard/screens/risk_lab_screen.dart';
import 'package:finguard/services/app_services.dart';
import 'package:finguard/services/demo_repository.dart';
import 'package:finguard/services/local_store.dart';
import 'package:finguard/theme/app_theme.dart';
import 'package:finguard/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  testWidgets('home presents the three focused entry points', (
    WidgetTester tester,
  ) async {
    final FakeApi api = FakeApi();
    final AppServices services = AppServices(
      api: api,
      store: MemoryLocalStore(),
      externalActions: FakeExternalActions(),
      demos: const DemoRepository(),
    );

    await tester.pumpWidget(FinGuardApp(services: services));

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.text('Scan QR'), findsOneWidget);
    expect(find.text('Paste UPI Link'), findsOneWidget);
    expect(find.text('Check suspicious message'), findsOneWidget);
    expect(find.byType(WorkspaceAction), findsNWidgets(3));
    expect(find.byKey(const Key('scan_qr_button')), findsOneWidget);
    expect(find.byKey(const Key('paste_upi_button')), findsOneWidget);
    expect(find.byKey(const Key('message_check_button')), findsOneWidget);
    expect(
      Theme.of(tester.element(find.byType(AppBar))).appBarTheme.backgroundColor,
      AppColors.chrome,
    );
    expect(find.text('Reliable demo cases'), findsOneWidget);
    expect(find.byKey(const Key('open_risk_lab_button')), findsOneWidget);
    expect(find.text('Start 90-second demo'), findsOneWidget);
    expect(find.textContaining('does not intercept'), findsOneWidget);
  });

  testWidgets('home opens the offline Risk Lab comparison', (
    WidgetTester tester,
  ) async {
    final AppServices services = AppServices(
      api: FakeApi(),
      store: MemoryLocalStore(),
      externalActions: FakeExternalActions(),
      demos: const DemoRepository(),
    );

    await tester.pumpWidget(FinGuardApp(services: services));
    final Finder openLab = find.byKey(const Key('open_risk_lab_button'));
    await tester.scrollUntilVisible(
      openLab,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(openLab);
    await tester.pumpAndSettle();

    expect(find.byType(RiskLabScreen), findsOneWidget);
    expect(find.text('OFFLINE SHOWCASE'), findsOneWidget);
    expect(find.text('Compare policy evidence'), findsOneWidget);
  });

  testWidgets('seeded fake KYC demo opens the locked high-risk result', (
    WidgetTester tester,
  ) async {
    final AppServices services = AppServices(
      api: FakeApi(),
      store: MemoryLocalStore(),
      externalActions: FakeExternalActions(),
      demos: const DemoRepository(),
    );

    await tester.pumpWidget(FinGuardApp(services: services));
    await tester.scrollUntilVisible(
      find.text('Fake KYC request'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Fake KYC request'));
    await tester.pumpAndSettle();

    expect(find.text('HIGH RISK'), findsOneWidget);
    expect(find.byKey(const Key('risk_score')), findsOneWidget);
    expect(find.text('99'), findsOneWidget);
    expect(find.text('SEEDED DEMO DATA'), findsOneWidget);
    expect(
      find.text('Recipient matches a seeded scam indicator'),
      findsOneWidget,
    );
  });
}
