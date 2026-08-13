import 'package:flutter/material.dart';

import '../services/app_services.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

class IncidentScreen extends StatefulWidget {
  const IncidentScreen({
    required this.services,
    required this.report,
    required this.alreadyPaid,
    required this.preparedLocally,
    super.key,
  });

  final AppServices services;
  final String report;
  final bool alreadyPaid;
  final bool preparedLocally;

  @override
  State<IncidentScreen> createState() => _IncidentScreenState();
}

class _IncidentScreenState extends State<IncidentScreen> {
  bool _copied = false;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.alreadyPaid ? 'Recovery steps' : 'Incident draft'),
    ),
    body: PageBody(
      maxWidth: 840,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (widget.alreadyPaid) ...<Widget>[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: AppColors.dangerSurface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: AppColors.danger.withValues(alpha: 0.35),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Act promptly',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Contact your bank or UPI app through its official support channel. For immediate Indian financial-cyber-fraud reporting, call 1930. Keep the UTR/reference and screenshots ready.',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
          ],
          Text(
            widget.alreadyPaid
                ? 'Prepared incident summary'
                : 'Review your private draft',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text(
            widget.preparedLocally
                ? 'FinGuard prepared this complete local template; no payment details were sent to a drafting service.'
                : 'Nothing has been submitted. Review and edit after copying if any detail is incomplete.',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: AppColors.inkMuted),
          ),
          const SizedBox(height: 18),
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(minHeight: 240),
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.border),
            ),
            child: SelectableText(
              widget.report,
              key: const Key('incident_report_text'),
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(height: 1.55),
            ),
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: <Widget>[
              FilledButton.icon(
                key: const Key('copy_report_button'),
                onPressed: _copy,
                icon: Icon(_copied ? Icons.check : Icons.copy_outlined),
                label: Text(_copied ? 'Copied' : 'Copy report'),
              ),
              OutlinedButton.icon(
                key: const Key('open_cybercrime_button'),
                onPressed: _openPortal,
                icon: const Icon(Icons.open_in_new),
                label: const Text('Open official cybercrime portal'),
              ),
            ],
          ),
          const SizedBox(height: 18),
          const PrivacyNote(
            text:
                'FinGuard does not programmatically file complaints, contact your bank or send this draft. The official portal opens only after your confirmation.',
          ),
        ],
      ),
    ),
  );

  Future<void> _copy() async {
    final bool confirmed = await confirmAction(
      context,
      title: 'Copy incident draft?',
      message:
          'This will copy the incident draft to your device clipboard. Review it before sharing it with anyone.',
      confirmLabel: 'Copy to clipboard',
    );
    if (!confirmed || !mounted) {
      return;
    }
    await widget.services.externalActions.copyText(widget.report);
    if (!mounted) {
      return;
    }
    setState(() => _copied = true);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Incident draft copied.')));
  }

  Future<void> _openPortal() async {
    final bool confirmed = await confirmAction(
      context,
      title: 'Open the government portal?',
      message:
          'This opens cybercrime.gov.in in your browser. FinGuard will not pre-fill or submit a complaint; you decide what to share.',
      confirmLabel: 'Open official portal',
    );
    if (!confirmed || !mounted) {
      return;
    }
    try {
      await widget.services.externalActions.openCybercrimePortal();
    } on Object catch (error) {
      if (mounted) {
        showActionError(context, error);
      }
    }
  }
}
