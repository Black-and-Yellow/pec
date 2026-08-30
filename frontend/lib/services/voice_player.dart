import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';

import '../widgets/listen_button.dart';

/// Plays synthesised verdict audio through the device speaker.
///
/// Bytes are played from memory rather than written to a file: the clip is a
/// spoken description of a payment the user is deciding about, and leaving
/// copies of it on disk would outlive the decision for no benefit.
final class DeviceVoicePlayer implements VoicePlayer {
  DeviceVoicePlayer({AudioPlayer? player}) : _player = player ?? AudioPlayer();

  final AudioPlayer _player;

  @override
  Future<void> play(Uint8List audio) async {
    // A second tap replaces the first clip instead of talking over it.
    await _player.stop();
    await _player.play(BytesSource(audio, mimeType: 'audio/mpeg'));
  }

  @override
  Future<void> stop() => _player.stop();

  @override
  void dispose() {
    _player.dispose();
  }
}
