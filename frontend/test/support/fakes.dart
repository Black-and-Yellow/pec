import 'dart:typed_data';
import 'dart:ui';

import 'package:finguard/models/auth_session.dart';
import 'package:finguard/models/context_analysis.dart';
import 'package:finguard/models/payment.dart';
import 'package:finguard/models/risk.dart';
import 'package:finguard/services/api_service.dart';
import 'package:finguard/services/auth_api.dart';
import 'package:finguard/services/auth_store.dart';
import 'package:finguard/services/external_actions.dart';

final class FakeApi implements FinGuardApi {
  FakeApi({this.contextAvailable = true});

  final bool contextAvailable;

  @override
  Future<ContextAnalysis> analyzeContext({
    required bool consentToExternalAi,
    String? text,
    Uint8List? screenshotBytes,
    String? screenshotMimeType,
  }) async => ContextAnalysis(
    available: contextAvailable,
    sourceText: text ?? '',
    flags: const <String, bool>{'urgency': true},
    confidence: 0.9,
    source: contextAvailable
        ? ContextAnalysisSource.gemini
        : ContextAnalysisSource.localRules,
  );

  @override
  Future<Payment> parsePayment(String upiUri) async => Payment(
    upiUri: upiUri,
    payeeVpa: 'merchant@upi',
    payeeName: 'Merchant',
    amount: 100,
    currency: 'INR',
  );

  @override
  Future<String> prepareResponse({
    required Payment payment,
    required RiskAssessment assessment,
    required bool alreadyPaid,
    ContextAnalysis? context,
  }) async => 'Prepared report for ${payment.payeeVpa}';

  @override
  Future<RiskAssessment> scorePayment({
    required Payment payment,
    required String deviceId,
    ContextAnalysis? context,
  }) async => const RiskAssessment(
    score: 10,
    level: RiskLevel.safe,
    signals: <RiskSignal>[
      RiskSignal(
        code: 'TEST',
        label: 'Test signal',
        weight: 10,
        evidence: 'Fixture evidence',
      ),
    ],
    recommendedAction: 'Verify and continue.',
  );
}

final class FakeExternalActions implements ExternalActions {
  int upiOpenCount = 0;
  int portalOpenCount = 0;
  int shareCount = 0;
  String? copiedText;

  @override
  Future<void> copyText(String text) async {
    copiedText = text;
  }

  @override
  Future<void> openCybercrimePortal() async {
    portalOpenCount += 1;
  }

  @override
  Future<void> openUpi(String rawUri) async {
    Payment.validateUpiUri(rawUri);
    upiOpenCount += 1;
  }

  @override
  Future<void> shareTrustedContact(String message, {Rect? origin}) async {
    shareCount += 1;
  }
}

final class MemoryAuthStore implements AuthStore {
  String? refreshToken;
  bool guestMode = false;

  @override
  Future<void> clear() async {
    refreshToken = null;
    guestMode = false;
  }

  @override
  Future<bool> readGuestMode() async => guestMode;

  @override
  Future<String?> readRefreshToken() async => refreshToken;

  @override
  Future<void> saveGuestMode(bool value) async {
    guestMode = value;
    if (value) {
      refreshToken = null;
    }
  }

  @override
  Future<void> saveRefreshToken(String value) async {
    refreshToken = value;
    guestMode = false;
  }
}

final class FakeAuthApi implements FinGuardAuthApi {
  int refreshCount = 0;
  int logoutCount = 0;
  int deleteCount = 0;

  AuthSession get session => AuthSession(
    accessToken: 'a' * 120,
    refreshToken: 'r' * 64,
    expiresIn: 900,
    user: AuthUser(
      id: 'user-1',
      email: 'person@example.com',
      displayName: 'Test Person',
      authProvider: 'password',
      createdAt: DateTime.utc(2026),
    ),
  );

  @override
  Future<AuthCapabilities> capabilities() async =>
      const AuthCapabilities(emailPassword: true, google: false);

  @override
  Future<void> deleteAccount({
    required String accessToken,
    String? password,
  }) async {
    deleteCount += 1;
  }

  @override
  Future<AuthSession> googleLogin(String idToken) async => session;

  @override
  Future<AuthSession> login({
    required String email,
    required String password,
  }) async => session;

  @override
  Future<void> logout(String refreshToken) async {
    logoutCount += 1;
  }

  @override
  Future<AuthSession> refresh(String refreshToken) async {
    refreshCount += 1;
    return session;
  }

  @override
  Future<AuthSession> register({
    required String email,
    required String password,
    required String displayName,
  }) async => session;
}
