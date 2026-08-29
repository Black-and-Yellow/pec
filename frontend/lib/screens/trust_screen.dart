import 'dart:async';

import 'package:flutter/material.dart';

import '../models/identifier_check.dart';
import '../services/api_service.dart';
import '../services/app_services.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import '../widgets/trust_report.dart';

/// Look up who is behind an identifier before any payment request exists.
///
/// This is the "check them before you deal with them" surface: a seller sends
/// their UPI ID over chat, and the buyer can read its reputation without a QR,
/// without an amount, and without handing anything to a UPI app.
class TrustScreen extends StatefulWidget {
  const TrustScreen({required this.services, super.key, this.initialVpa});

  final AppServices services;
  final String? initialVpa;

  @override
  State<TrustScreen> createState() => _TrustScreenState();
}

class _TrustScreenState extends State<TrustScreen> {
  /// Fast enough that a room full of people scanning the same QR see the
  /// counters move while they are still looking at the screen, slow enough
  /// that it is not hammering the service.
  static const Duration _refreshInterval = Duration(seconds: 5);

  late final TextEditingController _controller;
  bool _loading = false;
  String? _error;
  IdentifierCheck? _check;
  Timer? _refreshTimer;
  DateTime? _refreshedAt;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialVpa);
    if ((widget.initialVpa ?? '').isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _lookup());
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  /// Starts polling only once a report is on screen. Before that there is no
  /// address to refresh, and an idle screen has no reason to be talking to
  /// the service at all.
  void _startAutoRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(
      _refreshInterval,
      (_) => unawaited(_lookup(silent: true)),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Check before you pay')),
    body: RefreshIndicator(
      // Pulling on an empty screen must not fire a lookup for a blank
      // address, so the gesture is a no-op until a report exists.
      onRefresh: () =>
          _check == null ? Future<void>.value() : _lookup(silent: true),
      child: PageBody(
        maxWidth: 820,
        physics: const AlwaysScrollableScrollPhysics(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'PAYEE REPUTATION',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: AppColors.tealDark,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.1,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Who is behind this?',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 10),
            Text(
              'Paste a UPI ID, a payment link, or a mobile number. FinGuard '
              'works out which it is, then reports how long the network has '
              'known the address, how many people have paid it, and what the '
              'address itself gives away. Nothing is paid, and no UPI app opens.',
              style: Theme.of(
                context,
              ).textTheme.bodyLarge?.copyWith(color: AppColors.inkMuted),
            ),
            const SizedBox(height: 24),
            TextField(
              key: const Key('trust_vpa_field'),
              controller: _controller,
              enabled: !_loading,
              autofocus: widget.initialVpa == null,
              keyboardType: TextInputType.text,
              textInputAction: TextInputAction.search,
              autocorrect: false,
              enableSuggestions: false,
              onSubmitted: (_) => _lookup(),
              decoration: const InputDecoration(
                labelText: 'UPI ID, link, or mobile number',
                hintText: 'name@handle, upi://pay?… or 98765 43210',
              ),
            ),
            if (_error != null) ...<Widget>[
              const SizedBox(height: 16),
              ErrorNotice(message: _error!, onRetry: _loading ? null : _lookup),
            ],
            const SizedBox(height: 20),
            AsyncFilledButton(
              buttonKey: const Key('lookup_trust_button'),
              loading: _loading,
              onPressed: _lookup,
              icon: Icons.travel_explore_outlined,
              label: 'Check this',
              loadingLabel: 'Checking…',
              loadingSemanticsLabel: 'Checking reputation',
            ),
            if (_check case final IdentifierCheck check) ...<Widget>[
              const SizedBox(height: 26),
              _CheckSummary(check: check),
              for (final CheckedAddress entry in check.addresses) ...<Widget>[
                const SizedBox(height: 16),
                if (check.addresses.length > 1)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      entry.vpa,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                TrustReportCard(
                  trust: entry.trust,
                  initiallyExpanded: check.addresses.length == 1,
                ),
              ],
              const SizedBox(height: 10),
              _RefreshedAtLabel(refreshedAt: _refreshedAt),
              if (check.value.contains('@')) ...<Widget>[
                const SizedBox(height: 18),
                SuspectRegistryCard(
                  vpa: check.value,
                  onCopy: widget.services.externalActions.copyText,
                  onOpenRegistry:
                      widget.services.externalActions.openSuspectRegistry,
                ),
              ],
            ],
            const SizedBox(height: 18),
            const PrivacyNote(
              text:
                  'A lookup is a read. It does not add to the record for this '
                  'address, so nobody can build a reputation for a scam ID by '
                  'querying it repeatedly.',
            ),
          ],
        ),
      ),
    ),
  );

  /// [silent] is used by the poller and by pull-to-refresh: it keeps the
  /// existing report on screen instead of flashing a spinner over it, and it
  /// swallows a failed refresh rather than replacing a good result with an
  /// error. A dropped poll is not news; the next one is five seconds away.
  Future<void> _lookup({bool silent = false}) async {
    if (_loading) {
      return;
    }
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final IdentifierCheck check = await widget.services.api.checkIdentifier(
        _controller.text,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _check = check;
        _refreshedAt = DateTime.now();
      });
      // Nothing to poll for an input that named no address.
      if (check.addresses.isNotEmpty) {
        _startAutoRefresh();
      } else {
        _refreshTimer?.cancel();
        _refreshTimer = null;
      }
    } on ApiException catch (error) {
      if (!mounted || silent) {
        return;
      }
      setState(() {
        _loading = false;
        _error = error.message;
      });
    } on FormatException catch (error) {
      if (!mounted || silent) {
        return;
      }
      setState(() {
        _loading = false;
        _error = error.message.toString();
      });
    }
  }
}

