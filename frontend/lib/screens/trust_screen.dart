import 'dart:async';

import 'package:flutter/material.dart';

import '../models/payee_trust.dart';
import '../services/api_service.dart';
import '../services/app_services.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import '../widgets/trust_report.dart';

/// Look up a UPI ID's standing before any payment request exists.
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
  PayeeTrust? _trust;
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
    appBar: AppBar(title: const Text('Check a UPI ID')),
    body: RefreshIndicator(
      // Pulling on an empty screen must not fire a lookup for a blank
      // address, so the gesture is a no-op until a report exists.
      onRefresh: () =>
          _trust == null ? Future<void>.value() : _lookup(silent: true),
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
              'Who is behind this UPI ID?',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 10),
            Text(
              'Paste a UPI ID to see how long the FinGuard network has known '
              'it, how many people have paid it, and what the address itself '
              'gives away. Nothing is paid and no UPI app is opened.',
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
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.search,
              autocorrect: false,
              enableSuggestions: false,
              onSubmitted: (_) => _lookup(),
              decoration: const InputDecoration(
                labelText: 'UPI ID',
                hintText: 'name@handle',
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
              label: 'Check reputation',
              loadingLabel: 'Checking…',
              loadingSemanticsLabel: 'Checking reputation',
            ),
            if (_trust case final PayeeTrust trust) ...<Widget>[
              const SizedBox(height: 26),
              TrustReportCard(trust: trust, initiallyExpanded: true),
              const SizedBox(height: 10),
              _RefreshedAtLabel(refreshedAt: _refreshedAt),
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
      final PayeeTrust trust = await widget.services.api.lookupPayeeTrust(
        _controller.text,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _trust = trust;
        _refreshedAt = DateTime.now();
      });
      _startAutoRefresh();
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
