import 'package:finguard/models/payment.dart';
import 'package:finguard/models/risk.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

const Object _omitted = Object();

void main() {
  List<Object?> signalsForScore(Object? score) {
    if (score is! int || score == 0) {
      return <Object?>[];
    }
    return <Object?>[
      <String, Object?>{
        'code': 'TEST_SIGNAL',
        'label': 'Test risk signal',
        'weight': score,
        'evidence': 'Deterministic test fixture',
      },
    ];
  }

  Map<String, Object?> validResponse({
    Object? score = 70,
    Object? level = 'HIGH',
    Object? signals = _omitted,
    Object? recommendedAction = 'Stop and verify.',
    Object? assessmentId = 'assessment-1',
    Object? transactionId = 'transaction-1',
  }) => <String, Object?>{
    'score': score,
    'level': level,
    'assessment_id': assessmentId,
    'transaction_id': transactionId,
    'recommended_action': recommendedAction,
    'signals': identical(signals, _omitted) ? signalsForScore(score) : signals,
  };

  const Payment requestedPayment = Payment(
    upiUri:
        'upi://pay?pa=merchant%40upi&pn=Merchant&am=100.50&tn=Invoice&cu=INR&tr=ORDER-1',
    payeeVpa: 'merchant@upi',
    payeeName: 'Merchant',
    amount: 100.5,
    note: 'Invoice',
    currency: 'INR',
    transactionReference: 'ORDER-1',
  );

  Map<String, Object?> validEnvelope({
    String level = 'HIGH',
    int score = 70,
    Object? payment = _omitted,
    Object? signals = _omitted,
    Object? requiresConfirmation = true,
    Object? handoffPolicy = 'PAUSED',
    Object? assessedAt = '2026-08-12T10:00:00.123456Z',
    Object? payeeTrust = _omitted,
  }) => <String, Object?>{
    ...validResponse(score: score, level: level, signals: signals),
    'payment': identical(payment, _omitted)
        ? requestedPayment.toApiJson()
        : payment,
    'payee_trust': identical(payeeTrust, _omitted)
        ? payeeTrustJson(vpa: requestedPayment.payeeVpa)
        : payeeTrust,
    'requires_confirmation': requiresConfirmation,
    'handoff_policy': handoffPolicy,
    'assessed_at': assessedAt,
  };

  test('a trust report for a different recipient is rejected', () {
    expect(
      () => RiskScoreResult.fromApiJson(
        validEnvelope(payeeTrust: payeeTrustJson(vpa: 'someone.else@upi')),
        requestedPayment: requestedPayment,
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('a response without a trust report is rejected', () {
    final Map<String, Object?> envelope = validEnvelope()
      ..remove('payee_trust');
    expect(
      () => RiskScoreResult.fromApiJson(
        envelope,
        requestedPayment: requestedPayment,
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('a valid envelope carries the payee trust report through', () {
    final RiskScoreResult result = RiskScoreResult.fromApiJson(
      validEnvelope(),
      requestedPayment: requestedPayment,
    );

    expect(result.payeeTrust.vpa, 'merchant@upi');
    expect(result.payeeTrust.thinFile, isTrue);
    expect(result.payeeTrust.score, isNull);
  });

  test('valid live risk response keeps explainable server verdict', () {
    final RiskAssessment result = RiskAssessment.fromApiJson(validResponse());

    expect(result.score, 70);
    expect(result.level, RiskLevel.highRisk);
    expect(result.signals.single.weight, 70);
    expect(result.signals.single.evidence, 'Deterministic test fixture');
    expect(result.assessmentId, 'assessment-1');
    expect(result.transactionId, 'transaction-1');
    expect(result.toApiJson()['level'], 'HIGH');
    expect(result.toApiJson()['assessment_id'], 'assessment-1');
  });

  test('accepts only exact server risk level values', () {
    expect(
      RiskAssessment.fromJson(validResponse(score: 0, level: 'SAFE')).level,
      RiskLevel.safe,
    );
    expect(
      RiskAssessment.fromJson(validResponse(score: 30, level: 'CAUTION')).level,
      RiskLevel.caution,
    );
    expect(RiskAssessment.fromJson(validResponse()).level, RiskLevel.highRisk);

    for (final String alias in <String>[
      'LOW',
      'MEDIUM',
      'HIGH_RISK',
      'HIGH RISK',
      'high',
    ]) {
      expect(
        () => RiskAssessment.fromJson(validResponse(level: alias)),
        throwsFormatException,
        reason: '$alias is not an exact live API verdict value',
      );
    }
  });

  test('rejects missing, coerced and out-of-range scores', () {
    for (final Object? score in <Object?>[null, '70', 70.0, -1, 101]) {
      expect(
        () => RiskAssessment.fromJson(validResponse(score: score)),
        throwsFormatException,
        reason: 'score must be a bounded JSON integer: $score',
      );
    }
  });

  test('rejects a score that does not equal capped signal weights', () {
    expect(
      () => RiskAssessment.fromJson(
        validResponse(score: 70, signals: signalsForScore(69)),
      ),
      throwsFormatException,
    );

    final List<Object?> overCapSignals = <Object?>[
      ...signalsForScore(70),
      ...signalsForScore(40),
    ];
    expect(
      RiskAssessment.fromJson(
        validResponse(score: 100, signals: overCapSignals),
      ).score,
      100,
    );
  });

  test('rejects a risk level outside the score wire-contract range', () {
    for (final Map<String, Object?> response in <Map<String, Object?>>[
      validResponse(score: 29, level: 'CAUTION'),
      validResponse(score: 30, level: 'SAFE'),
      validResponse(score: 69, level: 'HIGH'),
      validResponse(score: 70, level: 'CAUTION'),
    ]) {
      expect(
        () => RiskAssessment.fromJson(response),
        throwsFormatException,
        reason: 'level must match the 0-29/30-69/70-100 score bands',
      );
    }
  });

  test('requires a non-empty bounded recommendation and signal list', () {
    for (final Object? recommendation in <Object?>[
      null,
      42,
      '',
      '   ',
      List<String>.filled(501, 'x').join(),
    ]) {
      expect(
        () => RiskAssessment.fromJson(
          validResponse(recommendedAction: recommendation),
        ),
        throwsFormatException,
      );
    }
    for (final Object? signals in <Object?>[
      null,
      <String, Object?>{},
      <Object?>['not-a-map'],
      List<Object?>.filled(33, <String, Object?>{
        'code': 'VALID_CODE',
        'label': 'Label',
        'weight': 1,
        'evidence': 'Evidence',
      }),
    ]) {
      expect(
        () => RiskAssessment.fromJson(validResponse(signals: signals)),
        throwsFormatException,
      );
    }
  });

  test('rejects fabricated, coerced and extra signal fields', () {
    final Map<String, Object?> validSignal = <String, Object?>{
      'code': 'VALID_CODE',
      'label': 'A clear label',
      'weight': 8,
      'evidence': 'Bounded evidence',
    };
    final List<Map<String, Object?>> malformed = <Map<String, Object?>>[
      <String, Object?>{...validSignal}..remove('code'),
      <String, Object?>{...validSignal, 'code': 'lowercase'},
      <String, Object?>{...validSignal, 'label': ' '},
      <String, Object?>{...validSignal, 'weight': '8'},
      <String, Object?>{...validSignal, 'weight': 8.0},
      <String, Object?>{...validSignal, 'weight': -1},
      <String, Object?>{...validSignal, 'weight': 101},
      <String, Object?>{...validSignal, 'evidence': ''},
      <String, Object?>{...validSignal, 'unexpected': true},
    ];

    for (final Map<String, Object?> signal in malformed) {
      expect(
        () =>
            RiskAssessment.fromJson(validResponse(signals: <Object?>[signal])),
        throwsFormatException,
        reason: 'signal must fail closed: $signal',
      );
    }
  });

  test('live responses require bounded identifiers', () {
    expect(
      () => RiskAssessment.fromApiJson(validResponse(assessmentId: null)),
      throwsFormatException,
    );
    expect(
      () => RiskAssessment.fromApiJson(validResponse(transactionId: '')),
      throwsFormatException,
    );
    expect(
      () => RiskAssessment.fromApiJson(
        validResponse(assessmentId: 'bad identifier'),
      ),
      throwsFormatException,
    );

    final RiskAssessment stored = RiskAssessment.fromJson(<String, Object?>{
      ...validResponse(),
      'assessment_id': null,
      'transaction_id': null,
    });
    expect(stored.assessmentId, isNull);
    expect(stored.transactionId, isNull);
  });

  test('complete live envelope validates payment, controls and timestamp', () {
    final RiskScoreResult result = RiskScoreResult.fromApiJson(
      validEnvelope(),
      requestedPayment: requestedPayment,
    );

    expect(result.payment.payeeVpa, requestedPayment.payeeVpa);
    expect(result.assessment.level, RiskLevel.highRisk);
    expect(result.requiresConfirmation, isTrue);
    expect(result.handoffPolicy, RiskHandoffPolicy.paused);
    expect(result.assessedAt.isUtc, isTrue);
    expect(result.paymentHandoffEnabled, isTrue);
  });

  test('complete live envelope rejects omitted and extra fields', () {
    for (final String field in validEnvelope().keys) {
      final Map<String, Object?> missing = <String, Object?>{...validEnvelope()}
        ..remove(field);
      expect(
        () => RiskScoreResult.fromApiJson(
          missing,
          requestedPayment: requestedPayment,
        ),
        throwsFormatException,
        reason: '$field is required in the live scoring envelope',
      );
    }

    expect(
      () => RiskScoreResult.fromApiJson(<String, Object?>{
        ...validEnvelope(),
        'unexpected': true,
      }, requestedPayment: requestedPayment),
      throwsFormatException,
    );
  });

  test('live envelope requires exact internally consistent controls', () {
    final List<Map<String, Object?>> validControls = <Map<String, Object?>>[
      validEnvelope(
        level: 'SAFE',
        score: 0,
        requiresConfirmation: false,
        handoffPolicy: 'NORMAL',
      ),
      validEnvelope(
        level: 'CAUTION',
        score: 30,
        handoffPolicy: 'DELIBERATE_CONFIRMATION',
      ),
      validEnvelope(),
    ];
    for (final Map<String, Object?> envelope in validControls) {
      expect(
        () => RiskScoreResult.fromApiJson(
          envelope,
          requestedPayment: requestedPayment,
        ),
        returnsNormally,
      );
    }

    for (final Map<String, Object?> envelope in <Map<String, Object?>>[
      validEnvelope(requiresConfirmation: 'true'),
      validEnvelope(requiresConfirmation: false),
      validEnvelope(handoffPolicy: 'DELIBERATE_CONFIRMATION'),
      validEnvelope(handoffPolicy: 'paused'),
      validEnvelope(
        level: 'SAFE',
        score: 0,
        requiresConfirmation: true,
        handoffPolicy: 'NORMAL',
      ),
      validEnvelope(level: 'CAUTION', score: 30, handoffPolicy: 'NORMAL'),
    ]) {
      expect(
        () => RiskScoreResult.fromApiJson(
          envelope,
          requestedPayment: requestedPayment,
        ),
        throwsFormatException,
      );
    }
  });

  test('rejects reviewer example before creating handoff controls', () {
    expect(
      () => RiskScoreResult.fromApiJson(
        validEnvelope(
          level: 'SAFE',
          score: 100,
          signals: <Object?>[],
          requiresConfirmation: false,
          handoffPolicy: 'NORMAL',
        ),
        requestedPayment: requestedPayment,
      ),
      throwsFormatException,
    );
  });

  test('live envelope requires a timezone-aware assessment timestamp', () {
    for (final Object? timestamp in <Object?>[
      null,
      42,
      '',
      '2026-08-12',
      '2026-08-12T10:00:00',
      'not-a-time',
    ]) {
      expect(
        () => RiskScoreResult.fromApiJson(
          validEnvelope(assessedAt: timestamp),
          requestedPayment: requestedPayment,
        ),
        throwsFormatException,
      );
    }
  });

  test('live envelope rejects every mismatched returned payment field', () {
    final Map<String, Object?> expectedPayment = requestedPayment.toApiJson();
    final Map<String, Object?> mismatches = <String, Object?>{
      'vpa': 'attacker@upi',
      'payee_name': 'Other merchant',
      'amount': 100.51,
      'transaction_note': 'Other invoice',
      'currency': 'USD',
      'transaction_reference': 'ORDER-2',
    };

    for (final MapEntry<String, Object?> mismatch in mismatches.entries) {
      expect(
        () => RiskScoreResult.fromApiJson(
          validEnvelope(
            payment: <String, Object?>{
              ...expectedPayment,
              mismatch.key: mismatch.value,
            },
          ),
          requestedPayment: requestedPayment,
        ),
        throwsFormatException,
        reason: '${mismatch.key} must match the checked payment',
      );
    }
  });
}
