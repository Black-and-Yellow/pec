import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import '../models/auth_session.dart';
import 'api_service.dart';

abstract interface class FinGuardAuthApi {
  Future<AuthCapabilities> capabilities();
  Future<AuthSession> register({
    required String email,
    required String password,
    required String displayName,
  });
  Future<AuthSession> login({required String email, required String password});
  Future<AuthSession> googleLogin(String idToken);
  Future<AuthSession> refresh(String refreshToken);
  Future<void> logout(String refreshToken);
  Future<void> deleteAccount({
    required String accessToken,
    String? password,
  });
}

final class AuthApiService implements FinGuardAuthApi {
  AuthApiService({
    required Uri baseUri,
    http.Client? client,
    this.timeout = AppConfig.apiTimeout,
  }) : _baseUri = baseUri,
       _client = client ?? http.Client();

  final Uri _baseUri;
  final http.Client _client;
  final Duration timeout;

  @override
  Future<AuthCapabilities> capabilities() async => AuthCapabilities.fromJson(
    await _request('api/v1/auth/capabilities', method: 'GET'),
  );

  @override
  Future<AuthSession> register({
    required String email,
    required String password,
    required String displayName,
  }) async => AuthSession.fromJson(
    await _request(
      'api/v1/auth/register',
      body: <String, Object?>{
        'email': email.trim(),
        'password': password,
        'display_name': displayName.trim(),
      },
    ),
  );

  @override
  Future<AuthSession> login({
    required String email,
    required String password,
  }) async => AuthSession.fromJson(
    await _request(
      'api/v1/auth/login',
      body: <String, Object?>{'email': email.trim(), 'password': password},
    ),
  );

  @override
  Future<AuthSession> googleLogin(String idToken) async => AuthSession.fromJson(
    await _request(
      'api/v1/auth/google',
      body: <String, Object?>{'id_token': idToken},
    ),
  );

  @override
  Future<AuthSession> refresh(String refreshToken) async =>
      AuthSession.fromJson(
        await _request(
          'api/v1/auth/refresh',
          body: <String, Object?>{'refresh_token': refreshToken},
        ),
      );

  @override
  Future<void> logout(String refreshToken) async {
    await _request(
      'api/v1/auth/logout',
      body: <String, Object?>{'refresh_token': refreshToken},
    );
  }

  @override
  Future<void> deleteAccount({
    required String accessToken,
    String? password,
  }) async {
    await _request(
      'api/v1/auth/account/delete',
      body: <String, Object?>{
        'confirmation': 'DELETE',
        'password': ?password,
      },
      accessToken: accessToken,
    );
  }

  Future<Map<String, Object?>> _request(
    String path, {
    String method = 'POST',
    Map<String, Object?>? body,
    String? accessToken,
  }) async {
    final Uri uri = _baseUri.resolve(path);
    late http.Response response;
    try {
      response =
          await (method == 'GET'
                  ? _client.get(
                      uri,
                      headers: <String, String>{
                        'Accept': 'application/json',
                        if (accessToken != null)
                          'Authorization': 'Bearer $accessToken',
                      },
                    )
                  : _client.post(
                      uri,
                      headers: <String, String>{
                        'Accept': 'application/json',
                        'Content-Type': 'application/json',
                        if (accessToken != null)
                          'Authorization': 'Bearer $accessToken',
                      },
                      body: jsonEncode(body),
                    ))
              .timeout(timeout);
    } on Object {
      throw const ApiException(
        'FinGuard could not reach the account service. Try again.',
        retryable: true,
      );
    }
    late Map<String, Object?> json;
    try {
      final Object? decoded = jsonDecode(response.body);
      if (decoded is! Map<Object?, Object?>) {
        throw const FormatException();
      }
      json = decoded.map(
        (Object? key, Object? value) => MapEntry(key.toString(), value),
      );
    } on FormatException {
      throw const ApiException(
        'The account service returned an invalid response.',
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final Object? errorValue = json['error'];
      final Map<Object?, Object?>? error = errorValue is Map<Object?, Object?>
          ? errorValue
          : null;
      final Object? message = error?['message'];
      throw ApiException(
        message is String && message.trim().isNotEmpty
            ? message.trim()
            : 'The account request could not be completed.',
        retryable: response.statusCode >= 500,
      );
    }
    return json;
  }
}
