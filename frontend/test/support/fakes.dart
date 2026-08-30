import 'dart:async';
import 'dart:typed_data';
import 'dart:ui';

import 'package:finguard/models/auth_session.dart';
import 'package:finguard/models/context_analysis.dart';
import 'package:finguard/models/identifier_check.dart';
import 'package:finguard/models/intent_shield.dart';
import 'package:finguard/models/payee_trust.dart';
import 'package:finguard/models/payment.dart';
import 'package:finguard/models/policy_card.dart';
import 'package:finguard/models/risk.dart';
import 'package:finguard/models/risk_explanation.dart';
import 'package:finguard/services/api_service.dart';
import 'package:finguard/services/auth_api.dart';
import 'package:finguard/services/auth_store.dart';
import 'package:finguard/services/external_actions.dart';
import 'package:finguard/services/share_intake.dart';
import 'package:finguard/services/threat_environment.dart';

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
  CallActivity lastCallActivity = CallActivity.none;
  PaymentIntent? lastIntent;
  String? lastTrustLookupVpa;
  int trustLookupCount = 0;
  PayeeTrust? trustLookupResult;
  ApiException? trustLookupError;
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

  int identifierCheckCount = 0;
  String? lastIdentifierChecked;
  IdentifierCheck? identifierCheckResult;

  @override
  Future<IdentifierCheck> checkIdentifier(String value) async {
    identifierCheckCount += 1;
    lastIdentifierChecked = value;
    // The screen reaches the trust report through this call now, so the same
    // knobs the lookup tests already use must drive it: a test that pins a
    // grade should not have to know which endpoint the screen happens to call.
    trustLookupCount += 1;
    lastTrustLookupVpa = value.trim().toLowerCase();
    final ApiException? error = trustLookupError;
    if (error != null) {
      throw error;
    }
    final IdentifierCheck? canned = identifierCheckResult;
    if (canned != null) {
      return canned;
    }
    final String vpa = value.trim().toLowerCase();
    final PayeeTrust trust =
        trustLookupResult ?? PayeeTrust.fromApiJson(payeeTrustJson(vpa: vpa));
    return IdentifierCheck(
      kind: IdentifierKind.upiId,
      value: trust.vpa,
      addresses: <CheckedAddress>[
        CheckedAddress(
          vpa: trust.vpa,
          trust: trust,
          knownToNetwork: !trust.thinFile,
        ),
      ],
      addressesExamined: 1,
      summary: '${trust.headline}.',
    );
  }

  int policyCardCount = 0;

  @override
  Future<PolicyCard> fetchPolicyCard() async {
    policyCardCount += 1;
    return PolicyCard.fromApiJson(policyCardJson());
  }

  @override
  Future<PayeeTrust> lookupPayeeTrust(String vpa) async {
    trustLookupCount += 1;
    lastTrustLookupVpa = vpa;
    final ApiException? error = trustLookupError;
    if (error != null) {
      throw error;
    }
    return trustLookupResult ??
        PayeeTrust.fromApiJson(payeeTrustJson(vpa: vpa.trim().toLowerCase()));
  }

  @override
  Future<RiskScoreResult> scorePayment({
    required Payment payment,
    required String deviceId,
    ContextAnalysis? context,
    List<String> remoteAccessTools = const <String>[],
    CallActivity callActivity = CallActivity.none,
    PaymentIntent? intent,
  }) async {
    lastIntent = intent;
    lastScoreContext = context;
    lastRemoteAccessTools = remoteAccessTools;
    lastCallActivity = callActivity;
    return RiskScoreResult.fromApiJson(<String, Object?>{
      'assessment_id': 'test-assessment-1',
      'transaction_id': 'test-transaction-1',
      'payment': payment.toApiJson(),
      'payee_trust': payeeTrustJson(vpa: payment.payeeVpa),
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
  int suspectRegistryOpenCount = 0;
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
  Future<void> openSuspectRegistry() async {
    suspectRegistryOpenCount += 1;
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

/// A trust report fixture shaped exactly like the server envelope, so a
/// change to the model's validation fails these tests rather than passing
/// them on a hand-relaxed map.
Map<String, Object?> payeeTrustJson({
  String vpa = 'merchant@upi',
  String grade = 'NEW',
  int? score,
  bool thinFile = true,
  bool impersonation = false,
  int checkCount = 0,
  int distinctDeviceCount = 0,
  int reportedCount = 0,
  int observedDays = 0,
}) => <String, Object?>{
  'vpa': vpa,
  'score': score,
  'grade': grade,
  'headline': 'No track record yet: treat this as a stranger',
  'thin_file': thinFile,
  'impersonation': impersonation,
  'confidence': thinFile ? 'LOW' : 'HIGH',
  'pillars': <Object?>[
    <String, Object?>{
      'code': 'IDENTITY',
      'label': 'Address identity',
      'points': 28,
      'maximum': 30,
      'status': 'STRONG',
      'evidence': 'The address structure raised none of the checks applied to it.',
    },
    <String, Object?>{
      'code': 'TENURE',
      'label': 'How long the network has known it',
      'points': thinFile ? 0 : 25,
      'maximum': 25,
      'status': thinFile ? 'NO_DATA' : 'STRONG',
      'evidence': 'Fixture tenure evidence.',
    },
  ],
  'assessed_points': thinFile ? 28 : 53,
  'assessable_maximum': thinFile ? 30 : 55,
  'first_seen_at': thinFile ? null : '2025-01-01T00:00:00Z',
  'observed_days': observedDays,
  'check_count': checkCount,
  'distinct_device_count': distinctDeviceCount,
  'reported_count': reportedCount,
  'disclaimer':
      'FinGuard network reputation, not an NPCI, bank, or credit bureau rating.',
};

final class FakeThreatEnvironment implements ThreatEnvironment {
  FakeThreatEnvironment({
    this.tools = const <String>[],
    this.call = CallActivity.none,
    this.permissionGranted = false,
    this.grantOnRequest = true,
  });

  List<String> tools;
  CallActivity call;
  bool permissionGranted;
  bool grantOnRequest;
  int permissionRequestCount = 0;

  @override
  Future<List<String>> remoteAccessTools() async => tools;

  @override
  Future<CallActivity> callActivity() async => call;

  @override
  Future<bool> hasCallStatePermission() async => permissionGranted;

  @override
  Future<bool> requestCallStatePermission() async {
    permissionRequestCount += 1;
    permissionGranted = grantOnRequest;
    return permissionGranted;
  }
}


Map<String, Object?> policyCardJson() => <String, Object?>{
  'policy_version': 'test-1',
  'bands': <Object?>[
    <String, Object?>{
      'name': 'SAFE',
      'minimum': 0,
      'maximum': 29,
      'meaning': 'Nothing strong enough to interrupt.',
    },
    <String, Object?>{
      'name': 'CAUTION',
      'minimum': 30,
      'maximum': 69,
      'meaning': 'Worth confirming before paying.',
    },
    <String, Object?>{
      'name': 'HIGH',
      'minimum': 70,
      'maximum': 100,
      'meaning': 'Stop and verify independently.',
    },
  ],
  'signals': <Object?>[
    <String, Object?>{
      'field': 'remote_access_tool',
      'title': 'A remote-access app is installed',
      'points': 25,
      'rationale': 'Screen-sharing tools let a caller drive the payment.',
      'source_category': 'NPCI_ADVISORY',
      'source_link': 'https://www.npci.org.in/fraud-awareness',
    },
    <String, Object?>{
      'field': 'first_time_payee',
      'title': 'First payment to this address',
      'points': 18,
      'rationale': 'Read from this device history.',
      'source_category': 'FINGUARD_POLICY',
      'source_link': '',
    },
  ],
  'limitations': <Object?>['FinGuard cannot see your bank account.'],
  'calibration_statement':
      'Official guidance supports the risk factor, not the exact numeric '
      "points. FinGuard's points are deterministic intervention values and "
      'are not statistically calibrated fraud probabilities.',
};
