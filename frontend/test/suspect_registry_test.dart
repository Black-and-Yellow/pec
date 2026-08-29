import 'package:finguard/models/payee_trust.dart';
import 'package:finguard/models/payment.dart';
import 'package:finguard/models/risk.dart';
import 'package:finguard/screens/risk_result_screen.dart';
import 'package:finguard/services/app_services.dart';
import 'package:finguard/services/demo_repository.dart';
import 'package:finguard/services/local_store.dart';
import 'package:finguard/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

const Payment _payment = Payment(
  upiUri: 'upi://pay?pa=secure-kyc-update%40okaxis&pn=SBI%20Refund&am=25000&cu=INR',
  payeeVpa: 'secure-kyc-update@okaxis',
  payeeName: 'SBI Refund',
  amount: 25000,
  currency: 'INR',
);

const RiskSignal _muleSignal = RiskSignal(
  code: 'MULE_ACCOUNT_SIGNATURE',
  label: 'This address is collecting like a money-mule account',
  weight: 22,
  evidence: '57 different people have checked this address in 9 day(s).',
);

const RiskSignal _nameSignal = RiskSignal(
  code: 'PAYEE_NAME_UNVERIFIED',
  label: 'The claimed payee name is not independently verified',
  weight: 14,
  evidence: 'The claimed payee name uses a bank name the handle does not back.',
);

RiskAssessment _assessment({
  RiskLevel level = RiskLevel.highRisk,
  List<RiskSignal> signals = const <RiskSignal>[_muleSignal],
}) => RiskAssessment(
  assessmentId: 'assessment-registry',
  score: level == RiskLevel.safe ? 8 : 80,
  level: level,
  signals: signals,
  recommendedAction: 'Stop and verify independently.',
);

void main() {
  late FakeExternalActions actions;

  setUp(() => actions = FakeExternalActions());

  AppServices buildServices() => AppServices(
    api: FakeApi(),
    store: MemoryLocalStore(),
    externalActions: actions,
    demos: const DemoRepository(),
  );

  Future<void> pumpResult(
    WidgetTester tester, {
    required RiskAssessment assessment,
    PayeeTrust? trust,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: RiskResultScreen(
          services: buildServices(),
          payment: _payment,
          assessment: assessment,
          payeeTrust: trust,
          paymentHandoffEnabled: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  PayeeTrust trustOf({required String grade, bool impersonation = false}) =>
      PayeeTrust.fromApiJson(
        payeeTrustJson(
          vpa: 'secure-kyc-update@okaxis',
          grade: grade,
          score: grade == 'D' ? 18 : 91,
          thinFile: false,
          impersonation: impersonation,
        ),
      );

  group('handing the address to the government register', () {
    testWidgets('an adverse payee gets the offer', (WidgetTester tester) async {
      await pumpResult(
        tester,
        assessment: _assessment(),
        trust: trustOf(grade: 'D'),
      );

      expect(find.byKey(const Key('suspect_registry_card')), findsOneWidget);
    });

    testWidgets('a safe result with a good payee does not', (
      WidgetTester tester,
    ) async {
      await pumpResult(
        tester,
        assessment: _assessment(
          level: RiskLevel.safe,
          signals: const <RiskSignal>[],
        ),
        trust: trustOf(grade: 'A_PLUS'),
      );

      // Prompting for a national fraud-register check on an ordinary payment
      // would teach people to tap past the prompt everywhere it matters.
      expect(find.byKey(const Key('suspect_registry_card')), findsNothing);
    });

    testWidgets('a mule-shaped ledger earns the offer on its own', (
      WidgetTester tester,
    ) async {
      await pumpResult(
        tester,
        assessment: _assessment(
          level: RiskLevel.caution,
          signals: const <RiskSignal>[_muleSignal],
        ),
        trust: trustOf(grade: 'B'),
      );

      expect(find.byKey(const Key('suspect_registry_card')), findsOneWidget);
    });

    testWidgets('tapping copies the address and opens the official search', (
      WidgetTester tester,
    ) async {
      await pumpResult(
        tester,
        assessment: _assessment(),
        trust: trustOf(grade: 'D'),
      );

      await tester.ensureVisible(
        find.byKey(const Key('open_suspect_registry_button')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('open_suspect_registry_button')));
      await tester.pumpAndSettle();

      // The address must reach the clipboard even if the browser never opens,
      // so the user can always run the search by hand.
      expect(actions.copiedText, 'secure-kyc-update@okaxis');
      expect(actions.suspectRegistryOpenCount, 1);
    });
  });

  group('the payee-name card cites the rule it relies on', () {
    testWidgets('the mandate is named when the name is unverifiable', (
      WidgetTester tester,
    ) async {
      await pumpResult(
        tester,
        assessment: _assessment(
          level: RiskLevel.caution,
          signals: const <RiskSignal>[_nameSignal],
        ),
        trust: trustOf(grade: 'B'),
      );

      expect(
        find.byKey(const Key('payee_name_unverified_card')),
        findsOneWidget,
      );
      // The instruction is only actionable because every UPI app is required
      // to show the bank-verified name, so the card says so.
      expect(
        find.byKey(const Key('payee_name_mandate_citation')),
        findsOneWidget,
      );
    });

    testWidgets('no signal means no claim about the name', (
      WidgetTester tester,
    ) async {
      await pumpResult(
        tester,
        assessment: _assessment(
          level: RiskLevel.caution,
          signals: const <RiskSignal>[_muleSignal],
        ),
        trust: trustOf(grade: 'B'),
      );

      expect(find.byKey(const Key('payee_name_unverified_card')), findsNothing);
    });
  });
}
