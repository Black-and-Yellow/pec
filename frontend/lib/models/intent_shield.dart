/// What the user said they expect this request to do.
///
/// Collected before analysis and compared against what the request actually
/// does. It never contributes to the risk score: a mismatch says the person
/// was told something untrue, not that the payee is a fraudster, and a
/// self-reported belief must never be able to brand somebody's address.
enum PaymentIntent {
  sendMoney('SEND_MONEY', 'I expect to send money'),
  receiveMoney('RECEIVE_MONEY', 'I expect to receive money'),
  refundOrReward('REFUND_OR_REWARD', 'I was promised a refund or reward'),
  verifyKyc('VERIFY_KYC_OR_ACCOUNT', 'I was told this verifies KYC or account access'),
  inspectOnly('INSPECT_ONLY', 'I only want to inspect this request');

  const PaymentIntent(this.apiValue, this.label);

  final String apiValue;
  final String label;
}

/// The comparison result, reported alongside the score but never inside it.
final class IntentShield {
  const IntentShield({
    required this.intent,
    required this.mismatched,
    this.headline,
    this.detail,
    this.rule,
  });

  final String intent;
  final bool mismatched;
  final String? headline;
  final String? detail;
  final String? rule;

  static IntentShield? fromApiJson(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is! Map<String, Object?>) {
      throw const FormatException('The intent shield payload is malformed.');
    }
    final Object? intent = value['intent'];
    if (intent is! String) {
      throw const FormatException('The intent shield payload is malformed.');
    }
    String? text(Object? raw) =>
        raw is String && raw.trim().isNotEmpty ? raw : null;
    return IntentShield(
      intent: intent,
      mismatched: value['mismatched'] == true,
      headline: text(value['headline']),
      detail: text(value['detail']),
      rule: text(value['rule']),
    );
  }
}
