import 'package:flutter/material.dart';

import '../models/context_analysis.dart';
import '../models/payment.dart';
import '../models/risk.dart';
import '../services/api_service.dart';
import '../services/app_services.dart';
import '../services/report_builder.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import 'incident_screen.dart';

class RiskResultScreen extends StatefulWidget {
  const RiskResultScreen({
    required this.services,
    required this.payment,
    required this.assessment,
    super.key,
    this.contextAnalysis,
    this.isDemo = false,
  });

  final AppServices services;
  final Payment payment;
  final RiskAssessment assessment;
  final ContextAnalysis? contextAnalysis;
  final bool isDemo;

  @override
  State<RiskResultScreen> createState() => _RiskResultScreenState();
}

class _RiskResultScreenState extends State<RiskResultScreen> {
  bool _preparingReport = false;

  @override
  Widget build(BuildContext context) {
    final bool wide = MediaQuery.sizeOf(context).width >= 900;
    final Widget result = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _ResultHeader(assessment: widget.assessment, isDemo: widget.isDemo),
        const SizedBox(height: 26),
        _PaymentDetails(payment: widget.payment),
        const SizedBox(height: 28),
        _SignalList(assessment: widget.assessment),
      ],
    );
    final Widget actions = _ActionPanel(
      assessment: widget.assessment,
      preparingReport: _preparingReport,
      onStop: _stopHere,
      onContinue: _continue,
      onVerify: _showVerificationGuidance,
      onPrepareReport: () => _prepareReport(alreadyPaid: false),
      onShare: _shareTrustedContact,
      onAlreadyPaid: () => _prepareReport(alreadyPaid: true),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Risk result'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Close result',
            onPressed: _stopHere,
            icon: const Icon(Icons.close),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: PageBody(
        maxWidth: 1080,
        child: wide
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(flex: 7, child: result),
                  const SizedBox(width: 36),
                  Expanded(flex: 4, child: actions),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[result, const SizedBox(height: 28), actions],
              ),
      ),
    );
  }

  void _stopHere() {
    Navigator.of(context).popUntil((Route<Object?> route) => route.isFirst);
  }

  Future<void> _continue() async {
    final RiskLevel level = widget.assessment.level;
    final bool confirmed = await confirmAction(
      context,
      title: switch (level) {
        RiskLevel.safe => 'Open this request in a UPI app?',
        RiskLevel.caution => 'Continue with caution?',
        RiskLevel.highRisk => 'Continue despite high risk?',
      },
      message: switch (level) {
        RiskLevel.safe =>
          'FinGuard will hand the validated request to a UPI app. Review the recipient and amount there before authorizing anything.',
        RiskLevel.caution =>
          'Verify the recipient independently first. Continuing will open your UPI app, where you remain responsible for reviewing and authorizing payment.',
        RiskLevel.highRisk =>
          'FinGuard found strong warning signals. Continuing will hand this request to a UPI app; FinGuard cannot stop or reverse a payment made there.',
      },
      confirmLabel: level == RiskLevel.safe
          ? 'Open UPI app'
          : 'Open UPI app anyway',
      isDanger: level == RiskLevel.highRisk,
    );
    if (!confirmed || !mounted) {
      return;
    }
    try {
      await widget.services.externalActions.openUpi(widget.payment.upiUri);
    } on Object catch (error) {
      if (mounted) {
        showActionError(context, error);
      }
    }
  }

  Future<void> _showVerificationGuidance() async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Check the recipient independently'),
        content: Text(
          'Confirm ${widget.payment.payeeVpa} using a phone number, website or in-person contact you already trust. Do not use contact details from the suspicious message.',
        ),
        actions: <Widget>[
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('I understand'),
          ),
        ],
      ),
    );
  }

  Future<void> _shareTrustedContact() async {
    final bool confirmed = await confirmAction(
      context,
      title: 'Open your share sheet?',
      message:
          'FinGuard will prepare a message with the recipient VPA and risk result. You choose the contact and must press Send yourself.',
      confirmLabel: 'Open share sheet',
    );
    if (!confirmed || !mounted) {
      return;
    }
    try {
      final RenderBox? box = context.findRenderObject() as RenderBox?;
      final Rect? origin = box == null
          ? null
          : box.localToGlobal(Offset.zero) & box.size;
      await widget.services.externalActions.shareTrustedContact(
        ReportBuilder.trustedContactMessage(widget.payment, widget.assessment),
        origin: origin,
      );
    } on Object catch (error) {
      if (mounted) {
        showActionError(context, error);
      }
    }
  }

  Future<void> _prepareReport({required bool alreadyPaid}) async {
    if (_preparingReport) {
      return;
    }
    final bool confirmed = await confirmAction(
      context,
      title: alreadyPaid
          ? 'Prepare a recovery draft?'
          : 'Prepare a private report draft?',
      message: alreadyPaid
          ? 'FinGuard will prepare incident details and recovery steps. Nothing is sent to a bank or government service.'
          : 'FinGuard will prepare a draft from the displayed payment and risk signals. Nothing is submitted or shared automatically.',
      confirmLabel: 'Prepare draft',
    );
    if (!confirmed || !mounted) {
      return;
    }
    setState(() => _preparingReport = true);
    bool preparedLocally = false;
    String report;
    try {
      report = await widget.services.api.prepareResponse(
        payment: widget.payment,
        assessment: widget.assessment,
        alreadyPaid: alreadyPaid,
        context: widget.contextAnalysis,
      );
    } on ApiException {
      preparedLocally = true;
      report = ReportBuilder.build(
        payment: widget.payment,
        assessment: widget.assessment,
        occurredAt: DateTime.now(),
        alreadyPaid: alreadyPaid,
        context: widget.contextAnalysis,
      );
    }
    if (!mounted) {
      return;
    }
    setState(() => _preparingReport = false);
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (BuildContext context) => IncidentScreen(
          services: widget.services,
          report: report,
          alreadyPaid: alreadyPaid,
          preparedLocally: preparedLocally,
        ),
      ),
    );
  }
}

