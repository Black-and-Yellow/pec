import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../config/app_config.dart';
import '../models/auth_session.dart';
import 'api_service.dart';
import 'auth_api.dart';
import 'auth_store.dart';

enum AuthStatus { loading, signedOut, guest, authenticated }

final class AuthController extends ChangeNotifier {
  AuthController({
    required FinGuardAuthApi api,
    required AuthStore store,
    GoogleSignIn? googleSignIn,
  }) : _api = api,
       _store = store,
       _googleSignIn = googleSignIn ?? GoogleSignIn.instance;

  final FinGuardAuthApi _api;
  final AuthStore _store;
  final GoogleSignIn _googleSignIn;
  StreamSubscription<GoogleSignInAuthenticationEvent>? _googleSubscription;

  AuthStatus _status = AuthStatus.loading;
  AuthSession? _session;
  AuthCapabilities _capabilities = const AuthCapabilities(
    emailPassword: true,
    google: false,
  );
  bool _busy = false;
  String? _error;
  bool _googleInitialized = false;
  bool _canRetrySessionRestore = false;

  static const String _storageError =
      'FinGuard could not access secure session storage. Try again.';

  AuthStatus get status => _status;
  AuthUser? get user => _session?.user;
  String? get accessToken => _session?.accessToken;
  bool get busy => _busy;
  String? get error => _error;
  bool get canRetrySessionRestore => _canRetrySessionRestore;
  bool get googleEnabled => _capabilities.google && _googleInitialized;
  bool get emailPasswordEnabled => _capabilities.emailPassword;

  Future<void> initialize() async {
    _status = AuthStatus.loading;
    _session = null;
    _busy = false;
    _error = null;
    _canRetrySessionRestore = false;
    notifyListeners();
    try {
      _capabilities = await _api.capabilities();
    } on Object {
      _capabilities = const AuthCapabilities(
        emailPassword: true,
        google: false,
      );
    }
    await _initializeGoogleIfAvailable();
    late String? refreshToken;
    try {
      refreshToken = await _store.readRefreshToken();
    } on Object {
      _finishSessionRestoreFailure(_storageError);
      return;
    }
    if (refreshToken != null && refreshToken.isNotEmpty) {
      try {
        final AuthSession refreshed = await _api.refresh(refreshToken);
        if (await _acceptSession(refreshed)) {
          return;
        }
        _finishSessionRestoreFailure(_storageError);
        return;
      } on ApiException catch (error) {
        if (!error.definitivelyRejectsSession) {
          _finishSessionRestoreFailure(
            'FinGuard could not restore your saved session. Check the connection and try again.',
          );
          return;
        }
        try {
          await _store.clear();
        } on Object {
          _finishSessionRestoreFailure(_storageError);
          return;
        }
        _finishSignedOut();
        return;
      } on FormatException {
        _finishSessionRestoreFailure(
          'FinGuard could not validate the restored session. Try again.',
        );
        return;
      } on Object {
        _finishSessionRestoreFailure(
          'FinGuard could not restore your saved session. Try again.',
        );
        return;
      }
    }
    late bool guestMode;
    try {
      guestMode = await _store.readGuestMode();
    } on Object {
      _finishSessionRestoreFailure(_storageError);
      return;
    }
    _status = guestMode ? AuthStatus.guest : AuthStatus.signedOut;
    notifyListeners();
  }

  Future<void> register({
    required String email,
    required String password,
    required String displayName,
  }) => _runAuth(
    () => _api.register(
      email: email,
      password: password,
      displayName: displayName,
    ),
  );

  Future<void> login({required String email, required String password}) =>
      _runAuth(() => _api.login(email: email, password: password));

  Future<void> signInWithGoogle() async {
    if (!googleEnabled) {
      _setError('Google sign-in is not configured for this deployment.');
      return;
    }
    if (!_googleSignIn.supportsAuthenticate()) {
      return;
    }
    _setBusy(true);
    try {
      await _googleSignIn.authenticate();
    } on GoogleSignInException {
      _setError('Google sign-in was cancelled or could not be completed.');
    } on Object {
      _setError('Google sign-in could not be completed.');
    } finally {
      if (_status != AuthStatus.authenticated) {
        _setBusy(false);
      }
    }
  }

  Future<void> continueAsGuest() async {
    _setBusy(true);
    try {
      await _store.saveGuestMode(true);
    } on Object {
      _setError(_storageError);
      return;
    }
    _session = null;
    _busy = false;
    _error = null;
    _canRetrySessionRestore = false;
    _status = AuthStatus.guest;
    notifyListeners();
  }

