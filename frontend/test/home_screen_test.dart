import 'package:finguard/app.dart';
import 'package:finguard/screens/context_screen.dart';
import 'package:finguard/screens/home_screen.dart';
import 'package:finguard/screens/risk_lab_screen.dart';
import 'package:finguard/screens/risk_result_screen.dart';
import 'package:finguard/services/app_services.dart';
import 'package:finguard/services/demo_repository.dart';
import 'package:finguard/services/local_store.dart';
import 'package:finguard/services/share_intake.dart';
import 'package:finguard/theme/app_theme.dart';
import 'package:finguard/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  test('shared text normalization rejects blank input and caps length', () {
    expect(normalizeSharedText('   '), isNull);
    final String oversized = List<String>.filled(5001, 'x').join();
    expect(normalizeSharedText(oversized), hasLength(maxSharedTextLength));
  });

  testWidgets('home presents the four focused entry points', (
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
    expect(find.text('Check a UPI ID'), findsOneWidget);
    expect(find.text('Check suspicious message'), findsOneWidget);
    expect(find.byType(WorkspaceAction), findsNWidgets(4));
    expect(find.byKey(const Key('scan_qr_button')), findsOneWidget);
    expect(find.byKey(const Key('paste_upi_button')), findsOneWidget);
    expect(find.byKey(const Key('check_payee_button')), findsOneWidget);
    expect(find.byKey(const Key('message_check_button')), findsOneWidget);
    expect(
      Theme.of(tester.element(find.byType(AppBar))).appBarTheme.backgroundColor,
      AppColors.chrome,
    );
    expect(find.text('Try with demo data'), findsOneWidget);
    expect(find.byKey(const Key('open_risk_lab_button')), findsOneWidget);
    expect(find.text('Start 90-second demo'), findsOneWidget);
    expect(find.textContaining('does not intercept'), findsOneWidget);
    expect(AppColors.teal, const Color(0xFF9BD617));
    expect(AppColors.chrome, const Color(0xFF101A15));
  });

  testWidgets(
    'cold plain-text share opens context pre-filled without analysis',
    (WidgetTester tester) async {
      const String message =
          'Urgent: update KYC now or your account will be blocked.';
      final FakeApi api = FakeApi();
      final FakeShareIntake shareIntake = FakeShareIntake(initialText: message);
      addTearDown(shareIntake.close);
      final AppServices services = AppServices(
        api: api,
        store: MemoryLocalStore(),
        externalActions: FakeExternalActions(),
        demos: const DemoRepository(),
        shareIntake: shareIntake,
      );

      await tester.pumpWidget(FinGuardApp(services: services));
      await tester.pumpAndSettle();

      expect(find.byType(ContextScreen), findsOneWidget);
      final TextField field = tester.widget<TextField>(
        find.byKey(const Key('suspicious_message_field')),
      );
      expect(field.controller?.text, message);
      expect(api.analyzeContextCount, 0);
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const Key('gemini_consent_checkbox')),
            )
            .value,
        isFalse,
      );
    },
  );

  testWidgets('warm text share extracts and analyzes the UPI request once', (
    WidgetTester tester,
  ) async {
    const String upiUri =
        'upi://pay?pa=merchant%40upi&pn=Merchant&am=100&cu=INR';
    final FakeApi api = FakeApi();
    final FakeShareIntake shareIntake = FakeShareIntake();
    addTearDown(shareIntake.close);
    final AppServices services = AppServices(
      api: api,
      store: MemoryLocalStore(),
      externalActions: FakeExternalActions(),
      demos: const DemoRepository(),
      shareIntake: shareIntake,
    );

    await tester.pumpWidget(FinGuardApp(services: services));
    await tester.pump();
    shareIntake.emit('Please review this payment: $upiUri.');
    await tester.pumpAndSettle();

    expect(find.byType(RiskResultScreen), findsOneWidget);
    expect(api.parsePaymentCount, 1);
    expect(api.lastParsedPayment, upiUri);

    shareIntake.emit('A second suspicious message');
    await tester.pump();
    expect(find.byType(ContextScreen), findsNothing);
    expect(api.parsePaymentCount, 1);

    await tester.tap(find.byTooltip('Close result'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(find.byType(ContextScreen), findsOneWidget);
    final TextField sharedMessage = tester.widget<TextField>(
      find.byKey(const Key('suspicious_message_field')),
    );
    expect(sharedMessage.controller?.text, 'A second suspicious message');
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

    // The signal breakdown is a closed-by-default disclosure now.
    await tester.scrollUntilVisible(
      find.byKey(const Key('why_this_score_toggle')),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('why_this_score_toggle')));
    await tester.pump();
    expect(
      find.text('Recipient matches a seeded scam indicator'),
      findsOneWidget,
    );
  });
}
