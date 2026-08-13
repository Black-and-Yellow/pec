import 'package:flutter/material.dart';

import '../models/risk.dart';
import '../services/app_services.dart';
import '../services/demo_repository.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import 'risk_result_screen.dart';

class RiskLabScreen extends StatefulWidget {
  const RiskLabScreen({required this.services, super.key});

  final AppServices services;

  @override
  State<RiskLabScreen> createState() => _RiskLabScreenState();
}

class _RiskLabScreenState extends State<RiskLabScreen> {
  int _selectedIndex = 0;

  DemoScenario get _selected => DemoRepository.bundled[_selectedIndex];

  @override
  Widget build(BuildContext context) => Scaffold(
    key: const Key('risk_lab_screen'),
    appBar: AppBar(title: const Text('Risk Lab')),
    body: PageBody(
      maxWidth: 1120,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'OFFLINE SHOWCASE',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: AppColors.teal,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Compare policy evidence',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Text(
              'Explore the bundled SAFE, CAUTION and HIGH RISK outcomes side by side. These fixtures never call the API, AI or a UPI app.',
              style: Theme.of(
                context,
              ).textTheme.bodyLarge?.copyWith(color: AppColors.inkMuted),
            ),
          ),
          const SizedBox(height: 16),
          const PrivacyNote(
            text:
                'Scores and verdicts shown here are precomputed demo outcomes from the deterministic policy. This screen does not calculate or change them.',
          ),
          const SizedBox(height: 20),
          _GuidedTour(
            selectedIndex: _selectedIndex,
            onSelected: _selectIndex,
            onPrevious: _selectedIndex == 0
                ? null
                : () => _selectIndex(_selectedIndex - 1),
            onNext: _selectedIndex == DemoRepository.bundled.length - 1
                ? null
                : () => _selectIndex(_selectedIndex + 1),
          ),
          const SizedBox(height: 28),
          AnimatedSwitcher(
            duration: _motionDuration(context, 180),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            child: _EvidenceInspector(
              key: ValueKey<String>(_selected.id),
              scenario: _selected,
              onOpenResult: _openResult,
            ),
          ),
        ],
      ),
    ),
  );

  void _selectIndex(int index) {
    if (index < 0 ||
        index >= DemoRepository.bundled.length ||
        index == _selectedIndex) {
      return;
    }
    setState(() => _selectedIndex = index);
  }

  Future<void> _openResult() => Navigator.push<void>(
    context,
    MaterialPageRoute<void>(
      builder: (BuildContext context) => RiskResultScreen(
        services: widget.services,
        payment: _selected.payment,
        assessment: _selected.assessment,
        paymentHandoffEnabled: false,
        isDemo: true,
      ),
    ),
  );
}

class _GuidedTour extends StatelessWidget {
  const _GuidedTour({
    required this.selectedIndex,
    required this.onSelected,
    required this.onPrevious,
    required this.onNext,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) => WorkspacePanel(
    padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 16,
          runSpacing: 4,
          children: <Widget>[
            Text(
              'Outcome spectrum',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            Text(
              'Case ${selectedIndex + 1} of ${DemoRepository.bundled.length}',
              key: const Key('risk_lab_case_progress'),
              style: Theme.of(
                context,
              ).textTheme.labelLarge?.copyWith(color: AppColors.inkMuted),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Follow the three bundled outcomes from SAFE to HIGH RISK.',
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: AppColors.inkMuted),
        ),
        const SizedBox(height: 14),
        _OutcomeSpectrum(selectedIndex: selectedIndex, onSelected: onSelected),
        const SizedBox(height: 10),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          spacing: 12,
          runSpacing: 8,
          children: <Widget>[
            OutlinedButton.icon(
              key: const Key('risk_lab_previous_case'),
              onPressed: onPrevious,
              icon: const Icon(Icons.arrow_back, size: 18),
              label: const Text('Previous'),
            ),
            OutlinedButton.icon(
              key: const Key('risk_lab_next_case'),
              onPressed: onNext,
              icon: const Icon(Icons.arrow_forward, size: 18),
              label: const Text('Next'),
              iconAlignment: IconAlignment.end,
            ),
          ],
        ),
      ],
    ),
  );
}

class _OutcomeSpectrum extends StatelessWidget {
  const _OutcomeSpectrum({
    required this.selectedIndex,
    required this.onSelected,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (BuildContext context, BoxConstraints constraints) {
      final double markerWidth = constraints.maxWidth < 340
          ? 60
          : constraints.maxWidth < 430
          ? 76
          : 96;
      final double travel = (constraints.maxWidth - markerWidth).clamp(
        0,
        double.infinity,
      );
      return SizedBox(
        height: 82,
        child: Stack(
          children: <Widget>[
            Positioned(
              left: markerWidth / 2,
              right: markerWidth / 2,
              top: 22,
              child: Container(height: 2, color: AppColors.border),
            ),
            for (final (int, DemoScenario) item
                in DemoRepository.bundled.indexed)
              Positioned(
                left:
                    travel *
                    (item.$2.assessment.score.clamp(0, 100).toDouble() / 100),
                top: 0,
                width: markerWidth,
                child: _SpectrumMarker(
                  scenario: item.$2,
                  selected: item.$1 == selectedIndex,
                  onTap: () => onSelected(item.$1),
                ),
              ),
          ],
        ),
      );
    },
  );
}

class _SpectrumMarker extends StatelessWidget {
  const _SpectrumMarker({
    required this.scenario,
    required this.selected,
    required this.onTap,
  });

