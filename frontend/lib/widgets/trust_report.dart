import 'package:flutter/material.dart';

import '../models/payee_trust.dart';
import '../theme/app_theme.dart';

/// Renders a payee reputation report as a credit-report-style card.
///
/// The grade leads and the number follows, because a grade is the unit people
/// already know how to read under stress. A thin file shows no number at all:
/// there is nothing honest to put there, and an invented one would be read as
/// an endorsement.
class TrustReportCard extends StatelessWidget {
  const TrustReportCard({
    required this.trust,
    super.key,
    this.initiallyExpanded = false,
  });

  final PayeeTrust trust;
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final Color accent = _gradeColor(trust.grade);
    final Color surface = _gradeSurface(trust.grade);
    return Container(
      key: const Key('payee_trust_card'),
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            color: surface,
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _GradeBadge(trust: trust, accent: accent),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'PAYEE TRUST',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: AppColors.inkMuted,
                          letterSpacing: 1.2,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        trust.headline,
                        key: const Key('payee_trust_headline'),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      SelectableText(
                        trust.vpa,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppColors.inkMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: _LedgerSummary(trust: trust),
          ),
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              key: const Key('payee_trust_pillars_toggle'),
              initiallyExpanded: initiallyExpanded,
              tilePadding: const EdgeInsets.symmetric(horizontal: 16),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              title: Text(
                'How this grade was built',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              subtitle: Text(
                '${trust.pillars.where((TrustPillar p) => p.hasData).length} of '
                '${trust.pillars.length} factors could be assessed',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: AppColors.inkMuted),
              ),
              children: <Widget>[
                for (final TrustPillar pillar in trust.pillars)
                  _PillarRow(pillar: pillar),
                const SizedBox(height: 6),
                Text(
                  trust.disclaimer,
                  key: const Key('payee_trust_disclaimer'),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.inkMuted,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _GradeBadge extends StatelessWidget {
  const _GradeBadge({required this.trust, required this.accent});

  final PayeeTrust trust;
  final Color accent;

  @override
  Widget build(BuildContext context) => Semantics(
    label: trust.score == null
        ? 'Payee trust grade ${trust.grade.label}, no score available'
        : 'Payee trust grade ${trust.grade.label}, ${trust.score} out of 100',
    child: Container(
      width: 72,
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: accent, width: 2),
      ),
      child: Column(
        children: <Widget>[
          Text(
            trust.grade.label,
            key: const Key('payee_trust_grade'),
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              color: accent,
              fontWeight: FontWeight.w800,
              height: 1.0,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            // A thin file gets no number, the way a credit bureau reports
            // "no history" rather than inventing a low score for someone
            // who has simply never borrowed.
            trust.score == null ? 'no history' : '${trust.score}/100',
            key: const Key('payee_trust_score'),
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: AppColors.inkMuted),
          ),
        ],
      ),
    ),
  );
}

class _LedgerSummary extends StatelessWidget {
  const _LedgerSummary({required this.trust});

  final PayeeTrust trust;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 26,
    runSpacing: 12,
    children: <Widget>[
      _Fact(
        label: 'KNOWN FOR',
        value: trust.checkCount == 0 ? 'never seen' : _duration(trust.observedDays),
      ),
      _Fact(
        label: 'PAYERS',
        value: trust.distinctDeviceCount == 0
            ? 'none yet'
            : _count(trust.distinctDeviceCount),
      ),
      _Fact(
        label: 'CHECKS',
        value: trust.checkCount == 0 ? 'none yet' : _count(trust.checkCount),
      ),
      if (trust.reportedCount > 0)
        _Fact(
          label: 'REPORTS',
          value: _count(trust.reportedCount),
          danger: true,
        ),
    ],
  );

  static String _duration(int days) {
    if (days >= 365) {
      final int years = days ~/ 365;
      return years == 1 ? '1 year' : '$years years';
    }
    if (days >= 60) {
      return '${days ~/ 30} months';
    }
    return days == 1 ? '1 day' : '$days days';
  }

