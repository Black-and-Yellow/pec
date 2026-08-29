import 'package:finguard/models/context_analysis.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('source none is never treated as validated context', () {
    final ContextAnalysis analysis = ContextAnalysis.fromJson(<String, Object?>{
      'available': true,
      'source': 'none',
      'context_token': 'server-token-that-must-not-override-source-none',
      'context': <String, Object?>{
        'impersonation': false,
        'urgency': true,
        'kyc_threat': false,
        'reward_or_refund_claim': false,
        'payment_requested': false,
        'suspicious_support_claim': false,
        'confidence': 0.9,
      },
    }, sourceText: 'Unvalidated text');

    expect(analysis.hasValidatedContext, isFalse);
  });

  test('locally fabricated non-none context is never validated', () {
    const ContextAnalysis analysis = ContextAnalysis(
      available: false,
      sourceText: 'Urgent message',
      flags: <String, bool>{'urgency': true},
      confidence: 0.9,
      source: ContextAnalysisSource.localRules,
    );

    expect(analysis.hasValidatedContext, isFalse);
    expect(analysis.integrityToken, isNull);
  });

  test('strict parsed signed local-rule context is eligible for scoring', () {
    final ContextAnalysis analysis = ContextAnalysis.fromJson(<String, Object?>{
      'available': false,
      'source': 'local_rules',
      'context_token': 'server-issued-integrity-token',
      'context': <String, Object?>{
        'impersonation': false,
        'urgency': true,
        'kyc_threat': false,
        'reward_or_refund_claim': false,
        'payment_requested': false,
        'suspicious_support_claim': false,
        'confidence': 0.47,
      },
    }, sourceText: 'Urgent message');

    expect(analysis.available, isFalse);
    expect(analysis.source, ContextAnalysisSource.localRules);
    expect(analysis.hasValidatedContext, isTrue);
    expect(analysis.integrityToken, 'server-issued-integrity-token');
  });
}
