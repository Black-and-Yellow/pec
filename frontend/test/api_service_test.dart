import 'dart:convert';

import 'package:finguard/models/payment.dart';
import 'package:finguard/models/risk.dart';
import 'package:finguard/services/api_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

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
            jsonEncode(<String, Object?>{
              'assessment_id': 'assessment-1',
              'transaction_id': 'transaction-1',
              'score': 33,
              'level': 'CAUTION',
              'signals': <Object?>[
                <String, Object?>{
                  'code': 'FIRST_TIME_PAYEE',
                  'label': 'First-time recipient',
                  'weight': 18,
                  'evidence': 'No completed payment exists',
                },
              ],
              'recommended_action': 'Verify independently.',
            }),
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
        'upi://pay?pa=merchant@upi&pn=Untrusted%20Name&am=4500&cu=INR&url=https%3A%2F%2Fevil.invalid',
      );
      final RiskAssessment assessment = await api.scorePayment(
        payment: payment,
        deviceId: 'device-test-1',
      );
      final String report = await api.prepareResponse(
        payment: payment,
        assessment: assessment,
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
      expect(report, contains('Recipient: Merchant (merchant@upi)'));
      expect(report, isNot(contains('{generated_at:')));
    },
  );

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
      expect(result.detectedLabels, contains('Urgent or pressuring language'));
      expect(result.toApiJson().keys, isNot(contains('available')));
    },
  );
}
