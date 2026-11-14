// Tests for the media notification handler (item 5): the
// audio_service AudioHandler mirrors the shared player into
// playbackState / mediaItem / queue, and control calls drive the
// player. No platform audio or notification is touched: playback
// goes through a fake AudioBackend, and only the handler's Dart-side
// state is asserted — the live shade check is the user's phone QA.

import 'dart:async';

import 'package:audio_service/audio_service.dart' as audioservice;
import 'package:flutter_test/flutter_test.dart';
import 'package:music_man/data/fallback/fallback_sources.dart';
import 'package:music_man/data/models/music_models.dart';
import 'package:music_man/presentation/providers/generation_provider.dart';
import 'package:music_man/presentation/providers/media_notification_handler.dart';

import 'fake_audio_backend.dart';

const _trackA = Track(
  artist: 'Singer A',
  title: 'Song A',
  previewUrl: 'https://example.com/a.m4a',
  imageUrl: 'https://example.com/a.jpg',
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
const _trackNoPreview = Track(
  artist: 'Singer X',
  title: 'Song X',
);

AudioPlayerNotifier _notifier(FakeAudioBackend backend,
        {FallbackSources? fallbacks}) =>
    AudioPlayerNotifier(fallbacks ?? FallbackSources(), backend: backend);

Future<void> _pump() => Future<void>.delayed(Duration.zero);

void main() {
  group('initial state', () {
    test('starts idle with no media item or queue', () {
      final backend = FakeAudioBackend();
      final notifier = _notifier(backend);
      final handler = MusicManAudioHandler(notifier);
      addTearDown(handler.dispose);
      expect(handler.playbackState.value.processingState,
          audioservice.AudioProcessingState.idle);
      expect(handler.playbackState.value.playing, isFalse);
      expect(handler.mediaItem.value, isNull);
      expect(handler.queue.value, isEmpty);
    });
  });

  group('play / pause / stop mirroring', () {
    test('playing a track publishes playing state, item and queue',
        () async {
      final backend = FakeAudioBackend();
      final notifier = _notifier(backend);
      final handler = MusicManAudioHandler(notifier);
      addTearDown(handler.dispose);
      await notifier.play(_trackA, queue: [_trackA, _trackB, _trackC]);
      await _pump();
      final state = handler.playbackState.value;
      expect(state.playing, isTrue);
      expect(state.processingState, audioservice.AudioProcessingState.ready);
      expect(state.queueIndex, 0);
      // Playing: previous, pause, stop, next; compact shows prev,
      // play/pause, next.
      expect(
          state.controls.map((c) => c.action).toList(),
          [
            audioservice.MediaAction.skipToPrevious,
            audioservice.MediaAction.pause,
            audioservice.MediaAction.stop,
            audioservice.MediaAction.skipToNext,
          ]);
      expect(state.androidCompactActionIndices, [0, 1, 3]);
      final item = handler.mediaItem.value!;
      expect(item.id, MusicManAudioHandler.mediaItemIdFor(_trackA));
      expect(item.title, 'Song A');
      expect(item.artist, 'Singer A');
      expect(item.artUri, Uri.parse('https://example.com/a.jpg'));
      expect(
          handler.queue.value.map((m) => m.title).toList(),
          ['Song A', 'Song B', 'Song C']);
    });

    test('pause and play through the handler drive the player',
        () async {
      final backend = FakeAudioBackend();
      final notifier = _notifier(backend);
      final handler = MusicManAudioHandler(notifier);
      addTearDown(handler.dispose);
      await notifier.play(_trackA, queue: [_trackA, _trackB]);
      await handler.pause();
      await _pump();
      expect(backend.pauseCalls, 1);
      expect(handler.playbackState.value.playing, isFalse);
      expect(
          handler.playbackState.value.controls[1].action,
          audioservice.MediaAction.play);
      // Paused, not stopped: the notification stays, the item stays.
      expect(handler.playbackState.value.processingState,
          audioservice.AudioProcessingState.ready);
      expect(handler.mediaItem.value?.title, 'Song A');
      await handler.play();
      await _pump();
      expect(backend.resumeCalls, 1);
      expect(handler.playbackState.value.playing, isTrue);
    });

    test('stop clears the player and broadcasts idle', () async {
      final backend = FakeAudioBackend();
      final notifier = _notifier(backend);
      final handler = MusicManAudioHandler(notifier);
      addTearDown(handler.dispose);
      await notifier.play(_trackA, queue: [_trackA, _trackB]);
      await handler.stop();
      await _pump();
      expect(notifier.state, PlaybackState.idle);
      // Idle is what makes audio_service stop the foreground service
      // and remove the notification.
      expect(handler.playbackState.value.processingState,
          audioservice.AudioProcessingState.idle);
      expect(handler.playbackState.value.playing, isFalse);
      expect(handler.mediaItem.value, isNull);
      expect(handler.queue.value, isEmpty);
    });

    test('swiping the notification away stops playback', () async {
      final backend = FakeAudioBackend();
      final notifier = _notifier(backend);
      final handler = MusicManAudioHandler(notifier);
      addTearDown(handler.dispose);
      await notifier.play(_trackA, queue: [_trackA, _trackB]);
      // BaseAudioHandler maps notification dismissal to stop().
      await handler.onNotificationDeleted();
      await _pump();
      expect(notifier.state, PlaybackState.idle);
      expect(handler.playbackState.value.processingState,
          audioservice.AudioProcessingState.idle);
    });
  });

  group('next / previous / seek / queue', () {
    test('skipToNext / skipToPrevious change the media item', () async {
      final backend = FakeAudioBackend();
      final notifier = _notifier(backend);
      final handler = MusicManAudioHandler(notifier);
      addTearDown(handler.dispose);
      await notifier.play(_trackA, queue: [_trackA, _trackB, _trackC]);
      await handler.skipToNext();
      await _pump();
      expect(handler.mediaItem.value?.title, 'Song B');
      expect(handler.playbackState.value.queueIndex, 1);
      await handler.skipToPrevious();
      await _pump();
      expect(handler.mediaItem.value?.title, 'Song A');
      expect(handler.playbackState.value.queueIndex, 0);
    });

    test('seek delegates to the player and jumps the position',
        () async {
      final backend = FakeAudioBackend();
      final notifier = _notifier(backend);
      final handler = MusicManAudioHandler(notifier);
      addTearDown(handler.dispose);
      await notifier.play(_trackA, queue: [_trackA, _trackB]);
      await handler.seek(const Duration(seconds: 10));
      expect(backend.lastSeek, const Duration(seconds: 10));
      expect(handler.playbackState.value.updatePosition,
          const Duration(seconds: 10));
    });

    test('playMediaItem plays the matching queue track', () async {
      final backend = FakeAudioBackend();
      final notifier = _notifier(backend);
      final handler = MusicManAudioHandler(notifier);
      addTearDown(handler.dispose);
      await notifier.play(_trackA, queue: [_trackA, _trackB, _trackC]);
      await handler.playMediaItem(audioservice.MediaItem(
        id: MusicManAudioHandler.mediaItemIdFor(_trackC),
        title: 'Song C',
      ));
      await _pump();
      expect(notifier.state.currentTrack, _trackC);
      expect(handler.mediaItem.value?.title, 'Song C');
      expect(handler.playbackState.value.queueIndex, 2);
    });

    test('skipToQueueItem plays that queue index', () async {
      final backend = FakeAudioBackend();
      final notifier = _notifier(backend);
      final handler = MusicManAudioHandler(notifier);
      addTearDown(handler.dispose);
      await notifier.play(_trackA, queue: [_trackA, _trackB, _trackC]);
      await handler.skipToQueueItem(1);
      await _pump();
      expect(handler.mediaItem.value?.title, 'Song B');
    });
  });

  group('loading / failure', () {
    test('resolving the next track shows loading, then an error',
        () async {
      final backend = FakeAudioBackend();
      final completer = Completer<String?>();
      final fallbacks = _GatedFallbacks(completer.future);
      final notifier = _notifier(backend, fallbacks: fallbacks);
      final handler = MusicManAudioHandler(notifier);
      addTearDown(handler.dispose);
      await notifier.play(_trackA, queue: [_trackA, _trackNoPreview]);
      // Next track has no preview anywhere; the resolve hangs on the
      // gated fallback, so the handler must show loading meanwhile.
      final next = handler.skipToNext();
      await _pump();
      expect(handler.playbackState.value.processingState,
          audioservice.AudioProcessingState.loading);
      // The resolve finds nothing: error state with the reason.
      completer.complete(null);
      await next;
      await _pump();
      expect(handler.playbackState.value.processingState,
          audioservice.AudioProcessingState.error);
      expect(handler.playbackState.value.errorMessage,
          'No preview found for this track');
    });

    test('a backend load failure surfaces as an error state', () async {
      final backend = FakeAudioBackend()..playError = Exception('boom');
      final notifier = _notifier(backend);
      final handler = MusicManAudioHandler(notifier);
      addTearDown(handler.dispose);
      await notifier.play(_trackA, queue: [_trackA, _trackB]);
      await _pump();
      expect(handler.playbackState.value.processingState,
          audioservice.AudioProcessingState.error);
      expect(handler.playbackState.value.errorMessage,
          "Couldn't play this track");
    });
  });
}

/// FallbackSources whose preview lookups all hang on one gated
/// future, so a test can observe the resolving window and then
/// decide the outcome. The Audius last resort is never reached: the
/// notifier under test has no Audius client.
class _GatedFallbacks extends FallbackSources {
  final Future<String?> _gated;
  _GatedFallbacks(this._gated);

  @override
  Future<String?> itunesTrackPreview(String artist, String title) =>
      _gated;

  @override
  Future<String?> deezerTrackPreview(String artist, String title) =>
      _gated;

  @override
  Future<String?> itunesTrackPreviewTitleOnly(
          String artist, String title) =>
      _gated;

  @override
  Future<String?> deezerTrackPreviewTitleOnly(
          String artist, String title) =>
      _gated;
}
