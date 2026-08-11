import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import '../models/context_analysis.dart';
import '../models/payment.dart';
import '../models/risk.dart';

abstract interface class FinGuardApi {
  Future<Payment> parsePayment(String upiUri);

  Future<RiskAssessment> scorePayment({
    required Payment payment,
    required String deviceId,
    ContextAnalysis? context,
  });

  Future<ContextAnalysis> analyzeContext({
    required bool consentToExternalAi,
    String? text,
    Uint8List? screenshotBytes,
    String? screenshotMimeType,
  });

  Future<String> prepareResponse({
    required Payment payment,
    required RiskAssessment assessment,
    required bool alreadyPaid,
    ContextAnalysis? context,
  });
}

final class ApiException implements Exception {
  const ApiException(this.message, {this.retryable = false});

  final String message;
  final bool retryable;

  @override
  String toString() => message;
}

final class ApiService implements FinGuardApi {
  ApiService({
    required Uri baseUri,
    http.Client? client,
    this.timeout = AppConfig.apiTimeout,
  }) : _baseUri = baseUri,
       _client = client ?? http.Client();

  final Uri _baseUri;
  final http.Client _client;
  final Duration timeout;

  @override
  Future<Payment> parsePayment(String upiUri) async {
    final Uri safeUri = Payment.validateUpiUri(upiUri);
    final Map<String, Object?> json = await _post(
      'api/v1/payments/parse',
      <String, Object?>{'upi_uri': safeUri.toString()},
    );
    final Map<String, Object?> paymentJson =
        _nestedMap(json, 'payment') ?? json;
    final Object? canonicalValue = json['canonical_uri'];
    if (canonicalValue is! String || canonicalValue.trim().isEmpty) {
      throw const ApiException(
        'The server response did not include a validated UPI handoff request.',
      );
    }
    final String canonicalUri = canonicalValue.trim();
    try {
      return Payment.fromJson(paymentJson, canonicalUpiUri: canonicalUri);
    } on FormatException catch (error) {
      throw ApiException(error.message.toString());
    }
  }

  @override
  Future<RiskAssessment> scorePayment({
    required Payment payment,
    required String deviceId,
    ContextAnalysis? context,
  }) async {
    final Map<String, Object?> json =
        await _post('api/v1/risk/score', <String, Object?>{
          'payment': payment.toApiJson(),
          'device_id': deviceId,
          if (context != null) 'context': context.toApiJson(),
        });
    final Map<String, Object?> assessmentJson =
        _nestedMap(json, 'assessment') ?? _nestedMap(json, 'risk') ?? json;
    return RiskAssessment.fromJson(assessmentJson);
  }

  @override
  Future<ContextAnalysis> analyzeContext({
    required bool consentToExternalAi,
    String? text,
    Uint8List? screenshotBytes,
    String? screenshotMimeType,
  }) async {
    final String safeText = text?.trim() ?? '';
    if (safeText.isEmpty && screenshotBytes == null) {
      throw const ApiException('Paste a message or choose a screenshot first.');
    }
    if (safeText.length > AppConfig.maxContextLength) {
      throw const ApiException(
        'The message is too long. Keep it under 5,000 characters.',
      );
    }
    if (screenshotBytes != null) {
      if (screenshotBytes.isEmpty ||
          screenshotBytes.length > AppConfig.maxContextImageBytes) {
        throw const ApiException(
          'Choose a non-empty screenshot no larger than 2 MB.',
        );
      }
      if (screenshotMimeType != 'image/png' &&
          screenshotMimeType != 'image/jpeg' &&
          screenshotMimeType != 'image/webp') {
        throw const ApiException('Choose a PNG, JPEG or WebP screenshot.');
      }
    } else if (screenshotMimeType != null) {
      throw const ApiException('The screenshot data is incomplete.');
    }
    final Map<String, Object?> json = await _post(
      'api/v1/context/analyze',
      <String, Object?>{
        if (safeText.isNotEmpty) 'text': safeText,
        if (screenshotBytes != null)
          'screenshot_base64': base64Encode(screenshotBytes),
        if (screenshotBytes != null) 'screenshot_mime_type': screenshotMimeType,
        'consent_to_external_ai': consentToExternalAi,
      },
    );
    return ContextAnalysis.fromJson(json, sourceText: safeText);
  }

  @override
  Future<String> prepareResponse({
    required Payment payment,
    required RiskAssessment assessment,
    required bool alreadyPaid,
    ContextAnalysis? context,
  }) async {
    final Map<String, Object?> json =
        await _post('api/v1/response/prepare', <String, Object?>{
          'payment': payment.toApiJson(),
          'assessment': assessment.toApiJson(),
          'already_paid': alreadyPaid,
          if (context != null) 'context': context.toApiJson(),
          if ((context?.sourceText ?? '').isNotEmpty)
            'suspicious_message': context!.sourceText,
        });
    final String report = _preparedReportText(json);
    if (report.isEmpty) {
      throw const ApiException('The server could not prepare a report draft.');
    }
    return report;
  }

