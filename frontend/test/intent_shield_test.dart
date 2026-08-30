import 'package:finguard/models/intent_shield.dart';
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
  upiUri: 'upi://pay?pa=refund.desk%40oksbi&am=1&cu=INR',
  payeeVpa: 'refund.desk@oksbi',
  payeeName: 'Refund Desk',
  amount: 1,
  currency: 'INR',
);

const RiskAssessment _safe = RiskAssessment(
  assessmentId: 'intent-1',
  score: 12,
  level: RiskLevel.safe,
  signals: <RiskSignal>[],
  recommendedAction: 'Verify the recipient before continuing.',
);

void main() {
  Future<void> pump(WidgetTester tester, IntentShield? shield) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: RiskResultScreen(
          services: AppServices(
            api: FakeApi(),
            store: MemoryLocalStore(),
            externalActions: FakeExternalActions(),
            demos: const DemoRepository(),
          ),
          payment: _payment,
          assessment: _safe,
          paymentHandoffEnabled: true,
          intentShield: shield,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  IntentShield shield({required bool mismatched, String intent = 'REFUND_OR_REWARD'}) =>
      IntentShield.fromApiJson(<String, Object?>{
        'intent': intent,
        'mismatched': mismatched,
        'headline': mismatched ? 'STOP - this request sends money.' : null,
        'detail': mismatched ? 'A genuine refund arrives on its own.' : null,
        'rule': mismatched
            ? 'Scanning a QR is never required to receive money.'
            : null,
      })!;

  group('intent shield on the result screen', () {
    testWidgets('a mismatch is shown above the verdict', (
      WidgetTester tester,
    ) async {
      await pump(tester, shield(mismatched: true));

      expect(find.byKey(const Key('intent_mismatch_card')), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('intent_mismatch_headline')))
            .data,
        contains('STOP'),
      );
      // It must say plainly that it did not move the score.
      expect(
        find.textContaining('does not change the risk score'),
        findsOneWidget,
      );
    });

    testWidgets('a matching expectation shows nothing', (
      WidgetTester tester,
    ) async {
      await pump(tester, shield(mismatched: false, intent: 'SEND_MONEY'));
      expect(find.byKey(const Key('intent_mismatch_card')), findsNothing);
    });

    testWidgets('no stated intent shows nothing', (WidgetTester tester) async {
      await pump(tester, null);
      expect(find.byKey(const Key('intent_mismatch_card')), findsNothing);
    });
  });

  group('reading the payload', () {
    test('an absent payload is null rather than an error', () {
      expect(IntentShield.fromApiJson(null), isNull);
    });

    test('a malformed payload is rejected', () {
      expect(
        () => IntentShield.fromApiJson(<String, Object?>{'mismatched': true}),
        throwsA(isA<FormatException>()),
      );
    });

    test('every intent option carries a readable label', () {
      for (final PaymentIntent intent in PaymentIntent.values) {
        expect(intent.label.trim(), isNotEmpty);
        expect(intent.apiValue, matches(RegExp(r'^[A-Z_]+$')));
      }
    });
  });
}
