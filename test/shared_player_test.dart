// Tests for the shared player (AudioPlayerNotifier as the single
// player behind the mini-player, play buttons and media notification):
// queue-aware play/next/previous/stop/seek, pause/resume toggle,
// completion auto-advance, position/duration state, and the playback
// failure reasons (item 3). No platform audio is touched: playback
// goes through a fake AudioBackend.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_man/data/fallback/fallback_sources.dart';
import 'package:music_man/data/models/music_models.dart';
import 'package:music_man/presentation/providers/audio_backend.dart';
import 'package:music_man/presentation/providers/generation_provider.dart';

class FakeAudioBackend implements AudioBackend {
  final stateController = StreamController<PlayerState>.broadcast();
  final positionController = StreamController<Duration>.broadcast();
  final durationController = StreamController<Duration>.broadcast();
  final playedUrls = <String>[];
  Object? playError;
  int pauseCalls = 0;
  int resumeCalls = 0;
  int stopCalls = 0;
  Duration? lastSeek;

  @override
  Stream<PlayerState> get onPlayerStateChanged => stateController.stream;
  @override
  Stream<Duration> get onPositionChanged => positionController.stream;
  @override
  Stream<Duration> get onDurationChanged => durationController.stream;

  @override
  Future<void> play(String url) async {
    if (playError != null) throw playError!;
    playedUrls.add(url);
    stateController.add(PlayerState.playing);
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    stateController.add(PlayerState.paused);
  }

  @override
  Future<void> resume() async {
    resumeCalls++;
    stateController.add(PlayerState.playing);
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    stateController.add(PlayerState.stopped);
  }

  @override
  Future<void> seek(Duration position) async {
    lastSeek = position;
    positionController.add(position);
  }

  @override
  Future<void> dispose() async {
    await stateController.close();
    await positionController.close();
    await durationController.close();
  }
}

const _trackA = Track(
  artist: 'Singer A',
  title: 'Song A',
  previewUrl: 'https://example.com/a.m4a',
);
const _trackB = Track(
  artist: 'Singer B',
  title: 'Song B',
  previewUrl: 'https://example.com/b.m4a',
);
const _trackC = Track(
  artist: 'Singer C',
  title: 'Song C',
  previewUrl: 'https://example.com/c.m4a',
);

AudioPlayerNotifier _notifier(FakeAudioBackend backend,
        {FallbackSources? fallbacks}) =>
    AudioPlayerNotifier(fallbacks ?? FallbackSources(), backend: backend);

Future<void> _pump() => Future<void>.delayed(Duration.zero);

