import 'dart:convert';

import 'package:finguard/services/api_service.dart';
import 'package:finguard/services/auth_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'refresh marks server 5xx as retryable without rejecting session',
    () async {
      final AuthApiService api = AuthApiService(
        baseUri: Uri.parse('https://example.test/'),
        client: MockClient(
          (_) async => http.Response(
            jsonEncode(<String, Object?>{
              'error': <String, Object?>{
                'code': 'INTERNAL_ERROR',
                'message': 'Temporary failure',
              },
            }),
            503,
          ),
        ),
      );

      final ApiException error = await _refreshError(api);

      expect(error.retryable, isTrue);
      expect(error.statusCode, 503);
      expect(error.definitivelyRejectsSession, isFalse);
    },
  );

  test('refresh identifies the backend invalid-session rejection', () async {
    final AuthApiService api = AuthApiService(
      baseUri: Uri.parse('https://example.test/'),
      client: MockClient(
        (_) async => http.Response(
          jsonEncode(<String, Object?>{
            'error': <String, Object?>{
              'code': 'INVALID_SESSION',
              'message': 'Session is invalid or expired',
            },
          }),
          401,
        ),
      ),
    );

    final ApiException error = await _refreshError(api);

    expect(error.retryable, isFalse);
    expect(error.statusCode, 401);
    expect(error.errorCode, 'INVALID_SESSION');
    expect(error.definitivelyRejectsSession, isTrue);
  });
}

Future<ApiException> _refreshError(AuthApiService api) async {
  try {
    await api.refresh('r' * 64);
  } on ApiException catch (error) {
    return error;
  }
  throw StateError('Expected refresh to fail.');
}
