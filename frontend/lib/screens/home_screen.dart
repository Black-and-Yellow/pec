import 'dart:async';

import 'package:flutter/material.dart';

import '../models/history_entry.dart';
import '../models/risk.dart';
import '../services/app_services.dart';
import '../services/demo_repository.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import 'account_screen.dart';
import 'context_screen.dart';
import 'history_screen.dart';
import 'paste_screen.dart';
import 'risk_result_screen.dart';
import 'scanner_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({required this.services, super.key});

  final AppServices services;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String? _loadingDemoId;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      toolbarHeight: 72,
      title: const FinGuardBrand(),
      actions: <Widget>[
        if (widget.services.auth != null)
          IconButton(
            tooltip: widget.services.auth!.user == null
                ? 'Guest account and privacy'
                : 'Account and privacy',
            onPressed: () => Navigator.push<void>(
              context,
              MaterialPageRoute<void>(
                builder: (BuildContext context) =>
                    AccountScreen(services: widget.services),
              ),
            ),
            icon: Icon(
              widget.services.auth!.user == null
                  ? Icons.person_outline
                  : Icons.account_circle_outlined,
            ),
          ),
        IconButton(
          tooltip: 'Check history',
          onPressed: () => Navigator.push<void>(
            context,
            MaterialPageRoute<void>(
              builder: (BuildContext context) =>
                  HistoryScreen(services: widget.services),
            ),
          ),
          icon: const Icon(Icons.history),
        ),
        const SizedBox(width: 12),
      ],
    ),
    body: PageBody(
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool wide = constraints.maxWidth >= 760;
          final Widget introduction = _Introduction(wide: wide);
          final Widget actions = _PrimaryActions(
            onScan: _openScanner,
            onPaste: _openPaste,
            onMessage: _openContext,
          );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (wide)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: <Widget>[
                    Expanded(flex: 6, child: introduction),
                    const SizedBox(width: 54),
                    Expanded(flex: 5, child: actions),
                  ],
                )
              else ...<Widget>[
                introduction,
                const SizedBox(height: 30),
                actions,
              ],
              const SizedBox(height: 52),
              _DemoSection(loadingId: _loadingDemoId, onSelected: _openDemo),
              const SizedBox(height: 34),
              const Divider(),
              const SizedBox(height: 18),
              const _BoundaryStatement(),
            ],
          );
        },
      ),
    ),
  );

  void _openScanner() {
    unawaited(
      Navigator.push<void>(
        context,
        MaterialPageRoute<void>(
          builder: (BuildContext context) =>
              ScannerScreen(services: widget.services),
        ),
      ),
    );
  }

  void _openPaste() {
    unawaited(
      Navigator.push<void>(
        context,
        MaterialPageRoute<void>(
          builder: (BuildContext context) =>
              PasteScreen(services: widget.services),
        ),
      ),
    );
  }

  void _openContext() {
    unawaited(
      Navigator.push<void>(
        context,
        MaterialPageRoute<void>(
          builder: (BuildContext context) =>
              ContextScreen(services: widget.services),
        ),
      ),
    );
  }

  Future<void> _openDemo(String id) async {
    if (_loadingDemoId != null) {
      return;
    }
    setState(() => _loadingDemoId = id);
    final DemoScenario scenario = await widget.services.demos.load(id);
    if (!mounted) {
      return;
    }
    setState(() => _loadingDemoId = null);
    final DateTime now = DateTime.now();
    try {
      await widget.services.store.addHistory(
        HistoryEntry(
          id: 'demo_${now.microsecondsSinceEpoch}',
          checkedAt: now,
          payment: scenario.payment,
          assessment: scenario.assessment,
          isDemo: true,
        ),
      );
    } on Object {
      // A browser that blocks local storage must not block the bundled demo.
    }
    if (!mounted) {
      return;
    }
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (BuildContext context) => RiskResultScreen(
          services: widget.services,
          payment: scenario.payment,
          assessment: scenario.assessment,
          isDemo: true,
        ),
      ),
    );
  }
}

class _Introduction extends StatelessWidget {
  const _Introduction({required this.wide});

