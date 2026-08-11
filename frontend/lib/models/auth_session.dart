final class AuthUser {
  const AuthUser({
    required this.id,
    required this.email,
    required this.displayName,
    required this.authProvider,
    required this.createdAt,
  });

  final String id;
  final String email;
  final String displayName;
  final String authProvider;
  final DateTime createdAt;

  factory AuthUser.fromJson(Map<String, Object?> json) {
    final DateTime? createdAt = DateTime.tryParse(
      _requiredString(json, 'created_at'),
    );
    if (createdAt == null) {
      throw const FormatException('Account creation date is invalid.');
    }
    return AuthUser(
      id: _requiredString(json, 'id'),
      email: _requiredString(json, 'email'),
      displayName: _requiredString(json, 'display_name'),
      authProvider: _requiredString(json, 'auth_provider'),
      createdAt: createdAt,
    );
  }
}

final class AuthSession {
  const AuthSession({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresIn,
    required this.user,
  });

  final String accessToken;
  final String refreshToken;
  final int expiresIn;
  final AuthUser user;

  factory AuthSession.fromJson(Map<String, Object?> json) {
    final String accessToken = _requiredString(json, 'access_token');
    final String refreshToken = _requiredString(json, 'refresh_token');
    final Object? expiresValue = json['expires_in'];
    final Object? userValue = json['user'];
    if (accessToken.length < 100 || refreshToken.length < 40) {
      throw const FormatException('Authentication tokens are malformed.');
    }
    if (expiresValue is! int || expiresValue < 60 || expiresValue > 3600) {
      throw const FormatException('Authentication expiry is malformed.');
    }
    if (userValue is! Map<Object?, Object?>) {
      throw const FormatException('Authenticated account is missing.');
    }
    return AuthSession(
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiresIn: expiresValue,
      user: AuthUser.fromJson(
        userValue.map(
          (Object? key, Object? value) => MapEntry(key.toString(), value),
        ),
      ),
    );
  }
}

final class AuthCapabilities {
  const AuthCapabilities({required this.emailPassword, required this.google});

  final bool emailPassword;
  final bool google;

  factory AuthCapabilities.fromJson(Map<String, Object?> json) {
    if (json['email_password'] is! bool || json['google'] is! bool) {
      throw const FormatException('Authentication capabilities are malformed.');
    }
    return AuthCapabilities(
      emailPassword: json['email_password']! as bool,
      google: json['google']! as bool,
    );
  }
}

String _requiredString(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('Authentication response is missing $key.');
  }
  return value.trim();
}
