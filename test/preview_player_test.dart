// Tests for the full-song play path (see
// lib/presentation/providers/generation_provider.dart and
// lib/data/fullsong/full_song_resolver.dart):
// - play() resolves through the full-song resolver: a track carrying
//   its own streamUrl plays without any network call; a track with
//   no full song anywhere records the distinguished failure reason
//   for the SnackBar;
// - playing-state observability: isResolving while resolving, idle
//   state when no full song exists, resolvingKey naming the resolving
//   track;
// - failure reasons distinguish no-stream vs network vs
//   Spotify-audio-unavailable (see playbackErrorMessage).
// No live API is called: iTunes/Deezer responses are canned via a Dio
// adapter, and Spotify search is a canned callback on an injected
// resolver. Playback goes through a fake AudioBackend, so no platform
// audio channel is touched.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_man/data/engine/recommendation_engine.dart';
import 'package:music_man/data/fallback/fallback_sources.dart';
import 'package:music_man/data/fullsong/full_song_resolver.dart';
import 'package:music_man/data/models/music_models.dart';
import 'package:music_man/presentation/providers/generation_provider.dart';

import 'fake_audio_backend.dart';

/// Answers empty iTunes/Deezer results for every request, so the
/// link lookups find nothing (no live network).
class _EmptyAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await requestStream?.drain<void>();
    return ResponseBody.fromString(
      jsonEncode({'results': [], 'data': []}),
      200,
      headers: {Headers.contentTypeHeader: ['application/json']},
    );
  }

  @override
  void close({bool force = false}) {}
}

Dio _emptyDio() {
  final dio = Dio();
  dio.httpClientAdapter = _EmptyAdapter();
  return dio;
}

