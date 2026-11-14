// Android media notification player (item 5): an audio_service
// AudioHandler that mirrors the single shared player
// (AudioPlayerNotifier) into the status-bar shade — the same controls
// (previous / play-pause / stop / next) + title / artist / cover.
// The handler owns no playback itself: every control call delegates
// to the notifier, and every notifier state change is mirrored into
// audio_service's playbackState / mediaItem / queue. The OS builds
// the notification from that state; it disappears when the handler
// broadcasts AudioProcessingState.idle (stop, or swipe-away, which
// audio_service maps to stop()).
//
// Position ticks: the notifier emits a new state on every position
// tick, but the shade projects the live position from
// updatePosition/updateTime itself, so position-only changes are
// broadcast at most once a second; track / playing / queue / error
// changes broadcast immediately.

import 'dart:async';

import 'package:audio_service/audio_service.dart' as audioservice;

import '../../data/engine/recommendation_engine.dart';
import '../../data/models/music_models.dart';
import 'generation_provider.dart';

class MusicManAudioHandler extends audioservice.BaseAudioHandler {
  final AudioPlayerNotifier _player;
  late final StreamSubscription<PlaybackState> _subscription;

  /// Last notifier state mirrored in full.
  PlaybackState? _lastMirrored;

  /// errorSeq of the failure already mirrored as an error state. A
  /// stale lastError must not re-surface as an error after a manual
  /// pause — the SnackBar already fired for it once.
  int _mirroredErrorSeq = -1;

  /// Last time a position-only update was broadcast.
  DateTime _lastPositionBroadcast = DateTime.fromMillisecondsSinceEpoch(0);

  MusicManAudioHandler(this._player) {
    _mirror(_player.currentState, force: true);
    _subscription = _player.stream.listen(_mirror);
  }

  /// Cancel the mirror subscription (tests; the app-lifetime handler
  /// is never disposed).
  void dispose() {
    _subscription.cancel();
  }

  /// Stable media-item id for [track]: the same normalized key the
  /// player and generation use, so playMediaItem / skipToQueueItem
  /// can find the track in the player's queue.
  static String mediaItemIdFor(Track track) =>
      RecommendationEngine.normalizeKey(track.artist, track.title);

  static audioservice.MediaItem _mediaItemFor(Track track,
      {Duration? duration}) {
    return audioservice.MediaItem(
      id: mediaItemIdFor(track),
      title: track.title,
      artist: track.artist,
      album: track.album,
      duration: duration ??
          (track.durationMs != null
              ? Duration(milliseconds: track.durationMs!)
              : null),
      artUri:
          track.imageUrl != null ? Uri.tryParse(track.imageUrl!) : null,
    );
  }

