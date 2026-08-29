import '../models/context_analysis.dart';
import '../models/payment.dart';
import '../models/risk.dart';

abstract final class ReportBuilder {
  static const Map<String, String> _signalPhrases = <String, String>{
    'SEEDED_FRAUD_MATCH':
        'this recipient appears in FinGuard\'s labelled scam indicator list',
    'FIRST_TIME_PAYEE': 'you have never paid this recipient from this device',
    'AMOUNT_NOT_SPECIFIED': 'the request lets the amount be filled in later',
    'UNUSUAL_AMOUNT': 'the amount is much larger than your usual payments',
    'SUSPICIOUS_PAYMENT_NOTE': 'the payment note uses pressure or KYC wording',
    'SEEDED_IDENTIFIER_RELATIONSHIP':
        'the recipient is linked to other reported identifiers',
    'CONTEXT_IMPERSONATION':
        'the message you supplied impersonates a trusted organisation',
    'CONTEXT_URGENCY': 'the message pressures you to act immediately',
    'CONTEXT_KYC_THREAT':
        'the message threatens to block your account over KYC',
    'CONTEXT_REWARD_OR_REFUND': 'the message promises a refund or reward',
    'CONTEXT_SUSPICIOUS_SUPPORT':
        'the message claims to be support you did not contact',
  };

  static String plainLanguageExplanation(RiskAssessment assessment) {
    if (assessment.level == RiskLevel.safe && assessment.signals.isEmpty) {
      return 'FinGuard found no warning signals in this request. A quiet result '
          'is not a guarantee that the recipient is genuine — check the name '
          'and amount in your UPI app before you pay.';
    }
    final List<RiskSignal> ranked = List<RiskSignal>.of(assessment.signals)
      ..sort(
        (RiskSignal left, RiskSignal right) =>
            right.weight.compareTo(left.weight),
      );
    final List<String> reasons = ranked
        .take(3)
        .map((RiskSignal signal) => _signalPhrases[signal.code])
        .whereType<String>()
        .toList(growable: false);
    final String joined = _joinReasons(
      reasons.isEmpty
          ? const <String>['the request triggered warning signals']
          : reasons,
    );
    final String closing = switch (assessment.level) {
      RiskLevel.safe =>
        ' Check the recipient name and amount in your UPI app before you pay.',
      RiskLevel.caution =>
        ' Verify the recipient independently before you continue.',
      RiskLevel.highRisk =>
        ' Do not pay until you have verified the recipient through a channel '
            'you already trust.',
    };
    return _truncate(
      'FinGuard rated this ${assessment.level.label} because $joined.$closing',
    );
  }

  static String build({
    required Payment payment,
    required RiskAssessment assessment,
    required DateTime occurredAt,
    required bool alreadyPaid,
    ContextAnalysis? context,
  }) {
    final StringBuffer report = StringBuffer()
      ..writeln('FinGuard incident summary')
      ..writeln('Prepared: ${occurredAt.toLocal().toIso8601String()}')
      ..writeln(
        'Status: ${alreadyPaid ? 'The user indicated that a payment may have occurred. FinGuard cannot verify payment status.' : 'FinGuard displayed a pre-payment warning. FinGuard cannot verify whether a payment occurred.'}',
      )
      ..writeln('Recipient: ${payment.recipientLabel} (${payment.payeeVpa})')
      ..writeln('Amount: ${payment.formattedAmount}')
      ..writeln('Risk: ${assessment.level.label} — ${assessment.score}/100');

    if ((payment.transactionReference ?? '').isNotEmpty) {
      report.writeln('Reference: ${payment.transactionReference}');
    }
    if ((payment.note ?? '').isNotEmpty) {
      report.writeln('Payment note: ${payment.note}');
    }
    if (context?.hasValidatedContext == true &&
        context!.sourceText.isNotEmpty) {
      report
        ..writeln()
        ..writeln('Supplied message:')
        ..writeln(context.sourceText);
    }
    report
      ..writeln()
      ..writeln('Detected signals:');
    for (final RiskSignal signal in assessment.signals) {
      report.writeln(
        '- ${signal.label} (${_weight(signal.weight)}): ${signal.evidence}',
      );
    }
    report
      ..writeln()
      ..writeln('Recommended next step: ${assessment.recommendedAction}')
      ..writeln()
      ..write(
        'This is a user-prepared draft from a pre-payment safety check. '
        'FinGuard did not submit a complaint or access bank transaction systems.',
      );
    return report.toString();
  }

  static String trustedContactMessage(
    Payment payment,
    RiskAssessment assessment,
  ) =>
      'FinGuard displayed a pre-payment warning for a UPI request to '
      '${payment.payeeVpa}: '
      '${assessment.level.label} (${assessment.score}/100) with '
      '${assessment.signals.length} risk signal${assessment.signals.length == 1 ? '' : 's'}. '
      'FinGuard cannot verify whether any payment occurred. Please contact me '
      'before I take further action.';

  static String _weight(int value) => value > 0 ? '+$value' : '$value';

  static String _joinReasons(List<String> reasons) => switch (reasons.length) {
    1 => reasons.single,
    2 => '${reasons.first} and ${reasons.last}',
    _ =>
      '${reasons.sublist(0, reasons.length - 1).join(', ')} '
          'and ${reasons.last}',
  };

  static String _truncate(String value) {
    final String normalized = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.length <= 400) {
      return normalized;
    }
    final String candidate = normalized.substring(0, 400);
    final int boundary = candidate.lastIndexOf(' ');
    return boundary > 0 ? candidate.substring(0, boundary) : candidate;
  }
}
