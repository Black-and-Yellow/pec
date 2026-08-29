import 'dart:async';
import 'dart:typed_data';
import 'dart:ui';

import 'package:finguard/models/auth_session.dart';
import 'package:finguard/models/context_analysis.dart';
import 'package:finguard/models/payment.dart';
import 'package:finguard/models/risk.dart';
import 'package:finguard/models/risk_explanation.dart';
import 'package:finguard/services/api_service.dart';
import 'package:finguard/services/auth_api.dart';
import 'package:finguard/services/auth_store.dart';
import 'package:finguard/services/external_actions.dart';
import 'package:finguard/services/share_intake.dart';

final class FakeApi implements FinGuardApi {
  FakeApi({
    this.contextAvailable = true,
    this.contextError,
    this.analyzeContextGate,
    this.parsePaymentGate,
    this.explanationResult,
  });

  final bool contextAvailable;
  final ApiException? contextError;
  final Future<void>? analyzeContextGate;
  final Future<void>? parsePaymentGate;
  final RiskExplanation? explanationResult;
  ContextAnalysis? lastScoreContext;
  List<String> lastRemoteAccessTools = const <String>[];
  int analyzeContextCount = 0;
  int parsePaymentCount = 0;
  String? lastParsedPayment;
  int prepareResponseCount = 0;
  int explainAssessmentCount = 0;
  bool? lastExplanationConsent;

  @override
  Future<ContextAnalysis> analyzeContext({
    required bool consentToExternalAi,
    String? text,
    Uint8List? screenshotBytes,
    String? screenshotMimeType,
  }) async {
    analyzeContextCount += 1;
    await analyzeContextGate;
    final ApiException? error = contextError;
    if (error != null) {
      throw error;
    }
    return ContextAnalysis.fromJson(<String, Object?>{
      'available': contextAvailable,
      'source': contextAvailable ? 'gemini' : 'local_rules',
      'context_token': 'test-server-context-token',
      'context': <String, Object?>{
        'impersonation': false,
        'urgency': true,
        'kyc_threat': false,
        'reward_or_refund_claim': false,
        'payment_requested': false,
        'suspicious_support_claim': false,
        'confidence': 0.9,
      },
    }, sourceText: text ?? '');
  }

  @override
  Future<Payment> parsePayment(String upiUri) async {
    parsePaymentCount += 1;
    lastParsedPayment = upiUri;
    await parsePaymentGate;
    return Payment(
      upiUri: upiUri,
      payeeVpa: 'merchant@upi',
      payeeName: 'Merchant',
      amount: 100,
      currency: 'INR',
    );
  }

  @override
  Future<RiskExplanation> explainAssessment({
    required String assessmentId,
    required bool consent,
  }) async {
    explainAssessmentCount += 1;
    lastExplanationConsent = consent;
    return explanationResult ??
        const RiskExplanation(
          available: true,
          source: RiskExplanationSource.template,
          status: 'ai_disabled',
          explanation: 'Server template explanation.',
        );
  }

  @override
  Future<String> prepareResponse({
    required Payment payment,
    required RiskAssessment assessment,
    required bool alreadyPaid,
    ContextAnalysis? context,
  }) async {
    prepareResponseCount += 1;
    return 'Prepared report for ${payment.payeeVpa}';
  }

  @override
  Future<RiskScoreResult> scorePayment({
    required Payment payment,
    required String deviceId,
    ContextAnalysis? context,
    List<String> remoteAccessTools = const <String>[],
  }) async {
    lastScoreContext = context;
    lastRemoteAccessTools = remoteAccessTools;
    return RiskScoreResult.fromApiJson(<String, Object?>{
      'assessment_id': 'test-assessment-1',
      'transaction_id': 'test-transaction-1',
      'payment': payment.toApiJson(),
      'score': 10,
      'level': 'SAFE',
      'signals': <Object?>[
        <String, Object?>{
          'code': 'TEST',
          'label': 'Test signal',
          'weight': 10,
          'evidence': 'Fixture evidence',
        },
      ],
      'recommended_action': 'Verify and continue.',
      'requires_confirmation': false,
      'handoff_policy': 'NORMAL',
      'assessed_at': '2026-08-12T10:00:00Z',
    }, requestedPayment: payment);
  }
}

final class FakeShareIntake implements ShareIntake {
  FakeShareIntake({String? initialText}) : _initialText = initialText;

  String? _initialText;
  final StreamController<String> _shares = StreamController<String>.broadcast();

  @override
  Future<String?> initialShare() async {
    final String? shared = _initialText;
    _initialText = null;
    return shared;
  }

  @override
  Stream<String> shares() => _shares.stream;

  void emit(String text) => _shares.add(text);

  Future<void> close() => _shares.close();
}

final class FakeExternalActions implements ExternalActions {
  int upiOpenCount = 0;
  int portalOpenCount = 0;
  int shareCount = 0;
  int messageTrustedContactCount = 0;
  int dialerOpenCount = 0;
  String? messagedPhone;
  String? messagedText;
  String? dialedUri;
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
  Future<void> messageTrustedContact(String phoneDigits, String message) async {
    messageTrustedContactCount += 1;
    messagedPhone = phoneDigits;
    messagedText = message;
  }

  @override
  Future<void> openDialer(String telUri) async {
    dialerOpenCount += 1;
    dialedUri = telUri;
  }

  @override
  Future<void> shareTrustedContact(String message, {Rect? origin}) async {
    shareCount += 1;
  }
}

final class MemoryAuthStore implements AuthStore {
  MemoryAuthStore({
    this.failReadRefresh = false,
    this.failReadGuest = false,
    this.failSaveRefresh = false,
    this.failSaveGuest = false,
    this.failClear = false,
  });

  String? refreshToken;
  bool guestMode = false;
  final bool failReadRefresh;
  final bool failReadGuest;
  final bool failSaveRefresh;
  final bool failSaveGuest;
  final bool failClear;

  @override
  Future<void> clear() async {
    if (failClear) {
      throw StateError('secure storage clear failed');
    }
    refreshToken = null;
    guestMode = false;
  }

  @override
  Future<bool> readGuestMode() async {
    if (failReadGuest) {
      throw StateError('secure storage guest read failed');
    }
    return guestMode;
  }

  @override
  Future<String?> readRefreshToken() async {
    if (failReadRefresh) {
      throw StateError('secure storage token read failed');
    }
    return refreshToken;
  }

  @override
  Future<void> saveGuestMode(bool value) async {
    if (failSaveGuest) {
      throw StateError('secure storage guest write failed');
    }
    guestMode = value;
    if (value) {
      refreshToken = null;
    }
  }

  @override
  Future<void> saveRefreshToken(String value) async {
    if (failSaveRefresh) {
      throw StateError('secure storage token write failed');
    }
    refreshToken = value;
    guestMode = false;
  }
}

final class FakeAuthApi implements FinGuardAuthApi {
  FakeAuthApi({this.refreshError});

  int refreshCount = 0;
  int logoutCount = 0;
  int deleteCount = 0;
  ApiException? refreshError;

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
    final ApiException? error = refreshError;
    if (error != null) {
      throw error;
    }
    return session;
  }

  @override
  Future<AuthSession> register({
    required String email,
    required String password,
    required String displayName,
  }) async => session;
}
