import 'package:flutter/services.dart';

/// Identifiers the backend risk policy accepts. The client filters against
/// this set so an unexpected platform value can never reach `/risk/score`
/// and fail schema validation, which would block the whole safety check.
const Set<String> knownRemoteAccessTools = <String>{
  'ANYDESK',
  'TEAMVIEWER',
  'RUSTDESK',
  'AIRDROID',
  'OTHER',
};

/// Whether a call was in progress at the moment a check started.
///
/// This is a single synchronous reading taken when the user runs a check, not
/// a subscription. FinGuard cannot see a call that begins after a result is
/// already on screen, and it never observes who is calling.
enum CallActivity {
  none('NONE'),
  cellular('CELLULAR'),
  voiceOverIp('VOICE_OVER_IP'),
  ringing('RINGING'),
  unknown('UNKNOWN');

  const CallActivity(this.apiValue);

  final String apiValue;

  bool get isActive =>
      this == CallActivity.cellular ||
      this == CallActivity.voiceOverIp ||
      this == CallActivity.unknown;

  static CallActivity fromPlatform(String? value) =>
      switch (value) {
        'CELLULAR' => CallActivity.cellular,
        'VOICE_OVER_IP' => CallActivity.voiceOverIp,
        'RINGING' => CallActivity.ringing,
        'UNKNOWN' => CallActivity.unknown,
        _ => CallActivity.none,
      };
}

/// Reads device-environment facts that raise payment risk.
///
/// This only ever observes FinGuard's own process at the moment of a check.
/// It does not run in the background and cannot see inside a UPI app, so it
/// protects payments routed through FinGuard, not payments made directly in
/// BHIM or Paytm.
abstract interface class ThreatEnvironment {
  Future<List<String>> remoteAccessTools();

  /// Reads the current call state. Never prompts.
  Future<CallActivity> callActivity();

  /// Whether the optional telephony permission has been granted.
  Future<bool> hasCallStatePermission();

  /// Shows the system permission prompt. Only ever called from an explicit
  /// user action in settings, never in the middle of a payment check.
  Future<bool> requestCallStatePermission();
}

final class PlatformThreatEnvironment implements ThreatEnvironment {
  const PlatformThreatEnvironment();

  static const MethodChannel _channel = MethodChannel('org.pec.finguard/threat');

  @override
  Future<List<String>> remoteAccessTools() async {
    try {
      final List<Object?>? detected = await _channel.invokeMethod<List<Object?>>(
        'detectRemoteAccessTools',
      );
      if (detected == null) {
        return const <String>[];
      }
      return detected
          .whereType<String>()
          .where(knownRemoteAccessTools.contains)
          .toSet()
          .toList(growable: false);
    } on Object {
      // Detection is an enhancement; failure degrades to the ordinary check.
      return const <String>[];
    }
  }

  @override
  Future<CallActivity> callActivity() async {
    try {
      final String? state = await _channel.invokeMethod<String>(
        'readCallActivity',
      );
      return CallActivity.fromPlatform(state);
    } on Object {
      // Reporting "no call" is the safe failure: it can only under-report,
      // and an unreadable call state must never block a safety result.
      return CallActivity.none;
    }
  }

  @override
  Future<bool> hasCallStatePermission() async {
    try {
      return await _channel.invokeMethod<bool>('hasCallStatePermission') ??
          false;
    } on Object {
      return false;
    }
  }

  @override
  Future<bool> requestCallStatePermission() async {
    try {
      return await _channel.invokeMethod<bool>('requestCallStatePermission') ??
          false;
    } on Object {
      return false;
    }
  }
}

final class NoopThreatEnvironment implements ThreatEnvironment {
  const NoopThreatEnvironment();

  @override
  Future<List<String>> remoteAccessTools() async => const <String>[];

  @override
  Future<CallActivity> callActivity() async => CallActivity.none;

  @override
  Future<bool> hasCallStatePermission() async => false;

  @override
  Future<bool> requestCallStatePermission() async => false;
}
