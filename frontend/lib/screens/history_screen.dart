import 'package:flutter/material.dart';

import '../models/history_entry.dart';
import '../services/app_services.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import 'risk_result_screen.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({required this.services, super.key});

  final AppServices services;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  late Future<List<HistoryEntry>> _history;

  @override
  void initState() {
    super.initState();
    _history = widget.services.store.history();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Check history'),
      actions: <Widget>[
        TextButton(onPressed: _clear, child: const Text('Clear')),
        const SizedBox(width: 8),
      ],
    ),
    body: FutureBuilder<List<HistoryEntry>>(
      future: _history,
      builder: (BuildContext context, AsyncSnapshot<List<HistoryEntry>> snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final List<HistoryEntry> entries =
            snapshot.data ?? const <HistoryEntry>[];
        return PageBody(
          maxWidth: 800,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Recent checks',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 8),
              Text(
                'This list is stored on this device. The safety service also keeps scored requests under an anonymous identifier for a limited retention period. This is not bank transaction history.',
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: AppColors.inkMuted),
              ),
              const SizedBox(height: 22),
              if (entries.isEmpty)
                const _EmptyHistory()
              else
                for (final HistoryEntry entry in entries)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _HistoryRow(entry: entry, onTap: () => _open(entry)),
                  ),
            ],
          ),
        );
      },
    ),
  );

  Future<void> _clear() async {
    final bool confirmed = await confirmAction(
      context,
      title: 'Clear local history?',
      message:
          'This removes payment-check summaries from this device. It does not delete the service\'s limited-retention assessment record or affect any bank or UPI app.',
      confirmLabel: 'Clear history',
      isDanger: true,
    );
    if (!confirmed) {
      return;
    }
    await widget.services.store.clearHistory();
    if (mounted) {
      setState(() => _history = widget.services.store.history());
    }
  }

  void _open(HistoryEntry entry) {
    Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (BuildContext context) => RiskResultScreen(
          services: widget.services,
          payment: entry.payment,
          assessment: entry.assessment,
          paymentHandoffEnabled: false,
          isDemo: entry.isDemo,
        ),
      ),
    );
  }
}

class _EmptyHistory extends StatelessWidget {
  const _EmptyHistory();

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 42),
    decoration: BoxDecoration(
      border: Border.all(color: AppColors.border),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Column(
      children: <Widget>[
        const Icon(Icons.history, size: 36, color: AppColors.inkMuted),
        const SizedBox(height: 12),
        Text('No checks yet', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 5),
        const Text('Scanned, pasted and demo results will appear here.'),
      ],
    ),
  );
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.entry, required this.onTap});

  final HistoryEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Card(
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: <Widget>[
            RiskBadge(level: entry.assessment.level),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    entry.payment.recipientLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${entry.payment.formattedAmount} · ${_formatDate(entry.checkedAt)}${entry.isDemo ? ' · Demo' : ''}',
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: AppColors.inkMuted),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${entry.assessment.score}/100',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right),
          ],
        ),
      ),
    ),
  );

  String _formatDate(DateTime date) {
    final DateTime local = date.toLocal();
    String twoDigits(int value) => value.toString().padLeft(2, '0');
    return '${twoDigits(local.day)}/${twoDigits(local.month)} ${twoDigits(local.hour)}:${twoDigits(local.minute)}';
  }
}