class _ResultHeader extends StatelessWidget {
  const _ResultHeader({required this.assessment, required this.isDemo});

  final RiskAssessment assessment;
  final bool isDemo;

  @override
  Widget build(BuildContext context) {
    final String headline = switch (assessment.level) {
      RiskLevel.safe => 'No strong warning signal found',
      RiskLevel.caution => 'Pause and verify the recipient',
      RiskLevel.highRisk => 'Strong warning signals found',
    };
    return Semantics(
      header: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              RiskBadge(level: assessment.level),
              if (isDemo)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    border: Border.all(color: AppColors.border),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text('SEEDED DEMO DATA'),
                ),
            ],
          ),
          const SizedBox(height: 18),
          Text(headline, style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Text(
                '${assessment.score}',
                key: const Key('risk_score'),
                style: Theme.of(context).textTheme.displaySmall?.copyWith(
                  color: _statusColor(assessment.level),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 5),
                child: Text(
                  '/100 risk score',
                  style: Theme.of(
                    context,
                  ).textTheme.titleMedium?.copyWith(color: AppColors.inkMuted),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            assessment.recommendedAction,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        ],
      ),
    );
  }

  Color _statusColor(RiskLevel level) => switch (level) {
    RiskLevel.safe => AppColors.safe,
    RiskLevel.caution => AppColors.caution,
    RiskLevel.highRisk => AppColors.danger,
  };
}

class _PaymentDetails extends StatelessWidget {
  const _PaymentDetails({required this.payment});

  final Payment payment;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(vertical: 18),
    decoration: const BoxDecoration(
      border: Border.symmetric(horizontal: BorderSide(color: AppColors.border)),
    ),
    child: Wrap(
      spacing: 38,
      runSpacing: 18,
      children: <Widget>[
        _Detail(
          label: 'RECIPIENT',
          value: payment.recipientLabel,
          detail: payment.payeeVpa,
        ),
        _Detail(label: 'AMOUNT', value: payment.formattedAmount),
        if ((payment.note ?? '').isNotEmpty)
          _Detail(label: 'NOTE', value: payment.note!),
        if ((payment.transactionReference ?? '').isNotEmpty)
          _Detail(label: 'REFERENCE', value: payment.transactionReference!),
      ],
    ),
  );
}

class _Detail extends StatelessWidget {
  const _Detail({required this.label, required this.value, this.detail});