  final bool wide;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Text(
        'PRE-PAYMENT SAFETY',
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: AppColors.teal,
          letterSpacing: 1.3,
        ),
      ),
      const SizedBox(height: 14),
      Text(
        'Detect risk.\nTrigger response.',
        style: wide
            ? Theme.of(context).textTheme.displaySmall
            : Theme.of(context).textTheme.headlineMedium,
      ),
      const SizedBox(height: 18),
      Text(
        'Check a QR code or UPI payment link, understand why it may be risky, and choose the safer next step before handoff.',
        style: Theme.of(
          context,
        ).textTheme.bodyLarge?.copyWith(color: AppColors.inkMuted),
      ),
      const SizedBox(height: 22),
      const Wrap(
        spacing: 18,
        runSpacing: 10,
        children: <Widget>[
          _Step(number: '1', label: 'Scan or paste'),
          _Step(number: '2', label: 'Score explainably'),
          _Step(number: '3', label: 'Respond'),
        ],
      ),
    ],
  );
}

class _Step extends StatelessWidget {
  const _Step({required this.number, required this.label});

  final String number;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      Container(
        width: 26,
        height: 26,
        alignment: Alignment.center,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: AppColors.tealSoft,
        ),
        child: Text(
          number,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: AppColors.tealDark,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      const SizedBox(width: 7),
      Text(label, style: Theme.of(context).textTheme.bodyMedium),
    ],
  );
}

class _PrimaryActions extends StatelessWidget {
  const _PrimaryActions({
    required this.onScan,
    required this.onPaste,
    required this.onMessage,
  });

  final VoidCallback onScan;
  final VoidCallback onPaste;
  final VoidCallback onMessage;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            'Check a payment request',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            'FinGuard will show the recipient, score, reasons and recommended action.',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: AppColors.inkMuted),
          ),
          const SizedBox(height: 22),
          FilledButton.icon(
            key: const Key('scan_qr_button'),
            onPressed: onScan,
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('Scan QR'),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            key: const Key('paste_upi_button'),
            onPressed: onPaste,
            icon: const Icon(Icons.link),
            label: const Text('Paste UPI Link'),
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            key: const Key('message_check_button'),
            onPressed: onMessage,
            icon: const Icon(Icons.message_outlined),
            label: const Text('Check suspicious message'),
          ),
        ],
      ),
    ),
  );
}

class _DemoSection extends StatelessWidget {
  const _DemoSection({required this.loadingId, required this.onSelected});

  final String? loadingId;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Reliable demo cases',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 4),
                Text(
                  'Clearly labelled seeded fixtures; results do not depend on AI or network availability.',
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: AppColors.inkMuted),
                ),
              ],
            ),
          ),
          if (loadingId != null)
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
        ],
      ),
      const SizedBox(height: 18),
      LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool wide = constraints.maxWidth >= 760;
          final List<Widget> cards = DemoRepository.bundled
              .map(
                (DemoScenario scenario) => _DemoCard(
                  scenario: scenario,
                  enabled: loadingId == null,
                  onTap: () => onSelected(scenario.id),
                ),
              )
              .toList(growable: false);
          if (!wide) {
            return Column(
              children: cards
                  .expand(
                    (Widget card) => <Widget>[card, const SizedBox(height: 12)],
                  )
                  .toList(growable: false),
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children:
                cards
                    .map((Widget card) => Expanded(child: card))
                    .expand(
                      (Widget card) => <Widget>[
                        card,
                        const SizedBox(width: 12),
                      ],
                    )
                    .toList()
                  ..removeLast(),
          );
        },
      ),
    ],
  );
}

class _DemoCard extends StatelessWidget {
  const _DemoCard({
    required this.scenario,
    required this.enabled,
    required this.onTap,
  });

  final DemoScenario scenario;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: enabled,
    label:
        '${scenario.title}, ${scenario.assessment.level.label}, ${scenario.subtitle}',
    child: Card(
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(17),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              RiskBadge(level: scenario.assessment.level),
              const SizedBox(height: 16),
              Text(
                scenario.title,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                scenario.subtitle,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: AppColors.inkMuted),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _BoundaryStatement extends StatelessWidget {
  const _BoundaryStatement();

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      const Icon(Icons.info_outline, color: AppColors.inkMuted, size: 20),
      const SizedBox(width: 10),
      Expanded(
        child: Text(
          'FinGuard checks before handoff. It does not intercept, freeze, cancel or reverse transactions inside UPI apps.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: AppColors.inkMuted,
            height: 1.5,
          ),
        ),
      ),
    ],
  );
}