  Future<void> leaveGuestMode() async {
    _setBusy(true);
    try {
      await _store.saveGuestMode(false);
    } on Object {
      _setError(_storageError);
      return;
    }
    _busy = false;
    _status = AuthStatus.signedOut;
    _error = null;
    _canRetrySessionRestore = false;
    notifyListeners();
  }

  Future<void> signOut() async {
    final String? refreshToken = _session?.refreshToken;
    _setBusy(true);
    try {
      if (refreshToken != null) {
        await _api.logout(refreshToken);
      }
    } on Object {
      // Local sign-out must still succeed if the server is unavailable.
    }
    try {
      if (_googleInitialized) {
        await _googleSignIn.signOut();
      }
    } on Object {
      // The FinGuard session is authoritative; Google cleanup is best effort.
    }
    try {
      await _store.clear();
    } on Object {
      _setError(_storageError);
      return;
    }
    _session = null;
    _busy = false;
    _error = null;
    _canRetrySessionRestore = false;
    _status = AuthStatus.signedOut;
    notifyListeners();
  }

  Future<bool> deleteAccount({String? password}) async {
    final String? token = _session?.accessToken;
    if (token == null) {
      _setError('Your session has expired. Sign in again.');
      return false;
    }
    _setBusy(true);
    try {
      await _api.deleteAccount(accessToken: token, password: password);
      bool storageCleared = true;
      try {
        await _store.clear();
      } on Object {
        storageCleared = false;
      }
      _session = null;
      _busy = false;
      _error = storageCleared ? null : _storageError;
      _canRetrySessionRestore = false;
      _status = AuthStatus.signedOut;
      notifyListeners();
      return true;
    } on ApiException catch (error) {
      _setError(error.message);
      return false;
    }
  }

  void clearError() {
    if (_error != null) {
      _error = null;
      _canRetrySessionRestore = false;
      notifyListeners();
    }
  }

  Future<void> _runAuth(Future<AuthSession> Function() operation) async {
    _setBusy(true);
    try {
      if (!await _acceptSession(await operation())) {
        _setError(_storageError);
      }
    } on ApiException catch (error) {
      _setError(error.message);
    } on FormatException {
      _setError('The account service returned an invalid session.');
    } on Object {
      _setError('FinGuard could not complete sign-in. Try again.');
    } finally {
      if (_status != AuthStatus.authenticated) {
        _setBusy(false);
      }
    }
  }

  Future<bool> _acceptSession(AuthSession session) async {
    try {
      await _store.saveRefreshToken(session.refreshToken);
    } on Object {
      return false;
    }
    _session = session;
    _busy = false;
    _error = null;
    _canRetrySessionRestore = false;
    _status = AuthStatus.authenticated;
    notifyListeners();
    return true;
  }

  Future<void> _initializeGoogleIfAvailable() async {
    if (_googleInitialized) {
      return;
    }
    final String clientId = AppConfig.googleWebClientId.trim();
    final String serverClientId = AppConfig.googleAndroidServerClientId.trim();
    if (!_capabilities.google ||
        (kIsWeb ? clientId.isEmpty : serverClientId.isEmpty)) {
      return;
    }
    try {
      await _googleSignIn.initialize(
        clientId: kIsWeb ? clientId : null,
        serverClientId: kIsWeb ? null : serverClientId,
      );
      _googleSubscription = _googleSignIn.authenticationEvents.listen(
        _handleGoogleEvent,
        onError: (_) => _setError('Google sign-in could not be completed.'),
      );
      _googleInitialized = true;
    } on Object {
      _googleInitialized = false;
    }
  }

  Future<void> _handleGoogleEvent(GoogleSignInAuthenticationEvent event) async {
    if (event is! GoogleSignInAuthenticationEventSignIn) {
      return;
    }
    final String? idToken = event.user.authentication.idToken;
    if (idToken == null || idToken.isEmpty) {
      _setError('Google did not provide a verifiable identity token.');
      return;
    }
    await _runAuth(() => _api.googleLogin(idToken));
  }

  void _setBusy(bool value) {
    _busy = value;
    if (value) {
      _error = null;
      _canRetrySessionRestore = false;
    }
    notifyListeners();
  }

  void _setError(String message) {
    _busy = false;
    _error = message;
    _canRetrySessionRestore = false;
    notifyListeners();
  }

  void _finishSessionRestoreFailure(String message) {
    _session = null;
    _status = AuthStatus.signedOut;
    _busy = false;
    _error = message;
    _canRetrySessionRestore = true;
    notifyListeners();
  }

  void _finishSignedOut() {
    _session = null;
    _status = AuthStatus.signedOut;
    _busy = false;
    _error = null;
    _canRetrySessionRestore = false;
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_googleSubscription?.cancel());
    super.dispose();
  }
}