  final DemoScenario scenario;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    key: Key('risk_lab_spectrum_${scenario.id}'),
    button: true,
    selected: selected,
    onTap: onTap,
    label:
        'Select ${scenario.title}, ${scenario.assessment.level.label}, score ${scenario.assessment.score} of 100',
    child: ExcludeSemantics(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          hoverColor: AppColors.surfaceMuted,
          focusColor: AppColors.tealSoft,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 2),
            child: Column(
              children: <Widget>[
                AnimatedContainer(
                  duration: _motionDuration(context, 160),
                  width: 42,
                  height: 42,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: selected ? AppColors.tealSoft : AppColors.surface,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: selected ? AppColors.teal : AppColors.border,
                      width: selected ? 2 : 1,
                    ),
                  ),
                  child: Text(
                    '${scenario.assessment.score}',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: _levelColor(scenario.assessment.level),
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  _compactLevelLabel(scenario.assessment.level),
                  maxLines: 1,
                  overflow: TextOverflow.fade,
                  softWrap: false,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: selected ? AppColors.ink : AppColors.inkMuted,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _EvidenceInspector extends StatelessWidget {
  const _EvidenceInspector({
    required this.scenario,
    required this.onOpenResult,
    super.key,
  });

  final DemoScenario scenario;
  final VoidCallback onOpenResult;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    liveRegion: true,
    label:
        '${scenario.title} selected. ${scenario.assessment.level.label}, score ${scenario.assessment.score} of 100.',
    child: WorkspacePanel(
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            spacing: 16,
            runSpacing: 14,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    scenario.title,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 5),
                  Text(
                    scenario.payment.payeeVpa,
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(color: AppColors.inkMuted),
                  ),
                ],
              ),
              RiskBadge(level: scenario.assessment.level),
            ],
          ),
          const SizedBox(height: 22),
          _ScoreMeter(assessment: scenario.assessment),
          const SizedBox(height: 22),
          const Divider(height: 1),
          const SizedBox(height: 20),
          _PaymentFacts(scenario: scenario),
          const SizedBox(height: 22),
          const Divider(height: 1),
          const SizedBox(height: 20),
          Text(
            'Signal contributions',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 4),
          Text(
            'Displayed weights come from the bundled deterministic result.',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: AppColors.inkMuted),
          ),
          const SizedBox(height: 16),
          if (scenario.assessment.signals.isEmpty)
            const _NoSignals()
          else
            for (final RiskSignal signal in scenario.assessment.signals)
              _SignalContribution(signal: signal),
          const SizedBox(height: 8),
          FilledButton.icon(
            key: const Key('risk_lab_open_result'),
            onPressed: onOpenResult,
            icon: const Icon(Icons.open_in_new),
            label: const Text('Open view-only result'),
          ),
        ],
      ),
    ),
  );
}

class _ScoreMeter extends StatelessWidget {
  const _ScoreMeter({required this.assessment});

  final RiskAssessment assessment;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Risk score ${assessment.score} of 100',
    child: ExcludeSemantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Text(
                '${assessment.score}',
                key: const Key('risk_lab_score'),
                style: Theme.of(context).textTheme.displaySmall?.copyWith(
                  color: _levelColor(assessment.level),
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(left: 5, bottom: 5),
                  child: Text(
                    '/100 risk score',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: AppColors.inkMuted,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: assessment.score / 100),
              duration: _motionDuration(context, 260),
              curve: Curves.easeOutCubic,
              builder: (BuildContext context, double value, Widget? child) =>
                  LinearProgressIndicator(
                    value: value,
                    minHeight: 8,
                    color: _levelColor(assessment.level),
                    backgroundColor: AppColors.surfaceMuted,
                  ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _PaymentFacts extends StatelessWidget {
  const _PaymentFacts({required this.scenario});

  final DemoScenario scenario;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 32,
    runSpacing: 18,
    children: <Widget>[
      _Fact(label: 'RECIPIENT', value: scenario.payment.recipientLabel),
      _Fact(label: 'AMOUNT', value: scenario.payment.formattedAmount),
      if ((scenario.payment.note ?? '').isNotEmpty)
        _Fact(label: 'NOTE', value: scenario.payment.note!),
    ],
  );
}

class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(minWidth: 130, maxWidth: 260),
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
      ],
    ),
  );
}

class _SignalContribution extends StatelessWidget {
  const _SignalContribution({required this.signal});

  final RiskSignal signal;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          width: 48,
          padding: const EdgeInsets.symmetric(vertical: 5),
          decoration: BoxDecoration(
            color: AppColors.dangerSurface,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            '+${signal.weight}',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: AppColors.danger,
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

class _NoSignals extends StatelessWidget {
  const _NoSignals();

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 16),
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: AppColors.safeSurface,
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: AppColors.safe.withValues(alpha: 0.25)),
    ),
    child: const Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(Icons.check_circle_outline, color: AppColors.safe, size: 20),
        SizedBox(width: 10),
        Expanded(
          child: Text(
            'The bundled policy outcome contains no risk-raising signals.',
          ),
        ),
      ],
    ),
  );
}

Color _levelColor(RiskLevel level) => switch (level) {
  RiskLevel.safe => AppColors.safe,
  RiskLevel.caution => AppColors.caution,
  RiskLevel.highRisk => AppColors.danger,
};

Duration _motionDuration(BuildContext context, int milliseconds) =>
    MediaQuery.disableAnimationsOf(context) ||
        MediaQuery.accessibleNavigationOf(context)
    ? Duration.zero
    : Duration(milliseconds: milliseconds);

String _compactLevelLabel(RiskLevel level) => switch (level) {
  RiskLevel.highRisk => 'HIGH',
  _ => level.label,
};
