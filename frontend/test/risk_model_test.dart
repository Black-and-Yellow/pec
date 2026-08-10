import 'package:finguard/models/risk.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('valid risk response keeps explainable signals', () {
    final RiskAssessment result = RiskAssessment.fromJson(<String, Object?>{
      'score': 100,
      'level': 'HIGH_RISK',
      'assessment_id': 'assessment-1',
      'transaction_id': 'transaction-1',
      'recommended_action': 'Stop and verify.',
      'signals': <Object?>[
        <String, Object?>{
          'code': 'SEEDED_FRAUD_MATCH',
          'label': 'Recipient matches seeded scam indicator',
          'weight': 30,
          'evidence': 'Matched demo fixture',
        },
      ],
    });

    expect(result.score, 100);
    expect(result.level, RiskLevel.highRisk);
    expect(result.signals.single.weight, 30);
    expect(result.signals.single.evidence, 'Matched demo fixture');
    expect(result.assessmentId, 'assessment-1');
    expect(result.transactionId, 'transaction-1');
    expect(result.toApiJson()['level'], 'HIGH');
    expect(result.toApiJson()['assessment_id'], 'assessment-1');
  });

  test('thresholds map 0-29, 30-69 and 70-100', () {
    expect(RiskThresholds.levelForScore(29), RiskLevel.safe);
    expect(RiskThresholds.levelForScore(30), RiskLevel.caution);
    expect(RiskThresholds.levelForScore(69), RiskLevel.caution);
    expect(RiskThresholds.levelForScore(70), RiskLevel.highRisk);
  });

  test('rejects missing, malformed and inconsistent risk verdicts', () {
    for (final Map<String, Object?> response in <Map<String, Object?>>[
      <String, Object?>{'level': 'SAFE'},
      <String, Object?>{'score': 10},
      <String, Object?>{'score': 'unknown', 'level': 'SAFE'},
      <String, Object?>{'score': 101, 'level': 'HIGH'},
      <String, Object?>{'score': 90, 'level': 'SAFE'},
      <String, Object?>{'score': 10, 'level': 'UNKNOWN'},
    ]) {
      expect(
        () => RiskAssessment.fromJson(response),
        throwsFormatException,
        reason: 'response must fail closed: $response',
      );
    }
  });
}
