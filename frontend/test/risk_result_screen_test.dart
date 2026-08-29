import 'package:finguard/models/payment.dart';
import 'package:finguard/models/risk.dart';
import 'package:finguard/models/risk_explanation.dart';
import 'package:finguard/models/trusted_contact.dart';
import 'package:finguard/screens/risk_result_screen.dart';
import 'package:finguard/services/app_services.dart';
import 'package:finguard/services/demo_repository.dart';
import 'package:finguard/services/local_store.dart';
import 'package:finguard/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  testWidgets(
    'AI wording stays ancillary and cannot replace the deterministic summary',
    (WidgetTester tester) async {
      final FakeApi api = FakeApi(
        explanationResult: const RiskExplanation(
          available: true,
          source: RiskExplanationSource.gemini,
          status: 'generated',
          explanation:
              'FinGuard rated this CAUTION because the request has warning signs.',
        ),
      );
      final AppServices services = AppServices(
        api: api,
        store: MemoryLocalStore(),
        externalActions: FakeExternalActions(),
        demos: const DemoRepository(),
      );
      const RiskAssessment assessment = RiskAssessment(
        assessmentId: 'assessment-ai-wording',
        score: 33,
        level: RiskLevel.caution,
        signals: <RiskSignal>[
          RiskSignal(
            code: 'FIRST_TIME_PAYEE',
            label: 'First-time recipient',
            weight: 18,
            evidence: 'No completed payment exists in local history',
          ),
          RiskSignal(
            code: 'UNUSUAL_AMOUNT',
            label: 'Unusual amount',
            weight: 15,
            evidence: 'The amount exceeds the new-recipient threshold',
          ),
        ],
        recommendedAction: 'Pause and verify independently.',
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: RiskResultScreen(
            services: services,
            payment: const Payment(
              upiUri: 'upi://pay?pa=market.seller%40okaxis&am=4500&cu=INR',
              payeeVpa: 'market.seller@okaxis',
              amount: 4500,
              currency: 'INR',
            ),
            assessment: assessment,
            paymentHandoffEnabled: true,
            consentToExternalAi: true,
          ),
        ),
      );
      await tester.pump();

      final Text deterministicSummary = tester.widget<Text>(
        find.byKey(const Key('plain_language_summary_text')),
      );
      expect(
        deterministicSummary.data,
        contains('you have never paid this recipient from this device'),
      );
      expect(
        deterministicSummary.data,
        isNot(
          'FinGuard rated this CAUTION because the request has warning signs.',
        ),
      );
      expect(find.byKey(const Key('ai_assisted_wording_chip')), findsOneWidget);
      expect(
        find.text(
          'FinGuard rated this CAUTION because the request has warning signs.',
        ),
        findsOneWidget,
      );
      expect(api.explainAssessmentCount, 1);
      expect(api.lastExplanationConsent, isTrue);
    },
  );

  testWidgets('safe result explains the empty signal set before handoff', (
    WidgetTester tester,
  ) async {
    final FakeExternalActions actions = FakeExternalActions();
    final AppServices services = AppServices(
      api: FakeApi(),
      store: MemoryLocalStore(),
      externalActions: actions,
      demos: const DemoRepository(),
    );
    const Payment payment = Payment(
      upiUri:
          'upi://pay?pa=coffee.corner%40okaxis&pn=Coffee%20Corner&am=180&cu=INR',
      payeeVpa: 'coffee.corner@okaxis',
      payeeName: 'Coffee Corner',
      amount: 180,
      currency: 'INR',
    );
    const RiskAssessment assessment = RiskAssessment(
      score: 0,
      level: RiskLevel.safe,
      signals: <RiskSignal>[],
      recommendedAction: 'Review the details before continuing.',
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: RiskResultScreen(
          services: services,
          payment: payment,
          assessment: assessment,
          paymentHandoffEnabled: true,
        ),
      ),
    );

    expect(find.text('SAFE'), findsOneWidget);
    expect(find.byKey(const Key('risk_score')), findsOneWidget);
    expect(find.text('0'), findsOneWidget);
    expect(find.text('No strong warning signal found'), findsOneWidget);
    expect(find.text('Plain-language summary'), findsOneWidget);
    expect(
      find.textContaining('A quiet result is not a guarantee'),
      findsOneWidget,
    );
    expect(
      find.text(
        'The deterministic policy found no risk-raising signals in this request.',
      ),
      findsOneWidget,
    );

    await tester.scrollUntilVisible(
      find.byKey(const Key('continue_upi_button')),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('continue_upi_button')));
    await tester.pumpAndSettle();

    expect(find.text('Open this request in a UPI app?'), findsOneWidget);
    expect(actions.upiOpenCount, 0);
    await tester.tap(find.text('Open UPI app'));
    await tester.pumpAndSettle();
    expect(actions.upiOpenCount, 1);
  });

  testWidgets('caution result keeps warning evidence and requires confirmation', (
    WidgetTester tester,
  ) async {
    final FakeExternalActions actions = FakeExternalActions();
    final AppServices services = AppServices(
      api: FakeApi(),
      store: MemoryLocalStore(),
      externalActions: actions,
      demos: const DemoRepository(),
    );
    const Payment payment = Payment(
      upiUri:
          'upi://pay?pa=market.seller%40okaxis&pn=Marketplace%20Seller&am=4500&cu=INR',
      payeeVpa: 'market.seller@okaxis',
      payeeName: 'Marketplace Seller',
      amount: 4500,
      currency: 'INR',
    );
    const RiskAssessment assessment = RiskAssessment(
      score: 33,
      level: RiskLevel.caution,
      signals: <RiskSignal>[
        RiskSignal(
          code: 'FIRST_TIME_PAYEE',
          label: 'First-time recipient',
          weight: 18,
          evidence: 'No completed payment exists in local history',
        ),
        RiskSignal(
          code: 'UNUSUAL_AMOUNT',
          label: 'Unusual amount',
          weight: 15,
          evidence: 'The amount exceeds the new-recipient threshold',
        ),
      ],
      recommendedAction: 'Pause and verify independently.',
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: RiskResultScreen(
          services: services,
          payment: payment,
          assessment: assessment,
          paymentHandoffEnabled: true,
        ),
      ),
    );

    expect(find.text('CAUTION'), findsOneWidget);
    expect(find.text('33'), findsOneWidget);
    expect(find.text('First-time recipient'), findsOneWidget);
    expect(
      find.text('No completed payment exists in local history'),
      findsOneWidget,
    );
    expect(find.text('+18'), findsOneWidget);
    expect(find.text('+15'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.byKey(const Key('continue_anyway_button')),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(const Key('stop_here_button')), findsOneWidget);
    expect(find.text('Check recipient'), findsOneWidget);
    expect(
      find.byKey(const Key('independent_verification_checklist')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('continue_anyway_button')))
          .onPressed,
      isNull,
    );

    await _completeIndependentVerification(tester);

    expect(find.text('Verification complete'), findsOneWidget);
    expect(find.byKey(const Key('cool_off_notice')), findsNothing);
    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('continue_anyway_button')))
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.byKey(const Key('continue_anyway_button')));
    await tester.pumpAndSettle();

    expect(find.text('Continue with caution?'), findsOneWidget);
    expect(actions.upiOpenCount, 0);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(actions.upiOpenCount, 0);
  });

  testWidgets('saved trusted contact requires confirmation before messaging', (
    WidgetTester tester,
  ) async {
    final MemoryLocalStore store = MemoryLocalStore();
    await store.setTrustedContact(
      const TrustedContact(name: 'Amma', phone: '919876543210'),
    );
    final FakeExternalActions actions = FakeExternalActions();
    final AppServices services = AppServices(
      api: FakeApi(),
      store: store,
      externalActions: actions,
      demos: const DemoRepository(),
    );
    const Payment payment = Payment(
      upiUri: 'upi://pay?pa=scam@upi&pn=Fake%20Support&am=25000&cu=INR',
      payeeVpa: 'scam@upi',
      payeeName: 'Fake Support',
      amount: 25000,
      currency: 'INR',
    );
    const RiskAssessment assessment = RiskAssessment(
      score: 80,
      level: RiskLevel.highRisk,
      signals: <RiskSignal>[
        RiskSignal(
          code: 'SEEDED_FRAUD_MATCH',
          label: 'Recipient matches seeded scam indicator',
          weight: 80,
          evidence: 'Fixture evidence',
        ),
      ],
      recommendedAction: 'Stop and verify independently.',
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: RiskResultScreen(
          services: services,
          payment: payment,
          assessment: assessment,
          paymentHandoffEnabled: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final Finder messageButton = find.byKey(
      const Key('message_trusted_contact_button'),
    );
    await tester.scrollUntilVisible(
      messageButton,
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Alert Amma on WhatsApp'), findsOneWidget);

    await tester.tap(messageButton);
    await tester.pumpAndSettle();
    expect(find.text('Message Amma on WhatsApp or SMS?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(actions.messageTrustedContactCount, 0);

    await tester.tap(messageButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open messaging app'));
    await tester.pumpAndSettle();
    expect(actions.messageTrustedContactCount, 1);
    expect(actions.messagedPhone, '919876543210');
    expect(actions.messagedText, contains('scam@upi'));
  });

  testWidgets('high-risk result explains evidence and confirms handoff', (
    WidgetTester tester,
  ) async {
    final FakeApi api = FakeApi();
    final FakeExternalActions actions = FakeExternalActions();
    final AppServices services = AppServices(
      api: api,
      store: MemoryLocalStore(),
      externalActions: actions,
      demos: const DemoRepository(),
    );
    const Payment payment = Payment(
      upiUri: 'upi://pay?pa=scam@upi&pn=Fake%20Support&am=25000&cu=INR',
      payeeVpa: 'scam@upi',
      payeeName: 'Fake Support',
      amount: 25000,
      currency: 'INR',
    );
    const RiskAssessment assessment = RiskAssessment(
      score: 83,
      level: RiskLevel.highRisk,
      signals: <RiskSignal>[
        RiskSignal(
          code: 'SEEDED_FRAUD_MATCH',
          label: 'Recipient matches seeded scam indicator',
          weight: 30,
          evidence: 'VPA matched demo fraud indicator dataset',
        ),
      ],
      recommendedAction: 'Stop and verify independently.',
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: RiskResultScreen(
          services: services,
          payment: payment,
          assessment: assessment,
          paymentHandoffEnabled: true,
        ),
      ),
    );

    expect(find.text('HIGH RISK'), findsOneWidget);
    expect(find.text('83'), findsOneWidget);
    expect(find.text('Fake Support'), findsOneWidget);
    expect(
      find.text('Recipient matches seeded scam indicator'),
      findsOneWidget,
    );
    expect(find.text('+30'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.byKey(const Key('continue_anyway_button')),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Alert trusted contact'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('continue_anyway_button')))
          .onPressed,
      isNull,
    );
    expect(actions.upiOpenCount, 0);

    await _completeIndependentVerification(tester);

    expect(find.byKey(const Key('cool_off_notice')), findsOneWidget);
    expect(find.text('Continue anyway (10s)'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('continue_anyway_button')))
          .onPressed,
      isNull,
    );

    await tester.scrollUntilVisible(
      find.byKey(const Key('verify_recipient_checkbox')),
      -180,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('verify_recipient_checkbox')));
    await tester.pump(const Duration(seconds: 10));
    await tester.tap(find.byKey(const Key('verify_recipient_checkbox')));
    await tester.pump();
    expect(find.text('Continue anyway (10s)'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('continue_anyway_button')))
          .onPressed,
      isNull,
    );

    await tester.pump(const Duration(seconds: 10));

    expect(find.byKey(const Key('cool_off_notice')), findsNothing);
    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('continue_anyway_button')))
          .onPressed,
      isNotNull,
    );

    await tester.tap(find.byKey(const Key('continue_anyway_button')));
    await tester.pumpAndSettle();

    expect(find.text('Continue despite high risk?'), findsOneWidget);
    expect(actions.upiOpenCount, 0);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(actions.upiOpenCount, 0);
  });

  testWidgets('demo result is view-only and cannot open a UPI app', (
    WidgetTester tester,
  ) async {
    final FakeApi api = FakeApi();
    final FakeExternalActions actions = FakeExternalActions();
    final AppServices services = AppServices(
      api: api,
      store: MemoryLocalStore(),
      externalActions: actions,
      demos: const DemoRepository(),
    );
    const Payment payment = Payment(
      upiUri: 'upi://pay?pa=demo%40upi&pn=Demo&am=50&cu=INR',
      payeeVpa: 'demo@upi',
      payeeName: 'Demo',
      amount: 50,
      currency: 'INR',
    );
    const RiskAssessment assessment = RiskAssessment(
      score: 80,
      level: RiskLevel.highRisk,
      signals: <RiskSignal>[],
      recommendedAction: 'Demo guidance only.',
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: RiskResultScreen(
          services: services,
          payment: payment,
          assessment: assessment,
          paymentHandoffEnabled: false,
          isDemo: true,
        ),
      ),
    );

    await tester.scrollUntilVisible(
      find.byKey(const Key('payment_handoff_unavailable')),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('SEEDED DEMO DATA'), findsOneWidget);
    expect(find.text('Plain-language summary'), findsOneWidget);
    expect(
      find.byKey(const Key('payment_handoff_unavailable')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('continue_upi_button')), findsNothing);
    expect(find.byKey(const Key('continue_anyway_button')), findsNothing);
    expect(
      find.byKey(const Key('independent_verification_checklist')),
      findsNothing,
    );
    expect(find.text('Check recipient'), findsOneWidget);
    expect(find.text('Prepare report'), findsNothing);
    expect(find.text('Alert trusted contact'), findsNothing);
    expect(find.byKey(const Key('already_paid_button')), findsNothing);
    expect(actions.upiOpenCount, 0);
    expect(api.prepareResponseCount, 0);
    expect(api.explainAssessmentCount, 0);
    expect(actions.shareCount, 0);
  });
}

Future<void> _completeIndependentVerification(WidgetTester tester) async {
  for (final Key key in <Key>[
    const Key('verify_recipient_checkbox'),
    const Key('verify_amount_checkbox'),
    const Key('verify_independent_contact_checkbox'),
  ]) {
    await tester.scrollUntilVisible(
      find.byKey(key),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(key));
    await tester.pump();
  }
  await tester.scrollUntilVisible(
    find.byKey(const Key('continue_anyway_button')),
    180,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}