/// Says when the figures above were last read, so a stale screen cannot be
/// mistaken for a live one during a demo.
class _RefreshedAtLabel extends StatelessWidget {
  const _RefreshedAtLabel({required this.refreshedAt});

  final DateTime? refreshedAt;

  @override
  Widget build(BuildContext context) {
    final DateTime? moment = refreshedAt;
    if (moment == null) {
      return const SizedBox.shrink();
    }
    final int seconds = DateTime.now().difference(moment).inSeconds;
    final String age = seconds < 10
        ? 'just now'
        : seconds < 60
        ? '$seconds seconds ago'
        : '${(seconds / 60).floor()} min ago';
    return Row(
      key: const Key('trust_refreshed_at'),
      children: <Widget>[
        const Icon(Icons.sync, size: 14, color: AppColors.inkMuted),
        const SizedBox(width: 6),
        Text(
          'Updated $age. Refreshing every 5 seconds.',
          style: Theme.of(
            context,
          ).textTheme.labelSmall?.copyWith(color: AppColors.inkMuted),
        ),
      ],
    );
  }
}

/// States what the input turned out to be and what the network knows about it.
///
/// This carries the whole answer when a mobile number matched nothing, which
/// is the common case and the one most likely to be misread as reassurance.
class _CheckSummary extends StatelessWidget {
  const _CheckSummary({required this.check});

  final IdentifierCheck check;

  @override
  Widget build(BuildContext context) {
    final bool unusable = check.kind == IdentifierKind.unsupported;
    return Container(
      key: const Key('identifier_check_summary'),
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: unusable ? AppColors.cautionSurface : AppColors.surfaceMuted,
        border: Border.all(
          color: unusable ? AppColors.caution : AppColors.border,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                check.kind.label.toUpperCase(),
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: AppColors.tealDark,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.1,
                ),
              ),
              if (!unusable) ...<Widget>[
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    check.value,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: AppColors.inkMuted,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          Text(
            check.reason ?? check.summary,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(height: 1.5),
          ),
        ],
      ),
    );
  }
}
