import 'payee_trust.dart';

/// What the server decided a pasted string actually was.
enum IdentifierKind {
  upiLink('UPI_LINK', 'Payment link'),
  upiId('UPI_ID', 'UPI ID'),
  mobile('MOBILE', 'Mobile number'),
  unsupported('UNSUPPORTED', 'Not recognised');

  const IdentifierKind(this.apiValue, this.label);

  final String apiValue;
  final String label;

  static IdentifierKind fromApi(Object? value) => switch (value) {
    'UPI_LINK' => IdentifierKind.upiLink,
    'UPI_ID' => IdentifierKind.upiId,
    'MOBILE' => IdentifierKind.mobile,
    'UNSUPPORTED' => IdentifierKind.unsupported,
    _ => throw const FormatException('Unknown identifier kind in response.'),
  };
}

/// One address that was actually looked up, and what came back.
final class CheckedAddress {
  const CheckedAddress({
    required this.vpa,
    required this.trust,
    required this.knownToNetwork,
  });

  final String vpa;
  final PayeeTrust trust;
  final bool knownToNetwork;

  static CheckedAddress fromApiJson(Map<String, Object?> json) {
    final Object? vpa = json['vpa'];
    final Object? trust = json['trust'];
    if (vpa is! String || trust is! Map<String, Object?>) {
      throw const FormatException('A checked address is malformed.');
    }
    return CheckedAddress(
      vpa: vpa,
      trust: PayeeTrust.fromApiJson(trust),
      knownToNetwork: json['known_to_network'] == true,
    );
  }
}

/// The answer to "what is this thing, and what does the network know about it".
final class IdentifierCheck {
  const IdentifierCheck({
    required this.kind,
    required this.value,
    required this.addresses,
    required this.addressesExamined,
    required this.summary,
    this.reason,
  });

  final IdentifierKind kind;

  /// The cleaned input: a normalised UPI ID, ten digits, or the original link.
  final String value;

  /// Only the addresses the network actually knows. For a mobile number this
  /// is usually shorter than [addressesExamined], and often empty.
  final List<CheckedAddress> addresses;

  final int addressesExamined;
  final String summary;

  /// Why an input could not be used. Present only when [kind] is unsupported.
  final String? reason;

  /// The single report to lead with, when there is exactly one thing to show.
  PayeeTrust? get primaryTrust =>
      addresses.length == 1 ? addresses.first.trust : null;

  static IdentifierCheck fromApiJson(Map<String, Object?> json) {
    final Object? value = json['value'];
    final Object? summary = json['summary'];
    final Object? rawAddresses = json['addresses'];
    if (value is! String || summary is! String || rawAddresses is! List<Object?>) {
      throw const FormatException('The identifier check response is malformed.');
    }
    final Object? examined = json['addresses_examined'];
    final Object? reason = json['reason'];
    return IdentifierCheck(
      kind: IdentifierKind.fromApi(json['kind']),
      value: value,
      addresses: <CheckedAddress>[
        for (final Object? entry in rawAddresses)
          if (entry is Map<String, Object?>)
            CheckedAddress.fromApiJson(entry)
          else
            throw const FormatException('A checked address is malformed.'),
      ],
      addressesExamined: examined is int ? examined : 0,
      summary: summary,
      reason: reason is String && reason.isNotEmpty ? reason : null,
    );
  }
}