  Future<Map<String, Object?>> _post(
    String path,
    Map<String, Object?> body,
  ) async {
    try {
      final http.Response response = await _client
          .post(
            _endpoint(path),
            headers: const <String, String>{
              'accept': 'application/json',
              'content-type': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(timeout);
      final Object? decoded = _decodeBody(response);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw ApiException(
          _errorMessage(decoded, response.statusCode),
          retryable: response.statusCode >= 500,
        );
      }
      if (decoded is! Map<Object?, Object?>) {
        throw const ApiException('The server returned an unexpected response.');
      }
      return decoded.map(
        (Object? key, Object? value) => MapEntry(key.toString(), value),
      );
    } on TimeoutException {
      throw const ApiException(
        'FinGuard took too long to respond. Check the connection and try again.',
        retryable: true,
      );
    } on http.ClientException {
      throw const ApiException(
        'FinGuard cannot reach the safety service right now. Your UPI app was not opened.',
        retryable: true,
      );
    } on FormatException {
      throw const ApiException(
        'The server returned unreadable data. Please try again.',
      );
    }
  }

  Uri _endpoint(String path) => _baseUri.resolve(path);

  Object? _decodeBody(http.Response response) {
    if (response.body.trim().isEmpty) {
      return null;
    }
    return jsonDecode(response.body);
  }

  String _errorMessage(Object? decoded, int statusCode) {
    if (decoded is Map<Object?, Object?>) {
      final Object? detail =
          decoded['detail'] ?? decoded['message'] ?? decoded['error'];
      if (detail is String && detail.trim().isNotEmpty) {
        return detail;
      }
      if (detail is Map<Object?, Object?>) {
        final Object? message = detail['message'] ?? detail['detail'];
        if (message is String && message.trim().isNotEmpty) {
          return message;
        }
      }
      if (detail is List<Object?> && detail.isNotEmpty) {
        final Object? first = detail.first;
        if (first is Map<Object?, Object?> && first['msg'] != null) {
          return first['msg'].toString();
        }
      }
    }
    return 'FinGuard could not complete this check (HTTP $statusCode).';
  }

  static Map<String, Object?>? _nestedMap(
    Map<String, Object?> json,
    String key,
  ) {
    final Object? value = json[key];
    if (value is! Map<Object?, Object?>) {
      return null;
    }
    return value.map(
      (Object? itemKey, Object? itemValue) =>
          MapEntry(itemKey.toString(), itemValue),
    );
  }

  static String _preparedReportText(Map<String, Object?> json) {
    final Object? reportValue = json['report'];
    if (reportValue is String && reportValue.trim().isNotEmpty) {
      return reportValue.trim();
    }
    final Map<String, Object?>? report = _nestedMap(json, 'report');
    if (report != null) {
      final StringBuffer text = StringBuffer('FinGuard incident summary');
      void addLine(String label, Object? value) {
        final String content = value?.toString().trim() ?? '';
        if (content.isNotEmpty) {
          text
            ..writeln()
            ..write('$label: $content');
        }
      }

      addLine('Prepared', report['generated_at']);
      addLine('Status', report['status']);
      final String recipientName =
          report['recipient_name']?.toString().trim() ?? '';
      final String recipientVpa =
          report['recipient_vpa']?.toString().trim() ?? '';
      addLine(
        'Recipient',
        recipientName.isEmpty ? recipientVpa : '$recipientName ($recipientVpa)',
      );
      final Object? amount = report['amount'];
      if (amount != null) {
        addLine('Amount', '${report['currency'] ?? 'INR'} $amount');
      } else {
        addLine('Amount', 'Not specified in the payment request');
      }
      addLine('Reference', report['transaction_reference']);
      addLine(
        'Risk',
        '${report['risk_level'] ?? ''} — ${report['risk_score'] ?? ''}/100',
      );
      addLine('Summary', report['summary'] ?? json['summary']);
      addLine('Supplied message', report['suspicious_message']);
      final Object? signals = report['detected_signals'];
      if (signals is List<Object?> && signals.isNotEmpty) {
        text.write('\n\nDetected signals:');
        for (final Object? value in signals) {
          if (value is Map<Object?, Object?>) {
            final String label = (value['label'] ?? 'Risk signal').toString();
            final String weight = (value['weight'] ?? 0).toString();
            final String evidence = (value['evidence'] ?? '').toString();
            text.write('\n- $label (+$weight): $evidence');
          }
        }
      }
      addLine('Data provenance', report['data_provenance']);
      final String disclaimer = json['disclaimer']?.toString().trim() ?? '';
      if (disclaimer.isNotEmpty) {
        text.write('\n\n$disclaimer');
      }
      return text.toString().trim();
    }
    return (json['summary'] ??
            json['incident_summary'] ??
            _nestedMap(json, 'response')?['summary'] ??
            '')
        .toString()
        .trim();
  }
}
