import 'dart:convert';

import 'package:finguard/models/context_analysis.dart';
import 'package:finguard/models/payment.dart';
import 'package:finguard/models/risk.dart';
import 'package:finguard/services/api_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/fakes.dart';

Map<String, Object?> _riskEnvelope({
  required Map<String, Object?> payment,
  required int score,
  required String level,
  required bool requiresConfirmation,
  required String handoffPolicy,
  String assessmentId = 'assessment-1',
  String transactionId = 'transaction-1',
  List<Object?> signals = const <Object?>[],
  String recommendedAction = 'Review independently.',
  Map<String, Object?>? payeeTrust,
}) => <String, Object?>{
  'assessment_id': assessmentId,
  'transaction_id': transactionId,
  'payment': payment,
  'payee_trust':
      payeeTrust ?? payeeTrustJson(vpa: payment['vpa']! as String),
  'score': score,
  'level': level,
  'signals': signals,
  'recommended_action': recommendedAction,
  'requires_confirmation': requiresConfirmation,
  'handoff_policy': handoffPolicy,
  'assessed_at': '2026-08-12T10:00:00Z',
};

void main() {
  test(
    'API client uses strict request shapes and the canonical handoff URI',
    () async {
      final List<Map<String, Object?>> requests = <Map<String, Object?>>[];
      final MockClient client = MockClient((http.Request request) async {
        final Map<String, Object?> body =
            (jsonDecode(request.body) as Map<Object?, Object?>).map(
              (Object? key, Object? value) => MapEntry(key.toString(), value),
            );
        requests.add(body);
        if (request.url.path.endsWith('/payments/parse')) {
          return http.Response(
            jsonEncode(<String, Object?>{
              'payment': <String, Object?>{
                'vpa': 'merchant@upi',
                'payee_name': 'Merchant',
                'amount': 4500,
                'transaction_note': 'Order payment',
                'currency': 'INR',
                'transaction_reference': null,
              },
              'canonical_uri':
                  'upi://pay?pa=merchant%40upi&pn=Merchant&am=4500.00&cu=INR&tn=Order%20payment',
            }),
            200,
            headers: const <String, String>{'content-type': 'application/json'},
          );
        }
        if (request.url.path.endsWith('/risk/score')) {
          return http.Response(
            jsonEncode(
              _riskEnvelope(
                payment: <String, Object?>{
                  'vpa': 'merchant@upi',
                  'payee_name': 'Merchant',
                  'amount': 4500,
                  'transaction_note': 'Order payment',
                  'currency': 'INR',
                  'transaction_reference': null,
                },
                score: 33,
                level: 'CAUTION',
                requiresConfirmation: true,
                handoffPolicy: 'DELIBERATE_CONFIRMATION',
                signals: <Object?>[
                  <String, Object?>{
                    'code': 'FIRST_TIME_PAYEE',
                    'label': 'First-time recipient',
                    'weight': 33,
                    'evidence': 'No completed payment exists',
                  },
                ],
                recommendedAction: 'Verify independently.',
              ),
            ),
            200,
            headers: const <String, String>{'content-type': 'application/json'},
          );
        }
        return http.Response(
          jsonEncode(<String, Object?>{
            'summary': 'Prepared summary',
            'report': <String, Object?>{
              'generated_at': '2026-08-10T10:00:00Z',
              'status': 'PRE_PAYMENT',
              'recipient_vpa': 'merchant@upi',
              'recipient_name': 'Merchant',
              'amount': 4500,
              'currency': 'INR',
              'risk_score': 33,
              'risk_level': 'CAUTION',
              'detected_signals': <Object?>[],
              'summary': 'Prepared summary',
              'data_provenance': 'Seeded and user-supplied data.',
            },
            'disclaimer': 'Nothing was submitted.',
          }),
          200,
          headers: const <String, String>{'content-type': 'application/json'},
        );
      });
      final ApiService api = ApiService(
        baseUri: Uri.parse('https://example.test/'),
        client: client,
      );

      final Payment payment = await api.parsePayment(
        'upi://pay?pa=merchant@upi&pn=Merchant&am=4500&cu=INR&tn=Order%20payment&url=https%3A%2F%2Fevil.invalid',
      );
      final RiskScoreResult scored = await api.scorePayment(
        payment: payment,
        deviceId: 'device-test-1',
      );
      final String report = await api.prepareResponse(
        payment: scored.payment,
        assessment: scored.assessment,
        alreadyPaid: false,
      );

      expect(payment.upiUri, isNot(contains('evil.invalid')));
      expect(requests[1]['payment'], <String, Object?>{
        'vpa': 'merchant@upi',
        'payee_name': 'Merchant',
        'amount': 4500.0,
        'transaction_note': 'Order payment',
        'currency': 'INR',
        'transaction_reference': null,
      });
      final Map<Object?, Object?> responseAssessment =
          requests[2]['assessment']! as Map<Object?, Object?>;
      expect(responseAssessment['assessment_id'], 'assessment-1');
      expect(responseAssessment['level'], 'CAUTION');
      expect(scored.requiresConfirmation, isTrue);
      expect(scored.handoffPolicy, RiskHandoffPolicy.deliberateConfirmation);
      expect(scored.assessedAt, DateTime.utc(2026, 8, 12, 10));
      expect(report, contains('Recipient: Merchant (merchant@upi)'));
      expect(report, isNot(contains('{generated_at:')));
    },
  );

  test('parse rejects a server-substituted recipient', () async {
    final ApiService api = ApiService(
      baseUri: Uri.parse('https://example.test/'),
      client: MockClient((http.Request request) async {
        return http.Response(
          jsonEncode(<String, Object?>{
            'payment': <String, Object?>{
              'vpa': 'attacker@upi',
              'payee_name': 'Merchant',
              'amount': 4500,
              'transaction_note': null,
              'currency': 'INR',
              'transaction_reference': null,
            },
            'canonical_uri':
                'upi://pay?pa=attacker%40upi&pn=Merchant&am=4500&cu=INR',
          }),
          200,
          headers: const <String, String>{'content-type': 'application/json'},
        );
      }),
    );

    await expectLater(
      api.parsePayment('upi://pay?pa=merchant@upi&pn=Merchant&am=4500&cu=INR'),
      throwsA(isA<ApiException>()),
    );
  });

  test('parse rejects a server-substituted amount', () async {
    final ApiService api = ApiService(
      baseUri: Uri.parse('https://example.test/'),
      client: MockClient((http.Request request) async {
        return http.Response(
          jsonEncode(<String, Object?>{
            'payment': <String, Object?>{
              'vpa': 'merchant@upi',
              'payee_name': 'Merchant',
              'amount': 45,
              'transaction_note': null,
              'currency': 'INR',
              'transaction_reference': null,
            },
            'canonical_uri':
                'upi://pay?pa=merchant%40upi&pn=Merchant&am=45&cu=INR',
          }),
          200,
          headers: const <String, String>{'content-type': 'application/json'},
        );
      }),
    );

    await expectLater(
      api.parsePayment('upi://pay?pa=merchant@upi&pn=Merchant&am=4500&cu=INR'),
      throwsA(isA<ApiException>()),
    );
  });

  test(
    'context analysis sends explicit consent and parses local fallback flags',
    () async {
      late Map<String, Object?> requestBody;
      final ApiService api = ApiService(
        baseUri: Uri.parse('https://example.test/'),
        client: MockClient((http.Request request) async {
          requestBody = (jsonDecode(request.body) as Map<Object?, Object?>).map(
            (Object? key, Object? value) => MapEntry(key.toString(), value),
          );
          return http.Response(
            jsonEncode(<String, Object?>{
              'available': false,
              'source': 'local_rules',
              'status': 'consent_required',
              'message': 'Nothing was sent externally.',
              'context_token': 'signed-local-context-token',
              'context': <String, Object?>{
                'impersonation': false,
                'urgency': true,
                'kyc_threat': true,
                'reward_or_refund_claim': false,
                'payment_requested': true,
                'suspicious_support_claim': false,
                'confidence': 0.71,
              },
            }),
            200,
            headers: const <String, String>{'content-type': 'application/json'},
          );
        }),
      );

      final result = await api.analyzeContext(
        text: 'Urgent: update KYC now',
        consentToExternalAi: false,
      );

      expect(requestBody['consent_to_external_ai'], isFalse);
      expect(result.source.name, 'localRules');
      expect(result.hasValidatedContext, isTrue);
      expect(result.integrityToken, 'signed-local-context-token');
      expect(result.detectedLabels, contains('Urgent or pressuring language'));
      expect(result.toApiJson().keys, isNot(contains('available')));
    },
  );

  test('parsed signed context and integrity token are sent together', () async {
    late Map<String, Object?> requestBody;
    final ApiService api = ApiService(
      baseUri: Uri.parse('https://example.test/'),
      client: MockClient((http.Request request) async {
        requestBody = (jsonDecode(request.body) as Map<Object?, Object?>).map(
          (Object? key, Object? value) => MapEntry(key.toString(), value),
        );
        return http.Response(
          jsonEncode(
            _riskEnvelope(
              payment: <String, Object?>{
                'vpa': 'merchant@upi',
                'payee_name': 'Merchant',
                'amount': 100,
                'transaction_note': null,
                'currency': 'INR',
                'transaction_reference': null,
              },
              score: 18,
              level: 'SAFE',
              requiresConfirmation: false,
              handoffPolicy: 'NORMAL',
              assessmentId: 'assessment-context-1',
              transactionId: 'transaction-context-1',
              signals: <Object?>[
                <String, Object?>{
                  'code': 'CONTEXT_RISK',
                  'label': 'Validated context risk',
                  'weight': 18,
                  'evidence': 'Signed context fixture',
                },
              ],
            ),
          ),
          200,
          headers: const <String, String>{'content-type': 'application/json'},
        );
      }),
    );
    const Payment payment = Payment(
      upiUri: 'upi://pay?pa=merchant%40upi&pn=Merchant&am=100&cu=INR',
      payeeVpa: 'merchant@upi',
      payeeName: 'Merchant',
      amount: 100,
      currency: 'INR',
    );
    final ContextAnalysis context = ContextAnalysis.fromJson(<String, Object?>{
      'available': false,
      'source': 'local_rules',
      'context_token': 'signed-context-token',
      'context': <String, Object?>{
        'impersonation': false,
        'urgency': true,
        'kyc_threat': true,
        'reward_or_refund_claim': false,
        'payment_requested': true,
        'suspicious_support_claim': false,
        'confidence': 0.71,
      },
    }, sourceText: 'Urgent KYC payment required now');

    await api.scorePayment(
      payment: payment,
      deviceId: 'device-test-1',
      context: context,
    );

    expect(requestBody['context_token'], 'signed-context-token');
    expect(requestBody['context'], context.toApiJson());
  });

  test('source-none context is omitted from deterministic scoring', () async {
    late Map<String, Object?> requestBody;
    final ApiService api = ApiService(
      baseUri: Uri.parse('https://example.test/'),
      client: MockClient((http.Request request) async {
        requestBody = (jsonDecode(request.body) as Map<Object?, Object?>).map(
          (Object? key, Object? value) => MapEntry(key.toString(), value),
        );
        return http.Response(
          jsonEncode(
            _riskEnvelope(
              payment: <String, Object?>{
                'vpa': 'merchant@upi',
                'payee_name': 'Merchant',
                'amount': 100,
                'transaction_note': null,
                'currency': 'INR',
                'transaction_reference': null,
              },
              score: 0,
              level: 'SAFE',
              requiresConfirmation: false,
              handoffPolicy: 'NORMAL',
              assessmentId: 'assessment-no-context-1',
              transactionId: 'transaction-no-context-1',
            ),
          ),
          200,
          headers: const <String, String>{'content-type': 'application/json'},
        );
      }),
    );
    const Payment payment = Payment(
      upiUri: 'upi://pay?pa=merchant%40upi&pn=Merchant&am=100&cu=INR',
      payeeVpa: 'merchant@upi',
      payeeName: 'Merchant',
      amount: 100,
      currency: 'INR',
    );
    const ContextAnalysis unavailable = ContextAnalysis(
      available: false,
      sourceText: 'Unvalidated source text',
      flags: <String, bool>{'urgency': true},
      source: ContextAnalysisSource.none,
    );

    await api.scorePayment(
      payment: payment,
      deviceId: 'device-test-1',
      context: unavailable,
    );

    expect(requestBody, isNot(contains('context')));
  });

  test('live scoring rejects a response without server identifiers', () async {
    final ApiService api = ApiService(
      baseUri: Uri.parse('https://example.test/'),
      client: MockClient((http.Request request) async {
        return http.Response(
          jsonEncode(<String, Object?>{
            'score': 0,
            'level': 'SAFE',
            'signals': <Object?>[],
            'recommended_action': 'Review independently.',
          }),
          200,
          headers: const <String, String>{'content-type': 'application/json'},
        );
      }),
    );
    const Payment payment = Payment(
      upiUri: 'upi://pay?pa=merchant%40upi&pn=Merchant&am=100&cu=INR',
      payeeVpa: 'merchant@upi',
      payeeName: 'Merchant',
      amount: 100,
      currency: 'INR',
    );

    expect(
      () => api.scorePayment(payment: payment, deviceId: 'device-test-1'),
      throwsFormatException,
    );
  });
}