  static bool _sameIds(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void _mirror(PlaybackState state, {bool force = false}) {
    final previous = _lastMirrored;
    final track = state.currentTrack;
    final trackKey = track == null ? null : mediaItemIdFor(track);
    final previousKey = previous?.currentTrack == null
        ? null
        : mediaItemIdFor(previous!.currentTrack!);
    final queueIds = state.queue.map(mediaItemIdFor).toList();
    final previousQueueIds =
        previous?.queue.map(mediaItemIdFor).toList() ?? const [];
    // Structural change: anything the notification shows besides the
    // moving position.
    final structural = force ||
        previous == null ||
        trackKey != previousKey ||
        state.isPlaying != previous.isPlaying ||
        state.isResolving != previous.isResolving ||
        state.queueIndex != previous.queueIndex ||
        !_sameIds(queueIds, previousQueueIds) ||
        state.duration != previous.duration ||
        state.errorSeq != previous.errorSeq ||
        state.lastError != previous.lastError;
    if (!structural) {
      // Position-only tick: broadcast at most once a second; the
      // shade projects the live position from updatePosition +
      // updateTime in between.
      if (DateTime.now().difference(_lastPositionBroadcast) <
          const Duration(seconds: 1)) {
        return;
      }
    }
    _lastPositionBroadcast = DateTime.now();
    _lastMirrored = state;

    // Media item + queue mirror the player's current track and
    // queue, but only when they actually changed — the subjects are
    // seeded with the idle values already. (MediaItem's == compares
    // id only, so duration/art changes are compared field by field —
    // otherwise the seek bar would never learn the duration once the
    // backend reports it.)
    final mediaItem = track == null
        ? null
        : _mediaItemFor(track, duration: state.duration);
    final currentItem = this.mediaItem.valueOrNull;
    final itemChanged = mediaItem?.id != currentItem?.id ||
        mediaItem?.duration != currentItem?.duration ||
        mediaItem?.artUri != currentItem?.artUri;
    if (itemChanged) {
      this.mediaItem.add(mediaItem);
    }
    if (!_sameIds(
        queueIds, queue.valueOrNull?.map((m) => m.id).toList() ?? const [])) {
      queue.add(state.queue.map((t) => _mediaItemFor(t)).toList());
    }

    // Fresh failure for the current track: error state carrying the
    // human-readable reason (the same string the SnackBar shows).
    // A stale lastError (an earlier failure, already shown) is not
    // re-surfaced — a paused track after one stays paused, not error.
    final freshError = state.lastError != null &&
        state.errorSeq != _mirroredErrorSeq &&
        !state.isPlaying;
    if (freshError) _mirroredErrorSeq = state.errorSeq;

    final processingState = track == null
        ? audioservice.AudioProcessingState.idle
        : freshError
            ? audioservice.AudioProcessingState.error
            : state.isResolving
                ? audioservice.AudioProcessingState.loading
                : audioservice.AudioProcessingState.ready;
    final controls = track == null
        ? const <audioservice.MediaControl>[]
        : <audioservice.MediaControl>[
            audioservice.MediaControl.skipToPrevious,
            state.isPlaying
                ? audioservice.MediaControl.pause
                : audioservice.MediaControl.play,
            audioservice.MediaControl.stop,
            audioservice.MediaControl.skipToNext,
          ];
    playbackState.add(audioservice.PlaybackState(
      processingState: processingState,
      playing: state.isPlaying,
      controls: controls,
      // Compact view: previous, play/pause, next. Stop lives in the
      // expanded notification only.
      androidCompactActionIndices: track == null ? null : const [0, 1, 3],
      // A seek bar only renders when the item has a duration (a live
      // radio stream never does).
      systemActions: state.duration == null
          ? const <audioservice.MediaAction>{}
          : const <audioservice.MediaAction>{
              audioservice.MediaAction.seek
            },
      updatePosition: state.position,
      bufferedPosition: state.position,
      speed: 1.0,
      errorMessage: freshError ? state.lastError : null,
      queueIndex: state.queueIndex >= 0 ? state.queueIndex : null,
    ));
  }

  @override
  Future<void> play() async {
    final state = _player.currentState;
    if (!state.isPlaying && state.hasCurrentTrack) {
      await _player.resume();
    }
  }

  @override
  Future<void> pause() async {
    if (_player.currentState.isPlaying) await _player.pause();
  }

  @override
  Future<void> stop() async {
    await _player.stop();
    // super.stop() broadcasts AudioProcessingState.idle, which makes
    // audio_service stop the foreground service and remove the
    // notification. The mirror would do the same once the notifier's
    // idle state lands; pushing it here guarantees the teardown even
    // if the mirror hasn't run yet.
    await super.stop();
  }

  @override
  Future<void> skipToNext() async {
    await _player.next();
  }

  @override
  Future<void> skipToPrevious() async {
    await _player.previous();
  }

  @override
  Future<void> seek(Duration position) async {
    await _player.seek(position);
    // A seek disrupts position continuity: broadcast immediately so
    // the shade's seek bar jumps instead of waiting for the throttle.
    _mirror(_player.currentState, force: true);
  }

  @override
  Future<void> playMediaItem(audioservice.MediaItem mediaItem) async {
    final index = _player.currentState.queue
        .indexWhere((t) => mediaItemIdFor(t) == mediaItem.id);
    if (index >= 0) await _player.playAt(index);
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    await _player.playAt(index);
  }
}