  static String _count(int value) {
    if (value >= 1000) {
      return '${(value / 1000).toStringAsFixed(value >= 10000 ? 0 : 1)}k';
    }
    return '$value';
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value, this.danger = false});

  final String label;
  final String value;
  final bool danger;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: AppColors.inkMuted,
          letterSpacing: 1.1,
        ),
      ),
      const SizedBox(height: 3),
      Text(
        value,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: danger ? AppColors.danger : AppColors.ink,
        ),
      ),
    ],
  );
}

class _PillarRow extends StatelessWidget {
  const _PillarRow({required this.pillar});

  final TrustPillar pillar;

  @override
  Widget build(BuildContext context) {
    final bool hasData = pillar.hasData;
    final Color barColor = switch (pillar.status) {
      TrustPillarStatus.strong => AppColors.safe,
      TrustPillarStatus.neutral => AppColors.caution,
      TrustPillarStatus.weak => AppColors.danger,
      TrustPillarStatus.noData => AppColors.border,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  pillar.label,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                hasData ? '${pillar.points}/${pillar.maximum}' : 'no data',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: hasData ? AppColors.ink : AppColors.inkMuted,
                  fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: hasData ? pillar.fraction : 0,
              minHeight: 6,
              backgroundColor: AppColors.surfaceMuted,
              valueColor: AlwaysStoppedAnimation<Color>(barColor),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            pillar.evidence,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: AppColors.inkMuted, height: 1.45),
          ),
        ],
      ),
    );
  }
}

Color _gradeColor(TrustGrade grade) => switch (grade) {
  TrustGrade.aPlus || TrustGrade.a => AppColors.safe,
  TrustGrade.b => AppColors.tealDark,
  TrustGrade.c => AppColors.caution,
  TrustGrade.d => AppColors.danger,
  TrustGrade.isNew => AppColors.inkMuted,
};

Color _gradeSurface(TrustGrade grade) => switch (grade) {
  TrustGrade.aPlus || TrustGrade.a => AppColors.safeSurface,
  TrustGrade.b => AppColors.tealSoft,
  TrustGrade.c => AppColors.cautionSurface,
  TrustGrade.d => AppColors.dangerSurface,
  TrustGrade.isNew => AppColors.surfaceMuted,
};

/// Hands a UPI ID to the government's own suspect registry.
///
/// FinGuard's bureau is built from what its own network has seen. The
/// authoritative list of identifiers reported by banks and victims belongs to
/// I4C, sits behind a CAPTCHA, and is not something this app can or should
/// read programmatically. So the app does the one useful thing it honestly
/// can: it puts the address on the clipboard and opens the official search, at
/// the moment the user has a reason to run it. FinGuard is not claiming the
/// government's answer here - it is handing over the question.
class SuspectRegistryCard extends StatefulWidget {
  const SuspectRegistryCard({
    required this.vpa,
    required this.onCopy,
    required this.onOpenRegistry,
    super.key,
  });

  final String vpa;
  final Future<void> Function(String vpa) onCopy;
  final Future<void> Function() onOpenRegistry;

  @override
  State<SuspectRegistryCard> createState() => _SuspectRegistryCardState();
}

class _SuspectRegistryCardState extends State<SuspectRegistryCard> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('suspect_registry_card'),
    width: double.infinity,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: AppColors.surface,
      border: Border.all(color: AppColors.border),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            const Icon(
              Icons.account_balance_outlined,
              size: 20,
              color: AppColors.tealDark,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Check the government list',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          'India\u2019s cybercrime portal keeps the official record of UPI IDs '
          'reported by banks and victims. FinGuard cannot read that list, so '
          'this copies the ID and opens the official search for you.',
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: AppColors.inkMuted, height: 1.5),
        ),
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            key: const Key('open_suspect_registry_button'),
            onPressed: _busy ? null : _handoff,
            icon: const Icon(Icons.open_in_new, size: 18),
            label: Text(_busy ? 'Opening\u2026' : 'Copy ID and open the check'),
          ),
        ),
      ],
    ),
  );

  Future<void> _handoff() async {
    setState(() => _busy = true);
    try {
      // Copy first: if opening the browser fails, the user still has the
      // address in hand and can run the search themselves.
      await widget.onCopy(widget.vpa);
      await widget.onOpenRegistry();
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${widget.vpa} copied. Paste it into the search.')),
      );
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }
}
