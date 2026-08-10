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

  AuthStatus get status => _status;
  AuthUser? get user => _session?.user;
  String? get accessToken => _session?.accessToken;
  bool get busy => _busy;
  String? get error => _error;
  bool get googleEnabled => _capabilities.google && _googleInitialized;
  bool get emailPasswordEnabled => _capabilities.emailPassword;

  Future<void> initialize() async {
    _status = AuthStatus.loading;
    notifyListeners();
    try {
      _capabilities = await _api.capabilities();
    } on ApiException {
      _capabilities = const AuthCapabilities(
        emailPassword: true,
        google: false,
      );
    }
    await _initializeGoogleIfAvailable();
    final String? refreshToken = await _store.readRefreshToken();
    if (refreshToken != null && refreshToken.isNotEmpty) {
      try {
        await _acceptSession(await _api.refresh(refreshToken));
        return;
      } on Object {
        await _store.clear();
      }
    }
    _status = await _store.readGuestMode()
        ? AuthStatus.guest
        : AuthStatus.signedOut;
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
    await _store.saveGuestMode(true);
    _session = null;
    _error = null;
    _status = AuthStatus.guest;
    notifyListeners();
  }

  Future<void> leaveGuestMode() async {
    await _store.saveGuestMode(false);
    _status = AuthStatus.signedOut;
    _error = null;
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
    await _store.clear();
    _session = null;
    _busy = false;
    _error = null;
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
      await _store.clear();
      _session = null;
      _busy = false;
      _error = null;
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
      notifyListeners();
    }
  }

  Future<void> _runAuth(Future<AuthSession> Function() operation) async {
    _setBusy(true);
    try {
      await _acceptSession(await operation());
    } on ApiException catch (error) {
      _setError(error.message);
    } on FormatException {
      _setError('The account service returned an invalid session.');
    } finally {
      if (_status != AuthStatus.authenticated) {
        _setBusy(false);
      }
    }
  }

  Future<void> _acceptSession(AuthSession session) async {
    await _store.saveRefreshToken(session.refreshToken);
    _session = session;
    _busy = false;
    _error = null;
    _status = AuthStatus.authenticated;
    notifyListeners();
  }

  Future<void> _initializeGoogleIfAvailable() async {
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
    }
    notifyListeners();
  }

  void _setError(String message) {
    _busy = false;
    _error = message;
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_googleSubscription?.cancel());
    super.dispose();
  }
}
