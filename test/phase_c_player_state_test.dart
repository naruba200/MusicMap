// Phase C Group 1: player state — duration fetch, shuffle and
// repeat, queue editing, and the live flag. Notifier unit tests on
// the fake backend; no Hive, no platform audio.

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_man/data/fallback/fallback_sources.dart';
import 'package:music_man/data/models/music_models.dart';
import 'package:music_man/presentation/providers/generation_provider.dart';

import 'fake_audio_backend.dart';

const _trackA = Track(
  artist: 'Singer A',
  title: 'Song A',
  streamUrl: 'https://example.com/a.m4a',
);
const _trackB = Track(
  artist: 'Singer B',
  title: 'Song B',
  streamUrl: 'https://example.com/b.m4a',
);
const _trackC = Track(
  artist: 'Singer C',
  title: 'Song C',
  streamUrl: 'https://example.com/c.m4a',
);
const _trackD = Track(
  artist: 'Singer D',
  title: 'Song D',
  streamUrl: 'https://example.com/d.m4a',
);

const _queue = [_trackA, _trackB, _trackC, _trackD];

AudioPlayerNotifier _notifier(FakeAudioBackend backend) =>
    AudioPlayerNotifier(FallbackSources(), backend: backend);

Future<void> _pump() => Future<void>.delayed(Duration.zero);

Future<void> _pumpTimes(int n) async {
  for (var i = 0; i < n; i++) {
    await _pump();
  }
}

