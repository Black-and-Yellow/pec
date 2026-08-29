import 'package:flutter/material.dart';

import '../models/risk.dart';
import '../models/trusted_contact.dart';
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
  const FinGuardBrand({super.key, this.compact = false, this.inverse = false});

  final bool compact;
  final bool inverse;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      Container(
        width: compact ? 34 : 42,
        height: compact ? 34 : 42,
        decoration: BoxDecoration(
          color: AppColors.teal,
          borderRadius: BorderRadius.circular(compact ? 11 : 14),
        ),
        child: Icon(
          Icons.shield_rounded,
          color: AppColors.ink,
          size: compact ? 19 : 23,
          semanticLabel: 'FinGuard shield',
        ),
      ),
      const SizedBox(width: 10),
      Text(
        'FinGuard',
        style: Theme.of(context).textTheme.titleLarge?.copyWith(
          color: inverse ? Colors.white : AppColors.ink,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.7,
        ),
      ),
    ],
  );
}

class WorkspacePanel extends StatelessWidget {
  const WorkspacePanel({required this.child, super.key, this.padding});

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: AppColors.surface,
      border: Border.all(color: AppColors.border),
      borderRadius: BorderRadius.circular(20),
    ),
    clipBehavior: Clip.antiAlias,
    child: Padding(padding: padding ?? EdgeInsets.zero, child: child),
  );
}

class WorkspaceAction extends StatelessWidget {
  const WorkspaceAction({
    required this.icon,
    required this.label,
    required this.description,
    required this.onTap,
    super.key,
    this.emphasized = false,
  });

  final IconData icon;
  final String label;
  final String description;
  final VoidCallback onTap;
  final bool emphasized;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    child: Material(
      color: emphasized ? AppColors.tealSoft : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        hoverColor: AppColors.tealSoft.withValues(alpha: 0.55),
        focusColor: AppColors.tealSoft,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 17),
          child: Row(
            children: <Widget>[
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: emphasized ? AppColors.teal : AppColors.surfaceMuted,
                  border: emphasized
                      ? null
                      : Border.all(color: AppColors.border),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, size: 20, color: AppColors.ink),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(label, style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(
                      description,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppColors.inkMuted,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
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

class AsyncFilledButton extends StatelessWidget {
  const AsyncFilledButton({
    required this.buttonKey,
    required this.loading,
    required this.onPressed,
    required this.icon,
    required this.label,
    required this.loadingLabel,
    super.key,
    this.loadingSemanticsLabel,
  });

  final Key buttonKey;
  final bool loading;
  final VoidCallback? onPressed;
  final IconData icon;
  final String label;
  final String loadingLabel;
  final String? loadingSemanticsLabel;

  @override
  Widget build(BuildContext context) => Semantics(
    container: loading,
    liveRegion: loading,
    label: loading ? loadingSemanticsLabel ?? loadingLabel : null,
    child: ExcludeSemantics(
      excluding: loading,
      child: SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          key: buttonKey,
          onPressed: loading ? null : onPressed,
          icon: loading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : Icon(icon),
          label: Text(loading ? loadingLabel : label),
        ),
      ),
    ),
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
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: foreground.withValues(alpha: 0.28)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, color: foreground, size: 19),
            const SizedBox(width: 7),
            Flexible(
              child: Text(
                level.label,
                softWrap: true,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: foreground,
                  letterSpacing: 0.5,
                ),
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
              ? FilledButton.styleFrom(
                  backgroundColor: AppColors.danger,
                  foregroundColor: Colors.white,
                )
              : null,
          onPressed: () => Navigator.pop(context, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

Future<TrustedContact?> showTrustedContactEditor(
  BuildContext context, {
  TrustedContact? initial,
}) async {
  final TextEditingController nameController = TextEditingController(
    text: initial?.name ?? '',
  );
  final TextEditingController phoneController = TextEditingController(
    text: initial?.phone ?? '',
  );
  bool attempted = false;
  final TrustedContact? result = await showDialog<TrustedContact>(
    context: context,
    builder: (BuildContext dialogContext) => StatefulBuilder(
      builder: (BuildContext context, StateSetter setDialogState) {
        final String name = nameController.text.trim();
        final String? phone = TrustedContact.normalizePhone(
          phoneController.text,
        );
        final bool nameValid = name.isNotEmpty && name.length <= 40;
        return AlertDialog(
          scrollable: true,
          title: Text(
            initial == null ? 'Save a trusted contact' : 'Edit trusted contact',
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Text(
                'The name and phone number stay on this device and are never sent to FinGuard servers.',
              ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('trusted_contact_name_field'),
                controller: nameController,
                maxLength: 40,
                onChanged: (_) => setDialogState(() {}),
                decoration: InputDecoration(
                  labelText: 'Name',
                  errorText: attempted && !nameValid
                      ? 'Enter a name between 1 and 40 characters.'
                      : null,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const Key('trusted_contact_phone_field'),
                controller: phoneController,
                keyboardType: TextInputType.phone,
                onChanged: (_) => setDialogState(() {}),
                decoration: InputDecoration(
                  labelText: 'Phone number',
                  hintText: '+91 98765 43210',
                  errorText: attempted && phone == null
                      ? 'Enter a valid phone number with country code.'
                      : null,
                ),
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const Key('save_trusted_contact_button'),
              onPressed: () {
                if (!nameValid || phone == null) {
                  setDialogState(() => attempted = true);
                  return;
                }
                Navigator.pop(
                  dialogContext,
                  TrustedContact(name: name, phone: phone),
                );
              },
              child: const Text('Save contact'),
            ),
          ],
        );
      },
    ),
  );
  nameController.dispose();
  phoneController.dispose();
  return result;
}

void showActionError(BuildContext context, Object error) {
  final String message = error.toString().replaceFirst('Exception: ', '');
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}
