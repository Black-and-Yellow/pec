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
  testWidgets('guides SAFE to CAUTION to HIGH with bounded controls', (
    WidgetTester tester,
  ) async {
    await _pumpRiskLab(tester);

    expect(find.byKey(const Key('risk_lab_screen')), findsOneWidget);
    expect(find.text('OFFLINE SHOWCASE'), findsOneWidget);
    expect(find.textContaining('never call the API'), findsOneWidget);
    expect(find.text('SAFE'), findsWidgets);
    expect(_score(tester), '0');
    expect(find.text('Case 1 of 4'), findsOneWidget);
    expect(_previousButton(tester).onPressed, isNull);
    expect(_nextButton(tester).onPressed, isNotNull);
    expect(
      find.text('The bundled policy outcome contains no risk-raising signals.'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('risk_lab_next_case')));
    await tester.pumpAndSettle();

    expect(find.text('SAFE'), findsWidgets);
    expect(_score(tester), '23');
    expect(find.text('Case 2 of 4'), findsOneWidget);
    expect(_previousButton(tester).onPressed, isNotNull);
    expect(_nextButton(tester).onPressed, isNotNull);
    expect(find.text('Payment amount is not specified'), findsOneWidget);

    await tester.tap(find.byKey(const Key('risk_lab_next_case')));
    await tester.pumpAndSettle();

    expect(find.text('CAUTION'), findsWidgets);
    expect(_score(tester), '37');
    expect(find.text('Case 3 of 4'), findsOneWidget);
    expect(_previousButton(tester).onPressed, isNotNull);
    expect(_nextButton(tester).onPressed, isNotNull);

    await tester.tap(find.byKey(const Key('risk_lab_next_case')));
    await tester.pumpAndSettle();

    expect(find.text('HIGH RISK'), findsWidgets);
    expect(_score(tester), '100');
    expect(find.text('Case 4 of 4'), findsOneWidget);
    expect(_nextButton(tester).onPressed, isNull);
    expect(
      find.text('Recipient matches a seeded scam indicator'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('risk_lab_previous_case')));
    await tester.pumpAndSettle();

    expect(_score(tester), '37');
    expect(find.text('Case 3 of 4'), findsOneWidget);
  });

  testWidgets('spectrum markers select the existing bundled outcomes', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    await _pumpRiskLab(tester);

    expect(
      tester.getSemantics(
        find.byKey(const Key('risk_lab_spectrum_coffee-shop')),
      ),
      matchesSemantics(
        label: 'Select Coffee-shop QR, SAFE, score 0 of 100',
        isButton: true,
        hasSelectedState: true,
        isSelected: true,
        hasTapAction: true,
      ),
    );

    await tester.tap(
      find.byKey(const Key('risk_lab_spectrum_marketplace-seller')),
    );
    await tester.pumpAndSettle();

    expect(_score(tester), '37');
    expect(find.text('Case 3 of 4'), findsOneWidget);

    await tester.tap(find.byKey(const Key('risk_lab_spectrum_fake-kyc')));
    await tester.pumpAndSettle();

    expect(_score(tester), '100');
    expect(find.text('Case 4 of 4'), findsOneWidget);

    await tester.tap(find.byKey(const Key('risk_lab_spectrum_coffee-shop')));
    await tester.pumpAndSettle();

    expect(_score(tester), '0');
    expect(find.text('Case 1 of 4'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('guided demo drill-down remains strictly view-only', (
    WidgetTester tester,
  ) async {
    final FakeExternalActions externalActions = FakeExternalActions();
    await _pumpRiskLab(tester, externalActions: externalActions);

    await tester.tap(find.byKey(const Key('risk_lab_spectrum_fake-kyc')));
    await tester.pumpAndSettle();

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

  testWidgets('guided controls fit a narrow large-text viewport', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await _pumpRiskLab(tester, textScaler: const TextScaler.linear(2));

    expect(find.byKey(const Key('risk_lab_case_progress')), findsOneWidget);
    expect(
      find.byKey(const Key('risk_lab_spectrum_coffee-shop')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('risk_lab_spectrum_tea-stall')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('risk_lab_spectrum_marketplace-seller')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('risk_lab_spectrum_fake-kyc')), findsOneWidget);
    final Finder next = find.byKey(const Key('risk_lab_next_case'));
    await tester.ensureVisible(next);
    await tester.pumpAndSettle();
    await tester.tap(next);
    await tester.pumpAndSettle();
    expect(find.text('Case 2 of 4'), findsOneWidget);
    await tester.ensureVisible(next);
    await tester.pumpAndSettle();
    await tester.tap(next);
    await tester.pumpAndSettle();
    expect(find.text('Case 3 of 4'), findsOneWidget);
    await tester.ensureVisible(next);
    await tester.pumpAndSettle();
    await tester.tap(next);
    await tester.pumpAndSettle();
    expect(find.text('Case 4 of 4'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpRiskLab(
  WidgetTester tester, {
  FakeExternalActions? externalActions,
  TextScaler? textScaler,
}) async {
  final AppServices services = AppServices(
    api: FakeApi(),
    store: MemoryLocalStore(),
    externalActions: externalActions ?? FakeExternalActions(),
    demos: const DemoRepository(),
  );

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      builder: textScaler == null
          ? null
          : (BuildContext context, Widget? child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: textScaler),
              child: child!,
            ),
      home: RiskLabScreen(services: services),
    ),
  );
}

String? _score(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('risk_lab_score'))).data;

OutlinedButton _previousButton(WidgetTester tester) => tester
    .widget<OutlinedButton>(find.byKey(const Key('risk_lab_previous_case')));

OutlinedButton _nextButton(WidgetTester tester) =>
    tester.widget<OutlinedButton>(find.byKey(const Key('risk_lab_next_case')));