void main() {
  group('duration fetch', () {
    test('duration is fetched after play and kept, not cleared', () async {
      final backend = FakeAudioBackend()
        ..fakeDuration = const Duration(minutes: 3, seconds: 30);
      final notifier = _notifier(backend);
      await notifier.play(_trackA, queue: _queue);
      expect(notifier.state.duration,
          const Duration(minutes: 3, seconds: 30));
      expect(notifier.state.progressFraction, 0);
    });

    test('a duration event firing mid-play does not lose the fetch',
        () async {
      final backend = FakeAudioBackend()
        ..fakeDuration = const Duration(minutes: 3, seconds: 30)
        ..durationOnPlay = const Duration(minutes: 3, seconds: 30);
      final notifier = _notifier(backend);
      await notifier.play(_trackA, queue: _queue);
      expect(notifier.state.duration,
          const Duration(minutes: 3, seconds: 30));
      // Playing the next track re-fetches instead of clearing.
      backend.fakeDuration = const Duration(minutes: 2);
      backend.durationOnPlay = const Duration(minutes: 2);
      await notifier.next();
      expect(notifier.state.currentTrack, _trackB);
      expect(notifier.state.duration, const Duration(minutes: 2));
    });

    test('a null fetch leaves duration null, the event stays a backup',
        () async {
      final backend = FakeAudioBackend();
      final notifier = _notifier(backend);
      await notifier.play(_trackA, queue: _queue);
      expect(notifier.state.duration, isNull);
      backend.durationController.add(const Duration(seconds: 45));
      await _pumpTimes(2);
      expect(notifier.state.duration, const Duration(seconds: 45));
    });
  });

  group('shuffle', () {
    test('toggleShuffle builds an order with the current track first',
        () async {
      final backend = FakeAudioBackend();
      final notifier = _notifier(backend);
      await notifier.play(_trackA, queue: _queue);
      notifier.toggleShuffle();
      expect(notifier.state.shuffleEnabled, isTrue);
      final order = notifier.state.shuffledOrder;
      expect(order, hasLength(4));
      expect(order.toSet(), {0, 1, 2, 3});
      expect(order.first, 0);
      expect(notifier.state.shufflePosition, 0);
    });

    test('next and previous walk the shuffled order', () async {
      final backend = FakeAudioBackend();
      final notifier = _notifier(backend);
      await notifier.play(_trackA, queue: _queue);
      notifier.toggleShuffle();
      final order = [...notifier.state.shuffledOrder];
      await notifier.next();
      expect(notifier.state.queueIndex, order[1]);
      expect(notifier.state.currentTrack, _queue[order[1]]);
      await notifier.next();
      expect(notifier.state.queueIndex, order[2]);
      await notifier.previous();
      expect(notifier.state.queueIndex, order[1]);
      expect(notifier.state.currentTrack, _queue[order[1]]);
      // Walking to the end of the order with repeat off stops.
      await notifier.next();
      await notifier.next();
      expect(notifier.state.queueIndex, order[3]);
      await notifier.next();
      expect(notifier.state.queueIndex, order[3]);
      expect(notifier.state.currentTrack, _queue[order[3]]);
    });

    test('playAt re-anchors the shuffle position to the played track',
        () async {
      final backend = FakeAudioBackend();
      final notifier = _notifier(backend);
      await notifier.play(_trackA, queue: _queue);
      notifier.toggleShuffle();
      final order = [...notifier.state.shuffledOrder];
      await notifier.playAt(2);
      expect(notifier.state.currentTrack, _trackC);
      expect(notifier.state.queueIndex, 2);
      expect(notifier.state.shufflePosition, order.indexOf(2));
      // Next continues the shuffled walk from the played track.
      final pos = order.indexOf(2);
      if (pos + 1 < order.length) {
        await notifier.next();
        expect(notifier.state.queueIndex, order[pos + 1]);
      }
    });

    test('shuffle off restores plain queue order', () async {
      final backend = FakeAudioBackend();
      final notifier = _notifier(backend);
      await notifier.play(_trackA, queue: _queue);
      notifier.toggleShuffle();
      await notifier.playAt(2);
      notifier.toggleShuffle();
      expect(notifier.state.shuffleEnabled, isFalse);
      expect(notifier.state.shuffledOrder, isEmpty);
      expect(notifier.state.currentTrack, _trackC);
      await notifier.next();
      expect(notifier.state.currentTrack, _trackD);
      await notifier.next();
      expect(notifier.state.currentTrack, _trackD);
    });

    test('shuffle with a one-track queue is just that track', () async {
      final backend = FakeAudioBackend();
      final notifier = _notifier(backend);
      await notifier.play(_trackA);
      notifier.toggleShuffle();
      expect(notifier.state.shuffledOrder, [0]);
      await notifier.next();
      expect(notifier.state.currentTrack, _trackA);
    });
  });

  group('repeat', () {
    test('cycleRepeat goes off to all to one to off', () async {
      final backend = FakeAudioBackend();
      final notifier = _notifier(backend);
      expect(notifier.state.repeatMode, RepeatMode.off);
      notifier.cycleRepeat();
      expect(notifier.state.repeatMode, RepeatMode.all);
      notifier.cycleRepeat();
      expect(notifier.state.repeatMode, RepeatMode.one);
      notifier.cycleRepeat();
      expect(notifier.state.repeatMode, RepeatMode.off);
      notifier.setRepeatMode(RepeatMode.one);
      expect(notifier.state.repeatMode, RepeatMode.one);
    });

    test('completion with repeat one replays the same track', () async {
      final backend = FakeAudioBackend();
      final notifier = _notifier(backend);
      await notifier.play(_trackA, queue: [_trackA, _trackB]);
      notifier.setRepeatMode(RepeatMode.one);
      backend.stateController.add(PlayerState.completed);
      await _pumpTimes(4);
      expect(notifier.state.currentTrack, _trackA);
      expect(notifier.state.isPlaying, isTrue);
      expect(backend.lastSeek, Duration.zero);
      expect(backend.resumeCalls, 1);
      expect(notifier.state.position, Duration.zero);
    });

    test('completion with repeat all wraps to the first track', () async {
      final backend = FakeAudioBackend();
      final notifier = _notifier(backend);
      await notifier.play(_trackA, queue: [_trackA, _trackB]);
      notifier.setRepeatMode(RepeatMode.all);
      await notifier.next();
      expect(notifier.state.currentTrack, _trackB);
      backend.stateController.add(PlayerState.completed);
      await _pumpTimes(4);
      expect(notifier.state.currentTrack, _trackA);
      expect(notifier.state.isPlaying, isTrue);
    });

    test('completion with repeat off advances, then stops at the end',
        () async {
      final backend = FakeAudioBackend();
      final notifier = _notifier(backend);
      await notifier.play(_trackA, queue: [_trackA, _trackB]);
      backend.stateController.add(PlayerState.completed);
      await _pumpTimes(4);
      expect(notifier.state.currentTrack, _trackB);
      backend.stateController.add(PlayerState.completed);
      await _pumpTimes(4);
      expect(notifier.state.currentTrack, isNull);
      expect(notifier.state.isPlaying, isFalse);
    });

    test('next wraps at the end with repeat all, no-op with repeat off',
        () async {
      final backend = FakeAudioBackend();
      final notifier = _notifier(backend);
      await notifier.play(_trackA, queue: [_trackA, _trackB]);
      await notifier.next();
      await notifier.next();
      expect(notifier.state.currentTrack, _trackB);
      notifier.setRepeatMode(RepeatMode.all);
      await notifier.next();
      expect(notifier.state.currentTrack, _trackA);
      expect(notifier.state.queueIndex, 0);
    });

    test('previous wraps to the last track with repeat all', () async {
      final backend = FakeAudioBackend();
      final notifier = _notifier(backend);
      await notifier.play(_trackA, queue: [_trackA, _trackB]);
      await notifier.previous();
      expect(notifier.state.currentTrack, _trackA);
      notifier.setRepeatMode(RepeatMode.all);
      await notifier.previous();
      expect(notifier.state.currentTrack, _trackB);
      expect(notifier.state.queueIndex, 1);
    });

    test('repeat all wraps through the shuffled order', () async {
      final backend = FakeAudioBackend();
      final notifier = _notifier(backend);
      await notifier.play(_trackA, queue: _queue);
      notifier.toggleShuffle();
      notifier.setRepeatMode(RepeatMode.all);
      final order = [...notifier.state.shuffledOrder];
      for (var i = 0; i < order.length - 1; i++) {
        await notifier.next();
      }
      expect(notifier.state.queueIndex, order.last);
      await notifier.next();
      expect(notifier.state.queueIndex, order.first);
      expect(notifier.state.currentTrack, _queue[order.first]);
    });
  });

  group('queue editing', () {
    test('moveInQueue reorders and keeps the current track', () async {
      final backend = FakeAudioBackend();
      final notifier = _notifier(backend);
      await notifier.play(_trackB, queue: _queue);
      notifier.moveInQueue(0, 2);
      expect(notifier.state.queue, [_trackB, _trackC, _trackA, _trackD]);
      expect(notifier.state.queueIndex, 0);
      expect(notifier.state.currentTrack, _trackB);
      notifier.moveInQueue(3, 0);
      expect(notifier.state.queue, [_trackD, _trackB, _trackC, _trackA]);
      expect(notifier.state.queueIndex, 1);
      expect(notifier.state.currentTrack, _trackB);
    });

    test('moveInQueue out of range is a no-op', () async {
      final backend = FakeAudioBackend();
      final notifier = _notifier(backend);
      await notifier.play(_trackA, queue: _queue);
      notifier.moveInQueue(-1, 0);
      notifier.moveInQueue(0, 4);
      notifier.moveInQueue(4, 0);
      notifier.moveInQueue(1, 1);
      expect(notifier.state.queue, _queue);
      expect(notifier.state.queueIndex, 0);
    });

    test('moveInQueue keeps the shuffled order a valid permutation',
        () async {
      final backend = FakeAudioBackend();
      final notifier = _notifier(backend);
      await notifier.play(_trackA, queue: _queue);
      notifier.toggleShuffle();
      notifier.moveInQueue(0, 3);
      final order = notifier.state.shuffledOrder;
      expect(order, hasLength(4));
      expect(order.toSet(), {0, 1, 2, 3});
      expect(order.indexOf(notifier.state.queueIndex), greaterThanOrEqualTo(0));
      expect(notifier.state.currentTrack, _trackA);
    });

    test('removeFromQueue of another track leaves playback alone',
        () async {
      final backend = FakeAudioBackend();
      final notifier = _notifier(backend);
      await notifier.play(_trackB, queue: [_trackA, _trackB, _trackC]);
      await notifier.removeFromQueue(0);
      expect(notifier.state.queue, [_trackB, _trackC]);
      expect(notifier.state.queueIndex, 0);
      expect(notifier.state.currentTrack, _trackB);
      expect(notifier.state.isPlaying, isTrue);
      expect(backend.playedUrls, hasLength(1));
    });

    test('removing the current track advances to the next', () async {
      final backend = FakeAudioBackend();
      final notifier = _notifier(backend);
      await notifier.play(_trackB, queue: [_trackA, _trackB, _trackC]);
      await notifier.removeFromQueue(1);
      expect(notifier.state.queue, [_trackA, _trackC]);
      expect(notifier.state.currentTrack, _trackC);
      expect(notifier.state.queueIndex, 1);
      expect(notifier.state.isPlaying, isTrue);
      expect(backend.playedUrls.last, 'https://example.com/c.m4a');
    });

    test('removing the last current track stops', () async {
      final backend = FakeAudioBackend();
      final notifier = _notifier(backend);
      await notifier.play(_trackC, queue: [_trackA, _trackB, _trackC]);
      await notifier.removeFromQueue(2);
      expect(notifier.state.currentTrack, isNull);
      expect(notifier.state.isPlaying, isFalse);
      expect(notifier.state.queue, isEmpty);
    });

    test('removing the only track stops', () async {
      final backend = FakeAudioBackend();
      final notifier = _notifier(backend);
      await notifier.play(_trackA);
      await notifier.removeFromQueue(0);
      expect(notifier.state.currentTrack, isNull);
      expect(notifier.state.queue, isEmpty);
    });

    test('removeFromQueue out of range is a no-op', () async {
      final backend = FakeAudioBackend();
      final notifier = _notifier(backend);
      await notifier.play(_trackA, queue: _queue);
      await notifier.removeFromQueue(-1);
      await notifier.removeFromQueue(4);
      expect(notifier.state.queue, _queue);
      expect(notifier.state.currentTrack, _trackA);
    });

    test('playNext inserts directly after the current track', () async {
      final backend = FakeAudioBackend();
      final notifier = _notifier(backend);
      await notifier.play(_trackA, queue: [_trackA, _trackB]);
      notifier.playNext(_trackC);
      expect(notifier.state.queue, [_trackA, _trackC, _trackB]);
      expect(notifier.state.queueIndex, 0);
      expect(notifier.state.currentTrack, _trackA);
      await notifier.next();
      expect(notifier.state.currentTrack, _trackC);
    });

    test('playNext moves an existing track instead of duplicating',
        () async {
      final backend = FakeAudioBackend();
      final notifier = _notifier(backend);
      await notifier.play(_trackA, queue: _queue);
      notifier.playNext(_trackC);
      expect(notifier.state.queue, [_trackA, _trackC, _trackB, _trackD]);
      expect(notifier.state.queue.length, 4);
      notifier.playNext(_trackD);
      expect(notifier.state.queue, [_trackA, _trackD, _trackC, _trackB]);
      expect(notifier.state.queue.length, 4);
    });

    test('playNext of the current track is a no-op', () async {
      final backend = FakeAudioBackend();
      final notifier = _notifier(backend);
      await notifier.play(_trackA, queue: [_trackA, _trackB]);
      notifier.playNext(_trackA);
      expect(notifier.state.queue, [_trackA, _trackB]);
      expect(notifier.state.queueIndex, 0);
    });

    test('addToQueue appends and never duplicates', () async {
      final backend = FakeAudioBackend();
      final notifier = _notifier(backend);
      await notifier.play(_trackA, queue: [_trackA, _trackB]);
      notifier.addToQueue(_trackC);
      expect(notifier.state.queue, [_trackA, _trackB, _trackC]);
      expect(notifier.state.queueIndex, 0);
      expect(notifier.state.currentTrack, _trackA);
      notifier.addToQueue(_trackB);
      expect(notifier.state.queue, [_trackA, _trackB, _trackC]);
    });
  });

  group('live flag', () {
    test('isLive defaults to false and is set only via the live flag',
        () async {
      final backend = FakeAudioBackend();
      final notifier = _notifier(backend);
      expect(notifier.state.isLive, isFalse);
      await notifier.playStream(_trackA, 'https://example.com/full.mp3',
          source: 'full', queue: [_trackA, _trackB]);
      expect(notifier.state.isLive, isFalse);
      await notifier.playStream(_trackA, 'https://example.com/radio.mp3',
          source: 'full', live: true);
      expect(notifier.state.isLive, isTrue);
      expect(notifier.state.currentTrack, _trackA);
      // A normal track afterwards clears the flag again.
      await notifier.play(_trackB, queue: [_trackA, _trackB]);
      expect(notifier.state.isLive, isFalse);
    });
  });
}