void main() {
  group('play / pause / resume', () {
    test('play loads the track, queue and playing state', () async {
      final backend = FakeAudioBackend();
      final notifier = _notifier(backend);
      await notifier.play(_trackA, queue: [_trackA, _trackB, _trackC]);
      expect(backend.playedUrls, ['https://example.com/a.m4a']);
      expect(notifier.state.isPlaying, isTrue);
      expect(notifier.state.currentTrack, _trackA);
      expect(notifier.state.queue, [_trackA, _trackB, _trackC]);
      expect(notifier.state.queueIndex, 0);
      expect(notifier.state.hasNext, isTrue);
      expect(notifier.state.hasPrevious, isFalse);
    });

    test('tapping the playing track pauses it, tapping again resumes',
        () async {
      final backend = FakeAudioBackend();
      final notifier = _notifier(backend);
      await notifier.play(_trackA, queue: [_trackA, _trackB]);
      await notifier.play(_trackA);
      expect(backend.pauseCalls, 1);
      expect(notifier.state.isPlaying, isFalse);
      // The paused track stays loaded, so the bar can resume it.
      expect(notifier.state.currentTrack, _trackA);
      await notifier.play(_trackA);
      expect(backend.resumeCalls, 1);
      expect(notifier.state.isPlaying, isTrue);
    });

    test('togglePlayPause pauses, then resumes, then does nothing stopped',
        () async {
      final backend = FakeAudioBackend();
      final notifier = _notifier(backend);
      await notifier.togglePlayPause();
      expect(backend.pauseCalls, 0);
      await notifier.play(_trackA);
      await notifier.togglePlayPause();
      expect(backend.pauseCalls, 1);
      expect(notifier.state.isPlaying, isFalse);
      await notifier.togglePlayPause();
      expect(backend.resumeCalls, 1);
      expect(notifier.state.isPlaying, isTrue);
    });
  });

  group('queue navigation', () {
    test('next and previous walk the queue', () async {
      final backend = FakeAudioBackend();
      final notifier = _notifier(backend);
      await notifier.play(_trackA, queue: [_trackA, _trackB, _trackC]);
      await notifier.next();
      expect(notifier.state.currentTrack, _trackB);
      expect(notifier.state.queueIndex, 1);
      expect(backend.playedUrls.last, 'https://example.com/b.m4a');
      await notifier.next();
      expect(notifier.state.currentTrack, _trackC);
      await notifier.previous();
      expect(notifier.state.currentTrack, _trackB);
    });

    test('next at the end is a no-op', () async {
      final backend = FakeAudioBackend();
      final notifier = _notifier(backend);
      await notifier.play(_trackA, queue: [_trackA, _trackB]);
      await notifier.next();
      await notifier.next();
      expect(notifier.state.currentTrack, _trackB);
      expect(backend.playedUrls, hasLength(2));
    });

    test('previous restarts the track when well into it', () async {
      final backend = FakeAudioBackend();
      final notifier = _notifier(backend);
      await notifier.play(_trackA, queue: [_trackA, _trackB]);
      await notifier.next();
      backend.positionController.add(const Duration(seconds: 10));
      await _pump();
      await _pump();
      await notifier.previous();
      expect(backend.lastSeek, Duration.zero);
      expect(notifier.state.currentTrack, _trackB);
    });

    test('previous goes back when near the start', () async {
      final backend = FakeAudioBackend();
      final notifier = _notifier(backend);
      await notifier.play(_trackA, queue: [_trackA, _trackB]);
      await notifier.next();
      backend.positionController.add(const Duration(seconds: 1));
      await _pump();
      await _pump();
      await notifier.previous();
      expect(notifier.state.currentTrack, _trackA);
      expect(backend.lastSeek, isNull);
    });

    test('completion advances to the next track, then stops at the end',
        () async {
      final backend = FakeAudioBackend();
      final notifier = _notifier(backend);
      await notifier.play(_trackA, queue: [_trackA, _trackB]);
      backend.stateController.add(PlayerState.completed);
      await _pump();
      await _pump();
      expect(notifier.state.currentTrack, _trackB);
      expect(notifier.state.isPlaying, isTrue);
      backend.stateController.add(PlayerState.completed);
      await _pump();
      await _pump();
      expect(notifier.state.currentTrack, isNull);
      expect(notifier.state.isPlaying, isFalse);
    });
  });

  group('stop / seek / position', () {
    test('stop clears the player and the bar', () async {
      final backend = FakeAudioBackend();
      final notifier = _notifier(backend);
      await notifier.play(_trackA, queue: [_trackA, _trackB]);
      // (play itself stops the backend once first, to cut any
      // previous stream — so measure the delta across stop().)
      final stopsBefore = backend.stopCalls;
      await notifier.stop();
      expect(backend.stopCalls, stopsBefore + 1);
      expect(notifier.state.currentTrack, isNull);
      expect(notifier.state.isPlaying, isFalse);
      expect(notifier.state.queue, isEmpty);
      expect(notifier.state.queueIndex, -1);
    });

    test('seek updates the backend and the position', () async {
      final backend = FakeAudioBackend();
      final notifier = _notifier(backend);
      await notifier.play(_trackA);
      await notifier.seek(const Duration(seconds: 12));
      expect(backend.lastSeek, const Duration(seconds: 12));
      expect(notifier.state.position, const Duration(seconds: 12));
    });

    test('position and duration streams update the state', () async {
      final backend = FakeAudioBackend();
      final notifier = _notifier(backend);
      await notifier.play(_trackA);
      backend.positionController.add(const Duration(seconds: 5));
      backend.durationController.add(const Duration(seconds: 30));
      await _pump();
      await _pump();
      expect(notifier.state.position, const Duration(seconds: 5));
      expect(notifier.state.duration, const Duration(seconds: 30));
      expect(notifier.state.progressFraction, closeTo(5 / 30, 0.001));
    });
  });

  group('playStream', () {
    test('plays the given URL directly with the given queue', () async {
      final backend = FakeAudioBackend();
      final notifier = _notifier(backend);
      await notifier.playStream(_trackA, 'https://example.com/full.mp3',
          source: 'full', queue: [_trackA, _trackB]);
      expect(backend.playedUrls, ['https://example.com/full.mp3']);
      expect(notifier.state.isPlaying, isTrue);
      expect(notifier.state.currentTrack, _trackA);
      expect(notifier.state.queueIndex, 0);
      expect(notifier.previewSourceFor(_trackA), 'full');
    });
  });

  group('playback failure reasons', () {
    test('no preview anywhere records the reason and stays stopped',
        () async {
      final dio = Dio();
      dio.httpClientAdapter = _EmptyAdapter();
      final backend = FakeAudioBackend();
      final notifier =
          _notifier(backend, fallbacks: FallbackSources(dio));
      const track = Track(artist: 'Nobody', title: 'No Such Song');
      await notifier.play(track);
      expect(notifier.state.currentTrack, isNull);
      expect(notifier.state.isPlaying, isFalse);
      expect(notifier.state.lastError, 'No preview found for this track');
      expect(notifier.state.errorSeq, 1);
      expect(backend.playedUrls, isEmpty);
    });

    test('a network load failure says to check the connection', () async {
      final backend = FakeAudioBackend()
        ..playError = Exception('SocketException: Failed host lookup');
      final notifier = _notifier(backend);
      await notifier.play(_trackA);
      expect(notifier.state.isPlaying, isFalse);
      expect(notifier.state.currentTrack, _trackA);
      expect(notifier.state.lastError,
          "Couldn't load audio — check your connection");
      expect(notifier.state.errorSeq, 1);
    });

    test('a non-network load failure stays generic', () async {
      final backend = FakeAudioBackend()..playError = Exception('boom');
      final notifier = _notifier(backend);
      await notifier.play(_trackA);
      expect(notifier.state.lastError, "Couldn't play this track");
    });

    test('playbackErrorMessage maps the cases directly', () {
      expect(
        AudioPlayerNotifier.playbackErrorMessage('', noPreview: true),
        'No preview found for this track',
      );
      expect(
        AudioPlayerNotifier.playbackErrorMessage(
            Exception('SocketException: Failed host lookup')),
        "Couldn't load audio — check your connection",
      );
      expect(
        AudioPlayerNotifier.playbackErrorMessage(
            Exception('Connection timed out')),
        "Couldn't load audio — check your connection",
      );
      expect(
        AudioPlayerNotifier.playbackErrorMessage(Exception('boom')),
        "Couldn't play this track",
      );
    });
  });
}

/// Answers empty iTunes/Deezer results for every request, so the
/// on-demand preview chain finds nothing (no live network).
class _EmptyAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await requestStream?.drain<void>();
    return ResponseBody.fromString(
      jsonEncode({'results': []}),
      200,
      headers: {Headers.contentTypeHeader: ['application/json']},
    );
  }

  @override
  void close({bool force = false}) {}
}
