import 'package:flutter/material.dart';

import '../models/policy_card.dart';
import '../theme/app_theme.dart';

/// A compact, on-demand account of how the score was built.
///
/// Fetched from the backend rather than bundled, because the app must not hold
/// a second copy of the weights: a client that keeps its own becomes a second
/// authority that can silently disagree with the engine. Collapsed by default,
/// because it answers a question most users will not ask - and the ones who do
/// deserve the real numbers rather than a line about accuracy.
class PolicyCardDrawer extends StatefulWidget {
  const PolicyCardDrawer({required this.load, super.key});

  final Future<PolicyCard> Function() load;

  @override
  State<PolicyCardDrawer> createState() => _PolicyCardDrawerState();
}

class _PolicyCardDrawerState extends State<PolicyCardDrawer> {
  Future<PolicyCard>? _pending;

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('policy_card_drawer'),
    width: double.infinity,
    decoration: BoxDecoration(
      color: AppColors.surface,
      border: Border.all(color: AppColors.border),
      borderRadius: BorderRadius.circular(12),
    ),
    clipBehavior: Clip.antiAlias,
    child: Material(
      type: MaterialType.transparency,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          key: const Key('policy_card_toggle'),
          tilePadding: const EdgeInsets.symmetric(horizontal: 16),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
          title: Text(
            'How this policy was chosen',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          subtitle: Text(
            'What each signal is worth, and why',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: AppColors.inkMuted),
          ),
          // Fetched only if somebody actually opens it.
          onExpansionChanged: (bool open) {
            if (open && _pending == null) {
              setState(() => _pending = widget.load());
            }
          },
          children: <Widget>[
            FutureBuilder<PolicyCard>(
              future: _pending,
              builder:
                  (BuildContext context, AsyncSnapshot<PolicyCard> snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 18),
                        child: Center(child: CircularProgressIndicator()),
                      );
                    }
                    if (snapshot.hasError) {
                      return Text(
                        'The scoring policy could not be loaded. It lives on '
                        'the server so the app never keeps its own copy.',
                        key: const Key('policy_card_error'),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppColors.inkMuted,
                        ),
                      );
                    }
                    return _PolicyCardBody(card: snapshot.data!);
                  },
            ),
          ],
        ),
      ),
    ),
  );
}

class _PolicyCardBody extends StatelessWidget {
  const _PolicyCardBody({required this.card});

  final PolicyCard card;

  @override
  Widget build(BuildContext context) {
    final TextStyle? sectionLabel = Theme.of(context).textTheme.labelSmall
        ?.copyWith(
          color: AppColors.inkMuted,
          letterSpacing: 1.1,
          fontWeight: FontWeight.w700,
        );
    final TextStyle? muted = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: AppColors.inkMuted, height: 1.4);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // The honesty line leads, ahead of any number.
        Container(
          key: const Key('policy_calibration_statement'),
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.surfaceMuted,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.border),
          ),
          child: Text(
            card.calibrationStatement,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(height: 1.5, color: AppColors.ink),
          ),
        ),
        const SizedBox(height: 14),
        Text('BANDS', style: sectionLabel),
        const SizedBox(height: 6),
        for (final PolicyBand band in card.bands)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SizedBox(
                  width: 58,
                  child: Text(
                    band.range,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                  ),
                ),
                SizedBox(
                  width: 66,
                  child: Text(
                    band.name,
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ),
                Expanded(child: Text(band.meaning, style: muted)),
              ],
            ),
          ),
        const SizedBox(height: 12),
        Text('WHAT EACH SIGNAL IS WORTH', style: sectionLabel),
        const SizedBox(height: 8),
        for (final PolicySignal signal in card.signalsByWeight)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SizedBox(
                  width: 34,
                  child: Text(
                    '+${signal.points}',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: AppColors.tealDark,
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        signal.title,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      Text(
                        '${signal.rationale}  ·  ${signal.sourceLabel}',
                        style: muted,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 6),
        Text('WHAT THIS CANNOT DO', style: sectionLabel),
        const SizedBox(height: 6),
        for (final String limitation in card.limitations)
          Padding(
            padding: const EdgeInsets.only(bottom: 5),
            child: Text('• $limitation', style: muted),
          ),
        const SizedBox(height: 8),
        Text(
          'Policy version ${card.policyVersion}',
          style: Theme.of(
            context,
          ).textTheme.labelSmall?.copyWith(color: AppColors.inkMuted),
        ),
      ],
    );
  }
}
