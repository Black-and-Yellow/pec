import '../models/context_analysis.dart';
import '../models/payment.dart';
import '../models/risk.dart';

abstract final class ReportBuilder {
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
        'Status: ${alreadyPaid ? 'Payment may have been completed' : 'Payment stopped before handoff'}',
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
    if (context != null && context.sourceText.isNotEmpty) {
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
      'I ${assessment.level == RiskLevel.highRisk ? 'stopped' : 'paused'} a suspicious '
      'UPI payment to ${payment.payeeVpa}. FinGuard showed '
      '${assessment.level.label} (${assessment.score}/100) with '
      '${assessment.signals.length} risk signal${assessment.signals.length == 1 ? '' : 's'}. '
      'Please contact me before I continue.';

  static String _weight(int value) => value > 0 ? '+$value' : '$value';
}
