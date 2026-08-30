import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import '../models/risk.dart';

/// One language the spoken layer can read a verdict in.
final class VoiceLanguage {
  const VoiceLanguage({required this.code, required this.label});

  /// What the API accepts, e.g. `ta`.
  final String code;

  /// What the listener sees on the button, written in its own script.
  final String label;

  @override
  bool operator ==(Object other) =>
      other is VoiceLanguage && other.code == code && other.label == label;

  @override
  int get hashCode => Object.hash(code, label);
}

/// Raised when spoken guidance cannot be produced.
///
/// Every caller is expected to treat this as "no audio", never as "no
/// verdict": the written result the user is already looking at is unaffected.
final class VoiceException implements Exception {
  const VoiceException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Speaks a verdict the risk engine has already reached.
///
/// This talks to a route that exists alongside the scoring API rather than
/// inside it. Nothing here parses or alters a risk assessment; it sends the
/// level and score it was given and plays back what the server reads out.
abstract interface class VoiceApi {
  /// Languages this deployment can speak, or an empty list when the layer is
  /// switched off. Never throws: a deployment without voice is a normal
  /// deployment, not an error.
  Future<List<VoiceLanguage>> availableLanguages();

  /// MP3 audio of the fixed statement for this verdict.
  Future<Uint8List> speak({
    required RiskLevel level,
    required int score,
    required String language,
  });
}

final class VoiceApiService implements VoiceApi {
  VoiceApiService({
    required Uri baseUri,
    http.Client? client,
    this.timeout = _voiceTimeout,
  }) : _baseUri = baseUri,
       _client = client ?? http.Client();

  /// Longer than [AppConfig.apiTimeout], because synthesising a clip the
  /// server has not cached yet is slower than answering a scoring call, and a
  /// listener waiting for audio is not blocked from reading the screen.
  static const Duration _voiceTimeout = Duration(seconds: 25);

  /// A spoken verdict is a few seconds of speech. A far larger body means
  /// something other than our own clip is on the wire.
  static const int _maxAudioBytes = 5 * 1024 * 1024;

  final Uri _baseUri;
  final http.Client _client;
  final Duration timeout;

  @override
  Future<List<VoiceLanguage>> availableLanguages() async {
    try {
      final http.Response response = await _client
          .get(
            _baseUri.resolve('api/v1/voice/languages'),
            headers: const <String, String>{'accept': 'application/json'},
          )
          .timeout(timeout);
      if (response.statusCode != 200) {
        return const <VoiceLanguage>[];
      }
      final Object? decoded = jsonDecode(response.body);
      if (decoded is! Map<Object?, Object?> || decoded['enabled'] != true) {
        return const <VoiceLanguage>[];
      }
      final Object? languages = decoded['languages'];
      if (languages is! List<Object?>) {
        return const <VoiceLanguage>[];
      }
      return languages
          .whereType<Map<Object?, Object?>>()
          .map(_languageFrom)
          .whereType<VoiceLanguage>()
          .toList(growable: false);
    } on Exception {
      // The listen control simply does not appear. A backend that cannot
      // answer this question must not stop the rest of the app working.
      return const <VoiceLanguage>[];
    }
  }

  static VoiceLanguage? _languageFrom(Map<Object?, Object?> json) {
    final Object? code = json['code'];
    final Object? label = json['label'];
    if (code is! String || label is! String) {
      return null;
    }
    if (code.isEmpty || code.length > 8 || label.isEmpty || label.length > 32) {
      return null;
    }
    return VoiceLanguage(code: code, label: label);
  }

  @override
  Future<Uint8List> speak({
    required RiskLevel level,
    required int score,
    required String language,
  }) async {
    try {
      final http.Response response = await _client
          .post(
            _baseUri.resolve('api/v1/voice/speak'),
            headers: const <String, String>{
              'accept': 'audio/mpeg',
              'content-type': 'application/json',
            },
            body: jsonEncode(<String, Object?>{
              'level': level.apiValue,
              'score': score,
              'language': language,
            }),
          )
          .timeout(timeout);
      if (response.statusCode != 200) {
        throw const VoiceException(
          'Spoken guidance is unavailable right now. The result on screen still applies.',
        );
      }
      final Uint8List audio = response.bodyBytes;
      if (audio.isEmpty || audio.length > _maxAudioBytes) {
        throw const VoiceException('The spoken guidance could not be played.');
      }
      return audio;
    } on TimeoutException {
      throw const VoiceException(
        'Spoken guidance took too long. The result on screen still applies.',
      );
    } on http.ClientException {
      throw const VoiceException(
        'FinGuard cannot reach the voice service. The result on screen still applies.',
      );
    } on FormatException {
      throw const VoiceException('The spoken guidance could not be played.');
    }
  }
}