void main() {
  group('play() resolves to a full song', () {
    test('a track with its own streamUrl plays without any network call',
        () async {
      final backend = FakeAudioBackend();
      final notifier =
          AudioPlayerNotifier(FallbackSources(), backend: backend);
      const track = Track(
        artist: 'Singer',
        title: 'Song',
        streamUrl: 'https://example.com/full.mp3',
      );
      await notifier.play(track);
      expect(backend.playedUrls, ['https://example.com/full.mp3']);
      expect(notifier.state.isPlaying, isTrue);
      expect(notifier.streamSourceFor(track), 'ownStream');
    });

    test('play() shows loading while resolving, then the no-stream '
        'reason when nothing is found', () async {
      final gate = Completer<Map<String, dynamic>>();
      final dio = Dio();
      dio.httpClientAdapter = _GatedAdapter(gate.future);
      final notifier = AudioPlayerNotifier(FallbackSources(dio));
      const track = Track(artist: 'Nobody', title: 'No Such Song');
      final key =
          RecommendationEngine.normalizeKey(track.artist, track.title);

      final playFuture = notifier.play(track);
      // Resolve is in flight: resolving state + resolving key observable.
      expect(notifier.state.isResolving, isTrue);
      expect(notifier.resolvingKey, key);
      expect(notifier.playingKey, isNull);

      gate.complete({'results': [], 'data': []});
      await playFuture;
      // No full song anywhere: back to stopped, no stale resolving
      // state, and the reason is recorded for the SnackBar.
      expect(notifier.state.isResolving, isFalse);
      expect(notifier.state.currentTrack, isNull);
      expect(notifier.state.resolvingKey, isNull);
      expect(notifier.playingKey, isNull);
      expect(notifier.state.lastError, 'No full stream found for this track');
      expect(notifier.state.errorSeq, 1);
    });

    test('a network failure names the unreachable source', () async {
      final dio = _emptyDio();
      final resolver = FullSongResolver(
        fallbacks: FallbackSources(dio),
        spotifySearch: (_) async =>
            throw const SocketException('Failed host lookup'),
      );
      final notifier = AudioPlayerNotifier(
        FallbackSources(dio),
        resolver: resolver,
      );
      const track = Track(artist: 'Nobody', title: 'No Such Song');
      await notifier.play(track);
      expect(notifier.state.lastError,
          "Couldn't reach spotify — check your connection");
      expect(notifier.state.errorSeq, 1);
    });

    test('Spotify found the track but nothing can play it', () async {
      final dio = _emptyDio();
      final resolver = FullSongResolver(
        fallbacks: FallbackSources(dio),
        spotifySearch: (_) async => [
          const Track(artist: 'Nobody', title: 'No Such Song'),
        ],
      );
      final notifier = AudioPlayerNotifier(
        FallbackSources(dio),
        resolver: resolver,
      );
      const track = Track(artist: 'Nobody', title: 'No Such Song');
      await notifier.play(track);
      expect(
          notifier.state.lastError, "Spotify audio can't play in-app");
      expect(notifier.state.errorSeq, 1);
    });

    test('an outbound-only match never leaves the app: the tap shows '
        'the in-app no-stream message', () async {
      final dio = Dio();
      dio.httpClientAdapter = _GatedAdapter(Future.value({
        'results': [
          {
            'artistName': 'Singer',
            'trackName': 'Song',
            'trackViewUrl': 'https://music.apple.com/song/1',
          },
        ],
        'data': [],
      }));
      final notifier = AudioPlayerNotifier(FallbackSources(dio));
      const track = Track(artist: 'Singer', title: 'Song');
      await notifier.play(track);
      // The iTunes link exists but has no in-app stream, so nothing
      // opens anywhere: the player reports the no-stream message
      // in-app, the track is not loaded, and no source label is set.
      expect(notifier.state.lastError, 'No full stream found for this track');
      expect(notifier.state.errorSeq, 1);
      expect(notifier.state.currentTrack, isNull);
      expect(notifier.state.isPlaying, isFalse);
      expect(notifier.streamSourceFor(track), isNull);
    });
  });

  group('playbackErrorMessage maps the cases directly', () {
    test('no-stream, network, and Spotify-audio cases', () {
      expect(
        AudioPlayerNotifier.playbackErrorMessage(
          '',
          failure: FullSongFailure.noStream,
        ),
        'No full stream found for this track',
      );
      expect(
        AudioPlayerNotifier.playbackErrorMessage(
          '',
          failure: FullSongFailure.network,
          networkSource: 'audius',
        ),
        "Couldn't reach audius — check your connection",
      );
      expect(
        AudioPlayerNotifier.playbackErrorMessage(
          '',
          failure: FullSongFailure.spotifyAudioUnavailable,
        ),
        "Spotify audio can't play in-app",
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

  group('preview key normalisation consistency', () {
    test('iTunes preview keys equal normalizeKey, including '
        'remaster-suffixed titles', () async {
      final dio = Dio();
      dio.httpClientAdapter = _CannedAdapter((_) async => {
            'results': [
              {
                'artistName': 'Singer',
                'trackName': 'Hit Song (Remastered)',
                'previewUrl': 'https://example.com/hit.m4a',
              }
            ]
          });
      final result =
          await FallbackSources(dio).itunesArtistTracksWithPreviews('Singer');
      // Generation looks previews up by normalizeKey(artist, title) for
      // the recommended track; a raw lowercased key would be
      // 'singer - hit song (remastered)' and would miss.
      final expected =
          RecommendationEngine.normalizeKey('Singer', 'Hit Song (Remastered)');
      expect(result.previews.keys.single, expected);
      expect(result.previews[expected], 'https://example.com/hit.m4a');
    });
  });
}

/// Answers every request with one gated future's payload, so a test
/// can observe the resolving window and then decide the outcome.
class _GatedAdapter implements HttpClientAdapter {
  final Future<Map<String, dynamic>> _gated;
  _GatedAdapter(this._gated);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await requestStream?.drain<void>();
    final body = await _gated;
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {Headers.contentTypeHeader: ['application/json']},
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Answers every request by calling [answer] with the options.
class _CannedAdapter implements HttpClientAdapter {
  final Future<Map<String, dynamic>> Function(RequestOptions options) answer;
  _CannedAdapter(this.answer);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await requestStream?.drain<void>();
    return ResponseBody.fromString(
      jsonEncode(await answer(options)),
      200,
      headers: {Headers.contentTypeHeader: ['application/json']},
    );
  }

  @override
  void close({bool force = false}) {}
}
