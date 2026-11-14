// Minimal seam over audioplayers so the shared player
// (AudioPlayerNotifier) is unit-testable without a platform audio
// channel: audioplayers' AudioPlayer constructor touches the platform,
// which has no registered plugin in a flutter_test environment.
// Production uses [AudioplayersBackend]; tests inject a fake.

import 'package:audioplayers/audioplayers.dart';

/// The only audio operations the shared player needs.
abstract class AudioBackend {
  Stream<PlayerState> get onPlayerStateChanged;
  Stream<Duration> get onPositionChanged;
  Stream<Duration> get onDurationChanged;

  Future<void> play(String url);
  Future<void> pause();
  Future<void> resume();
  Future<void> stop();
  Future<void> seek(Duration position);
  Future<void> dispose();
}

/// [AudioBackend] backed by a real audioplayers [AudioPlayer].
class AudioplayersBackend implements AudioBackend {
  final AudioPlayer _player;

  AudioplayersBackend([AudioPlayer? player])
      : _player = player ?? AudioPlayer();

  @override
  Stream<PlayerState> get onPlayerStateChanged =>
      _player.onPlayerStateChanged;

  @override
  Stream<Duration> get onPositionChanged => _player.onPositionChanged;

  @override
  Stream<Duration> get onDurationChanged => _player.onDurationChanged;

  @override
  Future<void> play(String url) => _player.play(UrlSource(url));

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> resume() => _player.resume();

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> dispose() => _player.dispose();
}
