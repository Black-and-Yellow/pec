import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/app_config.dart';
import '../models/payment.dart';

abstract interface class ExternalActions {
  Future<void> openUpi(String rawUri);

  Future<void> openCybercrimePortal();

  Future<void> openSuspectRegistry();

  Future<void> shareTrustedContact(String message, {Rect? origin});

  Future<void> messageTrustedContact(String phoneDigits, String message);

  Future<void> openDialer(String telUri);

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
  Future<void> openSuspectRegistry() async {
    final bool opened = await launchUrl(
      AppConfig.suspectRegistry,
      mode: LaunchMode.externalApplication,
    );
    if (!opened) {
      throw const ExternalActionException(
        'The government suspect registry could not be opened. You can reach it '
        'from cybercrime.gov.in under "Report & Check Suspect".',
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
  Future<void> messageTrustedContact(String phoneDigits, String message) async {
    if (!RegExp(r'^\d{10,15}$').hasMatch(phoneDigits)) {
      throw const ExternalActionException(
        'The trusted-contact number is invalid.',
      );
    }
    final Uri whatsapp = Uri.https('wa.me', '/$phoneDigits', <String, String>{
      'text': message,
    });
    try {
      if (await launchUrl(whatsapp, mode: LaunchMode.externalApplication)) {
        return;
      }
    } on Object {
      // Try the device SMS handler next.
    }
    final Uri sms = Uri(
      scheme: 'sms',
      path: phoneDigits,
      queryParameters: <String, String>{'body': message},
    );
    try {
      if (await launchUrl(sms, mode: LaunchMode.externalApplication)) {
        return;
      }
    } on Object {
      // The caller will offer the existing share-sheet fallback.
    }
    throw const ExternalActionException(
      'Could not open WhatsApp or SMS. Use the share sheet instead.',
    );
  }

  @override
  Future<void> openDialer(String telUri) async {
    final Uri? uri = Uri.tryParse(telUri);
    if (uri == null || uri.scheme != 'tel' || uri.path.isEmpty) {
      throw const ExternalActionException('The phone number is invalid.');
    }
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      throw const ExternalActionException(
        'The phone dialer could not be opened.',
      );
    }
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
