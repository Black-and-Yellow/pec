import 'package:finguard/models/history_entry.dart';
import 'package:finguard/models/payment.dart';
import 'package:finguard/models/risk.dart';
import 'package:finguard/screens/history_screen.dart';
import 'package:finguard/services/app_services.dart';
import 'package:finguard/services/demo_repository.dart';
import 'package:finguard/services/local_store.dart';
import 'package:finguard/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  testWidgets('history rows remain usable at narrow width and large text', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final MemoryLocalStore store = MemoryLocalStore();
    await store.addHistory(
      HistoryEntry(
        id: 'large-text-history',
        checkedAt: DateTime.utc(2026, 8, 12),
        payment: const Payment(
          upiUri: 'upi://pay?pa=merchant%40upi&pn=Merchant&am=75&cu=INR',
          payeeVpa: 'merchant@upi',
          payeeName: 'A deliberately long merchant recipient name',
          amount: 75,
          currency: 'INR',
        ),
        assessment: const RiskAssessment(
          score: 70,
          level: RiskLevel.highRisk,
          signals: <RiskSignal>[],
          recommendedAction: 'Stop here.',
        ),
      ),
    );
    final AppServices services = AppServices(
      api: FakeApi(),
      store: store,
      externalActions: FakeExternalActions(),
      demos: const DemoRepository(),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: HistoryScreen(services: services),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('70/100'), findsOneWidget);
    expect(find.text('HIGH RISK'), findsOneWidget);
  });

  testWidgets('a result reopened from history cannot hand off to UPI', (
    WidgetTester tester,
  ) async {
    final MemoryLocalStore store = MemoryLocalStore();
    final FakeExternalActions actions = FakeExternalActions();
    const Payment payment = Payment(
      upiUri: 'upi://pay?pa=history%40upi&pn=History&am=75&cu=INR',
      payeeVpa: 'history@upi',
      payeeName: 'History',
      amount: 75,
      currency: 'INR',
    );
    const RiskAssessment assessment = RiskAssessment(
      score: 0,
      level: RiskLevel.safe,
      signals: <RiskSignal>[],
      recommendedAction: 'Review this saved result.',
    );
    await store.addHistory(
      HistoryEntry(
        id: 'history-1',
        checkedAt: DateTime.utc(2026, 8, 12),
        payment: payment,
        assessment: assessment,
      ),
    );
    final AppServices services = AppServices(
      api: FakeApi(),
      store: store,
      externalActions: actions,
      demos: const DemoRepository(),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: HistoryScreen(services: services),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('History').first);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('payment_handoff_unavailable')),
      250,
      scrollable: find.byType(Scrollable).first,
    );

    expect(
      find.byKey(const Key('payment_handoff_unavailable')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('continue_upi_button')), findsNothing);
    expect(find.byKey(const Key('continue_anyway_button')), findsNothing);
    expect(actions.upiOpenCount, 0);
  });
}
