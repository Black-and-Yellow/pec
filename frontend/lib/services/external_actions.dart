import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/app_config.dart';
import '../models/payment.dart';

abstract interface class ExternalActions {
  Future<void> openUpi(String rawUri);

  Future<void> openCybercrimePortal();

  Future<void> shareTrustedContact(String message, {Rect? origin});

  Future<void> copyText(String text);
}

final class PlatformExternalActions implements ExternalActions {
  @override
  Future<void> openUpi(String rawUri) async {
    final Uri uri = Payment.validateUpiUri(rawUri);
    final bool opened = await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
    );
    if (!opened) {
      throw const ExternalActionException(
        'No UPI app could open this request. You can cancel and try on a phone with a UPI app.',
      );
    }
  }

  @override
  Future<void> openCybercrimePortal() async {
    final bool opened = await launchUrl(
      AppConfig.cybercrimePortal,
      mode: LaunchMode.externalApplication,
    );
    if (!opened) {
      throw const ExternalActionException(
        'The official cybercrime portal could not be opened.',
      );
    }
  }

  @override
  Future<void> shareTrustedContact(String message, {Rect? origin}) async {
    await SharePlus.instance.share(
      ShareParams(
        text: message,
        subject: 'FinGuard safety check',
        sharePositionOrigin: origin,
      ),
    );
  }

  @override
  Future<void> copyText(String text) =>
      Clipboard.setData(ClipboardData(text: text));
}

final class ExternalActionException implements Exception {
  const ExternalActionException(this.message);

  final String message;

  @override
  String toString() => message;
}
