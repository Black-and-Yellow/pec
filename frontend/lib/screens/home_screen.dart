import 'dart:async';

import 'package:flutter/material.dart';

import '../models/history_entry.dart';
import '../models/risk.dart';
import '../services/app_services.dart';
import '../services/demo_repository.dart';
import '../services/share_intake.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import 'account_screen.dart';
import 'context_screen.dart';
import 'history_screen.dart';
import 'paste_screen.dart';
import 'risk_lab_screen.dart';
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
  StreamSubscription<String>? _shareSubscription;
  bool _shareRouteOpen = false;
  bool _drainingSharedText = false;
  final List<String> _pendingSharedText = <String>[];

  @override
  void initState() {
    super.initState();
    _shareSubscription = widget.services.shareIntake.shares().listen(
      _handleSharedText,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_openInitialShare());
      }
    });
  }

  @override
  void dispose() {
    unawaited(_shareSubscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      toolbarHeight: 68,
      title: const FinGuardBrand(compact: true, inverse: true),
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
      maxWidth: 1120,
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 44),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool wide = constraints.maxWidth >= 760;
          final Widget actions = _PrimaryActions(
            onScan: _openScanner,
            onPaste: _openPaste,
            onMessage: _openContext,
          );
          final Widget demos = _DemoSection(
            loadingId: _loadingDemoId,
            onSelected: _openDemo,
            onCompare: _openRiskLab,
          );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const _Introduction(),
              const SizedBox(height: 28),
              if (wide)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Expanded(child: actions),
                    const SizedBox(width: 24),
                    SizedBox(width: 330, child: demos),
                  ],
                )
              else ...<Widget>[actions, const SizedBox(height: 32), demos],
              const SizedBox(height: 30),
              const _BoundaryStatement(),
            ],
          );
        },
      ),
    ),
  );

  void _openScanner() => unawaited(
    Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (BuildContext context) =>
            ScannerScreen(services: widget.services),
      ),
    ),
  );

  void _openPaste() => unawaited(
    Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (BuildContext context) =>
            PasteScreen(services: widget.services),
      ),
    ),
  );

  void _openContext() => unawaited(
    Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (BuildContext context) =>
            ContextScreen(services: widget.services),
      ),
    ),
  );

  Future<void> _openInitialShare() async {
    try {
      final String? shared = await widget.services.shareIntake.initialShare();
      if (shared != null) {
        await _handleSharedText(shared);
      }
    } on Object {
      // Share intake is optional and must not block the normal home flow.
    }
  }

  Future<void> _handleSharedText(String rawText) async {
    final String? shared = normalizeSharedText(rawText);
    if (shared == null || !mounted) {
      return;
    }
    if (_shareRouteOpen || ModalRoute.of(context)?.isCurrent != true) {
      _queueSharedText(shared);
      return;
    }
    _shareRouteOpen = true;
    try {
      final String? upiUri = _extractUpiUri(shared);
      await Navigator.push<void>(
        context,
        MaterialPageRoute<void>(
          builder: (BuildContext context) => upiUri == null
              ? ContextScreen(services: widget.services, initialText: shared)
              : PasteScreen(
                  services: widget.services,
                  initialUri: upiUri,
                  analyzeImmediately: true,
                ),
        ),
      );
    } finally {
      _shareRouteOpen = false;
      unawaited(_drainSharedText());
    }
  }

  void _queueSharedText(String shared) {
    if (_pendingSharedText.length == 5) {
      _pendingSharedText.removeAt(0);
    }
    _pendingSharedText.add(shared);
    unawaited(_drainSharedText());
  }

  Future<void> _drainSharedText() async {
    if (_drainingSharedText) {
      return;
    }
    _drainingSharedText = true;
    try {
      while (mounted && _pendingSharedText.isNotEmpty) {
        while (mounted &&
            (_shareRouteOpen || ModalRoute.of(context)?.isCurrent != true)) {
          await Future<void>.delayed(const Duration(milliseconds: 150));
        }
        if (!mounted) {
          return;
        }
        final String next = _pendingSharedText.removeAt(0);
        await _handleSharedText(next);
      }
    } finally {
      _drainingSharedText = false;
    }
  }

  String? _extractUpiUri(String text) {
    final RegExpMatch? match = RegExp(
      r'upi://pay[^\s]*',
      caseSensitive: false,
    ).firstMatch(text);
    if (match == null) {
      return null;
    }
    return match.group(0)?.replaceFirst(RegExp(r'''[.,\)\]>"']+$'''), '');
  }

  void _openRiskLab() => unawaited(
    Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (BuildContext context) =>
            RiskLabScreen(services: widget.services),
      ),
    ),
  );

  Future<void> _openDemo(String id) async {
    if (_loadingDemoId != null) return;
    setState(() => _loadingDemoId = id);
    final DemoScenario scenario = await widget.services.demos.load(id);
    if (!mounted) return;
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
    if (!mounted) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (BuildContext context) => RiskResultScreen(
          services: widget.services,
          payment: scenario.payment,
          assessment: scenario.assessment,
          paymentHandoffEnabled: false,
          isDemo: true,
        ),
      ),
    );
  }
}

