import 'package:flutter/material.dart';

import '../models/risk.dart';
import '../theme/app_theme.dart';

class PageBody extends StatelessWidget {
  const PageBody({
    required this.child,
    super.key,
    this.maxWidth = 1040,
    this.padding,
  });

  final Widget child;
  final double maxWidth;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: SingleChildScrollView(
      padding:
          padding ??
          const EdgeInsets.only(left: 20, right: 20, top: 22, bottom: 40),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: child,
        ),
      ),
    ),
  );
}

class FinGuardBrand extends StatelessWidget {
  const FinGuardBrand({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      Container(
        width: compact ? 32 : 38,
        height: compact ? 32 : 38,
        decoration: BoxDecoration(
          color: AppColors.teal,
          borderRadius: BorderRadius.circular(9),
        ),
        child: Icon(
          Icons.shield_outlined,
          color: Colors.white,
          size: compact ? 19 : 22,
          semanticLabel: 'FinGuard shield',
        ),
      ),
      const SizedBox(width: 10),
      Text(
        'FinGuard',
        style: Theme.of(context).textTheme.titleLarge?.copyWith(
          color: AppColors.tealDark,
          letterSpacing: -0.4,
        ),
      ),
    ],
  );
}

class RiskBadge extends StatelessWidget {
  const RiskBadge({required this.level, super.key});

  final RiskLevel level;

  @override
  Widget build(BuildContext context) {
    final (Color foreground, Color background, IconData icon) = switch (level) {
      RiskLevel.safe => (
        AppColors.safe,
        AppColors.safeSurface,
        Icons.check_circle_outline,
      ),
      RiskLevel.caution => (
        AppColors.caution,
        AppColors.cautionSurface,
        Icons.error_outline,
      ),
      RiskLevel.highRisk => (
        AppColors.danger,
        AppColors.dangerSurface,
        Icons.gpp_bad_outlined,
      ),
    };
    return Semantics(
      label: 'Risk level ${level.label}',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: foreground.withValues(alpha: 0.28)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, color: foreground, size: 19),
            const SizedBox(width: 7),
            Text(
              level.label,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: foreground,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ErrorNotice extends StatelessWidget {
  const ErrorNotice({
    required this.message,
    super.key,
    this.onRetry,
    this.secondary,
  });

  final String message;
  final VoidCallback? onRetry;
  final Widget? secondary;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.dangerSurface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.danger.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Icon(Icons.cloud_off_outlined, color: AppColors.danger),
              const SizedBox(width: 10),
              Expanded(child: Text(message)),
            ],
          ),
          if (onRetry != null || secondary != null) ...<Widget>[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                if (onRetry != null)
                  TextButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Try again'),
                  ),
                ?secondary,
              ],
            ),
          ],
        ],
      ),
    ),
  );
}

class PrivacyNote extends StatelessWidget {
  const PrivacyNote({required this.text, super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      const Icon(Icons.lock_outline, size: 18, color: AppColors.inkMuted),
      const SizedBox(width: 8),
      Expanded(
        child: Text(
          text,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: AppColors.inkMuted,
            height: 1.4,
          ),
        ),
      ),
    ],
  );
}

Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  bool isDanger = false,
}) async {
  final bool? confirmed = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: isDanger
              ? FilledButton.styleFrom(backgroundColor: AppColors.danger)
              : null,
          onPressed: () => Navigator.pop(context, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

void showActionError(BuildContext context, Object error) {
  final String message = error.toString().replaceFirst('Exception: ', '');
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}
