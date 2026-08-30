import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/risk.dart';
import '../services/voice_api.dart';
import '../theme/app_theme.dart';

/// Reads the verdict aloud in a language the user chooses.
///
/// This is an optional layer over a result that is already complete on screen.
/// It holds its own state and swallows its own failures on purpose: a person
/// deciding whether to pay must never be blocked, delayed, or misled by a
/// speaker that could not be reached. When the backend has no voice
/// configured, [languages] arrives empty and nothing is drawn at all.
///
/// It reports the level and score it was handed. It does not compute them, and
/// it cannot disagree with the card above it.
class ListenButton extends StatefulWidget {
  const ListenButton({
    required this.voice,
    required this.player,
    required this.level,
    required this.score,
    super.key,
  });

  final VoiceApi voice;
  final VoicePlayer player;
  final RiskLevel level;
  final int score;

  @override
  State<ListenButton> createState() => _ListenButtonState();
}

/// Plays MP3 bytes. Kept behind an interface so the widget can be tested
/// without an audio device, and so swapping the playback package later does
/// not reach into the screen.
abstract interface class VoicePlayer {
  Future<void> play(Uint8List audio);

  Future<void> stop();

  void dispose();
}

class _ListenButtonState extends State<ListenButton> {
  List<VoiceLanguage> _languages = const <VoiceLanguage>[];
  bool _busy = false;
  String? _failure;

  @override
  void initState() {
    super.initState();
    _loadLanguages();
  }

  Future<void> _loadLanguages() async {
    final List<VoiceLanguage> languages = await widget.voice
        .availableLanguages();
    if (mounted) {
      setState(() => _languages = languages);
    }
  }

  @override
  void dispose() {
    widget.player.dispose();
    super.dispose();
  }

  Future<void> _speak(VoiceLanguage language) async {
    if (_busy) {
      return;
    }
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      final Uint8List audio = await widget.voice.speak(
        level: widget.level,
        score: widget.score,
        language: language.code,
      );
      await widget.player.play(audio);
    } on VoiceException catch (error) {
      if (mounted) {
        setState(() => _failure = error.message);
      }
    } on Exception {
      if (mounted) {
        setState(
          () => _failure =
              'Spoken guidance could not be played. The result on screen still applies.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_languages.isEmpty) {
      return const SizedBox.shrink();
    }
    return Container(
      key: const Key('listen_button'),
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surfaceMuted,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(Icons.volume_up_outlined, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Listen in your language',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              if (_busy)
                const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'The same result, read aloud.',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: AppColors.inkMuted),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final VoiceLanguage language in _languages)
                OutlinedButton(
                  key: Key('listen_${language.code}'),
                  onPressed: _busy ? null : () => _speak(language),
                  child: Text(language.label),
                ),
            ],
          ),
          if (_failure case final String failure) ...<Widget>[
            const SizedBox(height: 10),
            Text(
              failure,
              key: const Key('listen_failure'),
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: AppColors.caution),
            ),
          ],
        ],
      ),
    );
  }
}