class _Introduction extends StatelessWidget {
  const _Introduction();

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 26),
    decoration: BoxDecoration(
      color: AppColors.chrome,
      borderRadius: BorderRadius.circular(24),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'PRE-PAYMENT CHECK',
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: AppColors.teal,
            letterSpacing: 1.3,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          'Know what you are paying.',
          style: Theme.of(
            context,
          ).textTheme.headlineMedium?.copyWith(color: Colors.white),
        ),
        const SizedBox(height: 10),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 660),
          child: Text(
            'Scan or paste a UPI request to see the recipient, risk signals and safer next step before any handoff.',
            style: Theme.of(
              context,
            ).textTheme.bodyLarge?.copyWith(color: AppColors.chromeMuted),
          ),
        ),
      ],
    ),
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
  Widget build(BuildContext context) => WorkspacePanel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Start a check',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 4),
              Text(
                'Choose how you received the payment request.',
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: AppColors.inkMuted),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        WorkspaceAction(
          key: const Key('scan_qr_button'),
          icon: Icons.qr_code_scanner,
          label: 'Scan QR',
          description: 'Use the camera to inspect a payment code.',
          emphasized: true,
          onTap: onScan,
        ),
        const Divider(height: 1, indent: 68),
        WorkspaceAction(
          key: const Key('paste_upi_button'),
          icon: Icons.link,
          label: 'Paste UPI Link',
          description: 'Review a copied UPI payment request.',
          onTap: onPaste,
        ),
        const Divider(height: 1, indent: 68),
        WorkspaceAction(
          key: const Key('message_check_button'),
          icon: Icons.message_outlined,
          label: 'Check suspicious message',
          description: 'Add context without changing the risk score.',
          onTap: onMessage,
        ),
      ],
    ),
  );
}

class _DemoSection extends StatelessWidget {
  const _DemoSection({
    required this.loadingId,
    required this.onSelected,
    required this.onCompare,
  });

  final String? loadingId;
  final ValueChanged<String> onSelected;
  final VoidCallback onCompare;

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
                  'Try with demo data',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 4),
                Text(
                  'Fixed examples. No AI or network required.',
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: AppColors.inkMuted),
                ),
              ],
            ),
          ),
          if (loadingId != null)
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
        ],
      ),
      const SizedBox(height: 14),
      WorkspacePanel(
        child: Column(
          children: DemoRepository.bundled.indexed
              .expand(
                ((int, DemoScenario) item) => <Widget>[
                  if (item.$1 > 0) const Divider(height: 1),
                  _DemoRow(
                    scenario: item.$2,
                    enabled: loadingId == null,
                    onTap: () => onSelected(item.$2.id),
                  ),
                ],
              )
              .toList(growable: false),
        ),
      ),
      const SizedBox(height: 10),
      Align(
        alignment: Alignment.centerRight,
        child: TextButton.icon(
          key: const Key('open_risk_lab_button'),
          onPressed: loadingId == null ? onCompare : null,
          icon: const Icon(Icons.science_outlined),
          label: const Text('Start 90-second demo'),
        ),
      ),
    ],
  );
}

class _DemoRow extends StatelessWidget {
  const _DemoRow({
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
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onTap : null,
        hoverColor: AppColors.surfaceMuted,
        focusColor: AppColors.tealSoft,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      scenario.title,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      scenario.subtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppColors.inkMuted,
                      ),
                    ),
                    const SizedBox(height: 10),
                    RiskBadge(level: scenario.assessment.level),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(
                Icons.chevron_right,
                size: 20,
                color: AppColors.inkMuted,
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
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(vertical: 16),
    decoration: const BoxDecoration(
      border: Border(top: BorderSide(color: AppColors.border)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Icon(Icons.info_outline, color: AppColors.inkMuted, size: 18),
        const SizedBox(width: 9),
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
    ),
  );
}
