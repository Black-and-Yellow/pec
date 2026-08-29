import 'package:finguard/models/payee_trust.dart';
import 'package:finguard/models/payment.dart';
import 'package:finguard/models/risk.dart';
import 'package:finguard/screens/risk_result_screen.dart';
import 'package:finguard/screens/trust_screen.dart';
import 'package:finguard/services/app_services.dart';
import 'package:finguard/services/demo_repository.dart';
import 'package:finguard/services/local_store.dart';
import 'package:finguard/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

const Payment _payment = Payment(
  upiUri: 'upi://pay?pa=merchant%40upi&pn=Merchant&am=25000&cu=INR',
  payeeVpa: 'merchant@upi',
  payeeName: 'Merchant',
  amount: 25000,
  currency: 'INR',
);

/// A HIGH verdict, which is the only level that triggers the cool-off pause.
RiskAssessment _highRisk({List<RiskSignal>? signals}) => RiskAssessment(
  assessmentId: 'assessment-cool-off',
  score: 70,
  level: RiskLevel.highRisk,
  signals:
      signals ??
      const <RiskSignal>[
        RiskSignal(
          code: 'SEEDED_FRAUD_MATCH',
          label: 'Recipient matches a seeded scam indicator',
          weight: 70,
          evidence: 'Seeded demo indicator match',
        ),
      ],
  recommendedAction: 'Stop and verify independently.',
);

