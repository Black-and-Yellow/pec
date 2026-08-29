import 'package:flutter/foundation.dart';

abstract final class AppConfig {
  static const String _configuredApiBase = String.fromEnvironment(
    'API_BASE_URL',
  );

  static Uri get apiBaseUri {
    final String configured = _configuredApiBase.trim();
    if (configured.isNotEmpty) {
      final Uri? uri = Uri.tryParse(
        configured.endsWith('/') ? configured : '$configured/',
      );
      if (uri == null ||
          (uri.scheme != 'http' && uri.scheme != 'https') ||
          !uri.hasAuthority ||
          uri.userInfo.isNotEmpty ||
          uri.hasFragment ||
          uri.hasQuery) {
        throw const FormatException(
          'API_BASE_URL must be an HTTP(S) origin or base path without credentials, a query, or a fragment.',
        );
      }
      if (kReleaseMode && !kIsWeb && uri.scheme != 'https') {
        throw const FormatException(
          'Android release builds require an HTTPS API_BASE_URL.',
        );
      }
      return uri;
    }
    if (kIsWeb) {
      return Uri.base.resolve('/');
    }
    if (kReleaseMode) {
      throw StateError(
        'Android release builds require an explicit HTTPS API_BASE_URL.',
      );
    }
    return Uri.parse('http://10.0.2.2:8000/');
  }

  static const Duration apiTimeout = Duration(seconds: 12);
  static const int maxUpiUriLength = 2048;
  static const int maxContextLength = 5000;
  static const int maxQrImageBytes = 5 * 1024 * 1024;
  static const int maxContextImageBytes = 2000000;
  static const String googleWebClientId = String.fromEnvironment(
    'GOOGLE_WEB_CLIENT_ID',
  );
  static const String googleAndroidServerClientId = String.fromEnvironment(
    'GOOGLE_ANDROID_SERVER_CLIENT_ID',
  );
  static final Uri cybercrimePortal = Uri.parse('https://cybercrime.gov.in/');

  /// The government's own "Report & Check Suspect" search, which accepts a UPI
  /// ID and answers from I4C's repository of identifiers reported by banks and
  /// victims. FinGuard cannot read that repository - it sits behind a CAPTCHA,
  /// and scraping a government portal would be indefensible - so the app hands
  /// the address over and lets the user run the authoritative check themselves.
  static final Uri suspectRegistry = Uri.parse(
    'https://cybercrime.gov.in/Webform/suspect_search_repository.aspx',
  );
}
