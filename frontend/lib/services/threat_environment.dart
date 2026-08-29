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

/// Reads device-environment facts that raise payment risk.
///
/// This only ever observes FinGuard's own process at the moment of a check.
/// It does not run in the background and cannot see inside a UPI app, so it
/// protects payments routed through FinGuard, not payments made directly in
/// BHIM or Paytm.
abstract interface class ThreatEnvironment {
  Future<List<String>> remoteAccessTools();
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
}

final class NoopThreatEnvironment implements ThreatEnvironment {
  const NoopThreatEnvironment();

  @override
  Future<List<String>> remoteAccessTools() async => const <String>[];
}