void main() {
  AppServices buildServices() => AppServices(
    api: FakeApi(),
    store: MemoryLocalStore(),
    externalActions: FakeExternalActions(),
    demos: const DemoRepository(),
  );

  Future<void> pumpResult(
    WidgetTester tester, {
    required RiskAssessment assessment,
    PayeeTrust? trust,
    Payment payment = _payment,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: RiskResultScreen(
          services: buildServices(),
          payment: payment,
          assessment: assessment,
          payeeTrust: trust,
          paymentHandoffEnabled: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Ticks every independent-verification box, which is what starts the pause.
  Future<void> completeVerification(WidgetTester tester) async {
    for (final String key in const <String>[
      'verify_recipient_checkbox',
      'verify_amount_checkbox',
      'verify_independent_contact_checkbox',
    ]) {
      await tester.tap(find.byKey(Key(key)));
      await tester.pump();
    }
  }

  group('cool-off scales with what the network knows about the payee', () {
    testWidgets('a well-established payee still cannot skip the pause', (
      WidgetTester tester,
    ) async {
      await pumpResult(
        tester,
        assessment: _highRisk(),
        trust: PayeeTrust.fromApiJson(
          payeeTrustJson(
            vpa: 'merchant@upi',
            grade: 'A_PLUS',
            score: 96,
            thinFile: false,
          ),
        ),
      );
      await completeVerification(tester);

      // The best possible grade earns the shortest pause, never none. A HIGH
      // verdict was reached on evidence the payee's record does not override:
      // a trusted merchant's QR can be swapped, and a payer can be talked into
      // paying an ordinary-looking account.
      expect(find.text('Continue anyway (5s)'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.byKey(const Key('continue_anyway_button')))
            .onPressed,
        isNull,
      );

      await tester.pump(const Duration(seconds: 5));
      expect(find.text('Continue anyway'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.byKey(const Key('continue_anyway_button')))
            .onPressed,
        isNotNull,
      );
    });

    testWidgets('no grade can drive the pause below the floor', (
      WidgetTester tester,
    ) async {
      for (final String grade in const <String>['A_PLUS', 'A', 'B', 'C', 'D']) {
        // Unmount first: the same widget type at the same tree position keeps
        // its State, so initState would not re-run and the pause would carry
        // over from the previous grade.
        await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
        await pumpResult(
          tester,
          assessment: _highRisk(),
          trust: PayeeTrust.fromApiJson(
            payeeTrustJson(
              vpa: 'merchant@upi',
              grade: grade,
              score: 50,
              thinFile: false,
            ),
          ),
        );
        await completeVerification(tester);

        expect(
          find.text('Continue anyway'),
          findsNothing,
          reason: 'grade $grade must still impose some pause',
        );
        expect(
          tester
              .widget<TextButton>(
                find.byKey(const Key('continue_anyway_button')),
              )
              .onPressed,
          isNull,
          reason: 'grade $grade must gate the button before the pause elapses',
        );

        // Let the timer finish so it does not outlive this iteration.
        await tester.pump(const Duration(seconds: 20));
      }
    });

    testWidgets('the bottom trust band imposes the longest pause', (
      WidgetTester tester,
    ) async {
      await pumpResult(
        tester,
        assessment: _highRisk(),
        trust: PayeeTrust.fromApiJson(
          payeeTrustJson(
            vpa: 'merchant@upi',
            grade: 'D',
            score: 18,
            thinFile: false,
          ),
        ),
      );
      await completeVerification(tester);

      expect(find.text('Continue anyway (20s)'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.byKey(const Key('continue_anyway_button')))
            .onPressed,
        isNull,
        reason: 'the pause must actually gate the button, not just label it',
      );

      await tester.pump(const Duration(seconds: 20));
      expect(find.text('Continue anyway'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.byKey(const Key('continue_anyway_button')))
            .onPressed,
        isNotNull,
      );
    });

    testWidgets('a result with no trust report keeps the original pause', (
      WidgetTester tester,
    ) async {
      await pumpResult(tester, assessment: _highRisk());
      await completeVerification(tester);

      expect(find.text('Continue anyway (10s)'), findsOneWidget);
    });

    testWidgets('unticking a box restarts the pause from the top', (
      WidgetTester tester,
    ) async {
      await pumpResult(
        tester,
        assessment: _highRisk(),
        trust: PayeeTrust.fromApiJson(
          payeeTrustJson(vpa: 'merchant@upi', grade: 'C', score: 40,
              thinFile: false),
        ),
      );
      await completeVerification(tester);
      expect(find.text('Continue anyway (15s)'), findsOneWidget);

      await tester.pump(const Duration(seconds: 5));
      expect(find.text('Continue anyway (10s)'), findsOneWidget);

      await tester.tap(find.byKey(const Key('verify_amount_checkbox')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('verify_amount_checkbox')));
      await tester.pump();

      expect(find.text('Continue anyway (15s)'), findsOneWidget);
    });
  });

  group('unverifiable payee name', () {
    RiskAssessment withNameSignal() => _highRisk(
      signals: const <RiskSignal>[
        RiskSignal(
          code: 'SEEDED_FRAUD_MATCH',
          label: 'Recipient matches a seeded scam indicator',
          weight: 70,
          evidence: 'Seeded demo indicator match',
        ),
        RiskSignal(
          code: 'PAYEE_NAME_UNVERIFIED',
          label: 'The name on this request cannot be verified',
          weight: 0,
          evidence: 'The name is set by whoever created the request',
        ),
      ],
    );

    testWidgets('names the claim and points at the screen that can settle it', (
      WidgetTester tester,
    ) async {
      await pumpResult(
        tester,
        assessment: withNameSignal(),
        payment: const Payment(
          upiUri: 'upi://pay?pa=refund%40okaxis&pn=SBI%20Refund%20Cell&cu=INR',
          payeeVpa: 'refund@okaxis',
          payeeName: 'SBI Refund Cell',
          currency: 'INR',
        ),
      );

      expect(find.byKey(const Key('payee_name_unverified_card')), findsOneWidget);
      expect(find.textContaining('SBI Refund Cell'), findsWidgets);
      expect(find.textContaining('cannot check it'), findsOneWidget);
      expect(find.textContaining('real registered name'), findsOneWidget);
    });

    testWidgets('stays silent when the server did not raise the signal', (
      WidgetTester tester,
    ) async {
      await pumpResult(tester, assessment: _highRisk());

      expect(find.byKey(const Key('payee_name_unverified_card')), findsNothing);
    });

    testWidgets('stays silent when the request carries no name to doubt', (
      WidgetTester tester,
    ) async {
      await pumpResult(
        tester,
        assessment: withNameSignal(),
        payment: const Payment(
          upiUri: 'upi://pay?pa=merchant%40upi&cu=INR',
          payeeVpa: 'merchant@upi',
          currency: 'INR',
        ),
      );

      expect(find.byKey(const Key('payee_name_unverified_card')), findsNothing);
    });
  });

  group('live network view', () {
    testWidgets('an idle screen never polls', (WidgetTester tester) async {
      final FakeApi api = FakeApi();
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: TrustScreen(
            services: AppServices(
              api: api,
              store: MemoryLocalStore(),
              externalActions: FakeExternalActions(),
              demos: const DemoRepository(),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 30));

      expect(api.trustLookupCount, 0);
    });

    testWidgets('counters refresh on their own once a report is on screen', (
      WidgetTester tester,
    ) async {
      final FakeApi api = FakeApi();
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: TrustScreen(
            services: AppServices(
              api: api,
              store: MemoryLocalStore(),
              externalActions: FakeExternalActions(),
              demos: const DemoRepository(),
            ),
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const Key('trust_vpa_field')),
        'coffee.corner@okaxis',
      );
      await tester.tap(find.byKey(const Key('lookup_trust_button')));
      // Deliberately not pumpAndSettle: the poller schedules frames forever,
      // so settling would spin until the test timed out.
      await tester.pump();
      await tester.pump();

      expect(api.trustLookupCount, 1);
      expect(find.byKey(const Key('trust_refreshed_at')), findsOneWidget);

      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(api.trustLookupCount, 2);

      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(api.trustLookupCount, 3);

      // The timer must not outlive the screen.
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await tester.pump(const Duration(seconds: 15));
      expect(api.trustLookupCount, 3);
    });
  });
}
