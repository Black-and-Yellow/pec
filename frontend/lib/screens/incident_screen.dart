import 'dart:async';

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
  _PaymentTiming? _paymentTiming;
  Duration? _elapsedAtSelection;
  DateTime? _selectedAt;
  Duration _timerElapsed = Duration.zero;
  Timer? _tick;
  int? _lastAnnouncedMinute;
  String? _clockAnnouncement;
  bool _dialerUnavailable = false;

  Duration? get _remaining {
    final Duration? elapsedAtSelection = _elapsedAtSelection;
    final DateTime? selectedAt = _selectedAt;
    if (elapsedAtSelection == null || selectedAt == null) {
      return null;
    }
    final Duration wallElapsed = DateTime.now().difference(selectedAt);
    final Duration elapsed =
        elapsedAtSelection +
        (wallElapsed > _timerElapsed ? wallElapsed : _timerElapsed);
    final Duration remaining = const Duration(hours: 1) - elapsed;
    return remaining.isNegative ? Duration.zero : remaining;
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

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
            _buildRecoveryClock(context),
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

  Widget _buildRecoveryClock(BuildContext context) {
    final Duration? remaining = _remaining;
    final bool counting = remaining != null && remaining > Duration.zero;
    final bool selected = _paymentTiming != null;
    return Container(
      key: const Key('golden_hour_card'),
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.dangerSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.danger.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            selected && !counting ? 'Report now' : 'Act promptly',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          const Text(
            'Reporting quickly gives banks the best chance to hold the transferred money before it moves on. This is general guidance, not a guarantee.',
          ),
          const SizedBox(height: 10),
          if (!selected) ...<Widget>[
            const Text('When did the payment happen?'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final _PaymentTiming timing in _PaymentTiming.values)
                  ChoiceChip(
                    key: Key('payment_timing_${timing.name}'),
                    label: Text(timing.label),
                    selected: false,
                    onSelected: (_) => _selectTiming(timing),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            const Text(
              'Contact your bank or UPI app through its official support channel. Keep the UTR/reference and screenshots ready.',
            ),
          ] else if (counting) ...<Widget>[
            Semantics(
              liveRegion: true,
              label: _clockAnnouncement,
              child: ExcludeSemantics(
                child: Text(
                  _formatRemaining(remaining),
                  key: const Key('recovery_clock'),
                  style: Theme.of(context).textTheme.displaySmall,
                ),
              ),
            ),
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value:
                  remaining.inMilliseconds /
                  const Duration(hours: 1).inMilliseconds,
            ),
            const SizedBox(height: 12),
            _buildCallButton(),
          ] else ...<Widget>[
            const Text(
              'More than an hour may have passed. Reporting still matters — call 1930 and file at cybercrime.gov.in.',
            ),
            const SizedBox(height: 12),
            _buildCallButton(),
          ],
          if (_dialerUnavailable) ...<Widget>[
            const SizedBox(height: 10),
            const Text('Dial this number manually:'),
            const SelectableText('1930'),
          ],
        ],
      ),
    );
  }

  Widget _buildCallButton() => FilledButton.icon(
    key: const Key('call_1930_button'),
    onPressed: _call1930,
    icon: const Icon(Icons.call_outlined),
    label: const Text('Call 1930'),
  );

  void _selectTiming(_PaymentTiming timing) {
    _tick?.cancel();
    final Duration? assumedElapsed = timing.assumedElapsed;
    setState(() {
      _paymentTiming = timing;
      _elapsedAtSelection = assumedElapsed;
      _selectedAt = assumedElapsed == null ? null : DateTime.now();
      _timerElapsed = Duration.zero;
      _dialerUnavailable = false;
      _updateClockAnnouncement();
    });
    if (assumedElapsed == null) {
      return;
    }
    _tick = Timer.periodic(const Duration(seconds: 1), (Timer timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        _timerElapsed += const Duration(seconds: 1);
        _updateClockAnnouncement();
        if (_remaining == Duration.zero) {
          timer.cancel();
        }
      });
    });
  }

  void _updateClockAnnouncement() {
    final Duration? remaining = _remaining;
    if (remaining == null || remaining == Duration.zero) {
      _lastAnnouncedMinute = null;
      _clockAnnouncement = null;
      return;
    }
    final int minutes = (remaining.inSeconds / 60).ceil();
    if (_lastAnnouncedMinute != minutes) {
      _lastAnnouncedMinute = minutes;
      _clockAnnouncement = 'About $minutes minutes remain in the first hour.';
    }
  }

  String _formatRemaining(Duration remaining) {
    final int minutes = remaining.inMinutes;
    final int seconds = remaining.inSeconds.remainder(60);
    final String paddedSeconds = seconds.toString().padLeft(
      2,
      String.fromCharCode(48),
    );
    return 'about $minutes:$paddedSeconds left';
  }

  Future<void> _call1930() async {
    final bool confirmed = await confirmAction(
      context,
      title: 'Call 1930?',
      message:
          'This opens your phone dialer for India\'s cyber-fraud helpline. '
          'FinGuard does not place the call or speak on your behalf.',
      confirmLabel: 'Open dialer',
    );
    if (!confirmed || !mounted) {
      return;
    }
    try {
      await widget.services.externalActions.openDialer('tel:1930');
    } on Object catch (error) {
      if (mounted) {
        setState(() => _dialerUnavailable = true);
        showActionError(context, error);
      }
    }
  }

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

enum _PaymentTiming {
  justNow('Just now', Duration.zero),
  under15('Under 15 minutes ago', Duration(minutes: 15)),
  underHour('Under an hour ago', Duration(minutes: 45)),
  longer('Longer ago', null),
  notSure('Not sure', null);

  const _PaymentTiming(this.label, this.assumedElapsed);

  final String label;
  final Duration? assumedElapsed;
}