  final String label;
  final String value;
  final String? detail;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(minWidth: 150, maxWidth: 290),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: AppColors.inkMuted,
            letterSpacing: 1.1,
          ),
        ),
        const SizedBox(height: 5),
        Text(value, style: Theme.of(context).textTheme.titleMedium),
        if (detail != null) ...<Widget>[
          const SizedBox(height: 2),
          SelectableText(
            detail!,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: AppColors.inkMuted),
          ),
        ],
      ],
    ),
  );
}

class _SignalList extends StatelessWidget {
  const _SignalList({required this.assessment});

  final RiskAssessment assessment;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Text('Why this score', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 6),
      Text(
        'Each displayed weight is a deterministic input to the policy score. No AI assigns the final verdict.',
        style: Theme.of(
          context,
        ).textTheme.bodyMedium?.copyWith(color: AppColors.inkMuted),
      ),
      const SizedBox(height: 16),
      if (assessment.signals.isEmpty)
        Text(
          assessment.level == RiskLevel.safe
              ? 'The deterministic policy found no risk-raising signals in this request.'
              : 'No detailed signal was supplied for this assessment. Verify the request independently.',
        )
      else
        for (final RiskSignal signal in assessment.signals)
          _SignalRow(signal: signal),
    ],
  );
}

class _SignalRow extends StatelessWidget {
  const _SignalRow({required this.signal});

  final RiskSignal signal;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 18),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 48,
          child: Text(
            signal.weight > 0 ? '+${signal.weight}' : '${signal.weight}',
            textAlign: TextAlign.right,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: signal.weight > 0 ? AppColors.danger : AppColors.safe,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                signal.label,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 3),
              Text(
                signal.evidence,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: AppColors.inkMuted),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _ActionPanel extends StatelessWidget {
  const _ActionPanel({
    required this.assessment,
    required this.preparingReport,
    required this.onStop,
    required this.onContinue,
    required this.onVerify,
    required this.onPrepareReport,
    required this.onShare,
    required this.onAlreadyPaid,
  });

  final RiskAssessment assessment;
  final bool preparingReport;
  final VoidCallback onStop;
  final VoidCallback onContinue;
  final VoidCallback onVerify;
  final VoidCallback onPrepareReport;
  final VoidCallback onShare;
  final VoidCallback onAlreadyPaid;

  @override
  Widget build(BuildContext context) {
    final bool safe = assessment.level == RiskLevel.safe;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              'Choose the next step',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              safe
                  ? 'FinGuard will hand the validated request to your UPI app. Review the recipient again there.'
                  : 'FinGuard has not opened a UPI app or initiated a payment.',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: AppColors.inkMuted),
            ),
            const SizedBox(height: 18),
            if (safe)
              FilledButton.icon(
                key: const Key('continue_upi_button'),
                onPressed: onContinue,
                icon: const Icon(Icons.open_in_new),
                label: const Text('Continue to UPI app'),
              )
            else ...<Widget>[
              FilledButton.icon(
                key: const Key('stop_here_button'),
                style: assessment.level == RiskLevel.highRisk
                    ? FilledButton.styleFrom(backgroundColor: AppColors.danger)
                    : null,
                onPressed: onStop,
                icon: const Icon(Icons.stop_circle_outlined),
                label: const Text('Stop here'),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: onVerify,
                icon: const Icon(Icons.person_search_outlined),
                label: const Text('Check recipient'),
              ),
              const SizedBox(height: 10),
              if (assessment.level == RiskLevel.highRisk) ...<Widget>[
                OutlinedButton.icon(
                  onPressed: preparingReport ? null : onPrepareReport,
                  icon: preparingReport
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.description_outlined),
                  label: const Text('Prepare report'),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: onShare,
                  icon: const Icon(Icons.ios_share_outlined),
                  label: const Text('Alert trusted contact'),
                ),
                const SizedBox(height: 6),
              ],
              TextButton(
                key: const Key('continue_anyway_button'),
                onPressed: onContinue,
                child: const Text('Continue anyway'),
              ),
            ],
            const Divider(height: 30),
            TextButton.icon(
              key: const Key('already_paid_button'),
              onPressed: preparingReport ? null : onAlreadyPaid,
              icon: const Icon(Icons.receipt_long_outlined),
              label: const Text('I already paid'),
            ),
          ],
        ),
      ),
    );
  }
}
