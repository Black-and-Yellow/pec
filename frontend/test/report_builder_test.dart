import 'package:finguard/models/payment.dart';
import 'package:finguard/models/risk.dart';
import 'package:finguard/services/report_builder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const Payment payment = Payment(
    upiUri: 'upi://pay?pa=merchant%40upi&pn=Merchant&am=125&cu=INR',
    payeeVpa: 'merchant@upi',
    payeeName: 'Merchant',
    amount: 125,
    currency: 'INR',
  );
  const RiskAssessment assessment = RiskAssessment(
    score: 72,
    level: RiskLevel.highRisk,
    signals: <RiskSignal>[
      RiskSignal(
        code: 'TEST_SIGNAL',
        label: 'Warning signal',
        weight: 12,
        evidence: 'Test evidence',
      ),
    ],
    recommendedAction: 'Verify independently.',
  );

  test('not-already-paid draft uses neutral, evidence-bounded status copy', () {
    final String report = ReportBuilder.build(
      payment: payment,
      assessment: assessment,
      occurredAt: DateTime.utc(2026, 8, 12),
      alreadyPaid: false,
    );

    expect(report, contains('FinGuard displayed a pre-payment warning.'));
    expect(
      report,
      contains('FinGuard cannot verify whether a payment occurred.'),
    );
    _expectNoProhibitedOutcomeClaims(report);
  });

  test('already-paid draft records only the user indication', () {
    final String report = ReportBuilder.build(
      payment: payment,
      assessment: assessment,
      occurredAt: DateTime.utc(2026, 8, 12),
      alreadyPaid: true,
    );

    expect(
      report,
      contains('The user indicated that a payment may have occurred.'),
    );
    expect(report, contains('FinGuard cannot verify payment status.'));
    _expectNoProhibitedOutcomeClaims(report);
  });

  test('trusted-contact fallback does not assert a payment outcome', () {
    final String message = ReportBuilder.trustedContactMessage(
      payment,
      assessment,
    );

    expect(message, contains('FinGuard displayed a pre-payment warning'));
    expect(
      message,
      contains('FinGuard cannot verify whether any payment occurred.'),
    );
    _expectNoProhibitedOutcomeClaims(message);
  });
}

void _expectNoProhibitedOutcomeClaims(String value) {
  for (final String prohibited in <String>[
    'Payment stopped',
    'payment was stopped',
    'Payment completed',
    'payment was completed',
    'Payment reversed',
    'payment was reversed',
    'Payment reported',
    'payment was reported',
    'I stopped',
    'I paused',
  ]) {
    expect(value, isNot(contains(prohibited)), reason: prohibited);
  }
}
