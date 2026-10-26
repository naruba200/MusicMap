// Tests for the Phase 1 preview fix (see
// lib/presentation/providers/generation_provider.dart and
// lib/data/fallback/fallback_sources.dart):
// - on-demand iTunes lookup via AudioPlayerNotifier.resolvePreview,
//   including the cache (one network call, not one per tap);
// - playing-state observability: AsyncLoading while resolving, data(null)
//   when no preview exists, resolvingKey naming the resolving track;
// - preview-key normalisation consistency between the fallback layer
//   (which builds the keys) and generation/player lookup (which reads
//   them via RecommendationEngine.normalizeKey).
// No live API is called: iTunes responses are canned via a Dio adapter.
// These tests never play audio, so no platform audio channel is touched
// (the completion subscription is installed lazily on first real play).

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_man/data/engine/recommendation_engine.dart';
import 'package:music_man/data/fallback/fallback_sources.dart';
import 'package:music_man/data/models/music_models.dart';
import 'package:music_man/presentation/providers/generation_provider.dart';

void main() {
  group('resolvePreview (on-demand iTunes lookup)', () {
    test('returns the track previewUrl without any network call', () async {
      final notifier = AudioPlayerNotifier(FallbackSources());
      const track = Track(
        artist: 'Singer',
        title: 'Song',
        previewUrl: 'https://example.com/known.m4a',
      );
      expect(await notifier.resolvePreview(track),
          'https://example.com/known.m4a');
    });

    test('looks a preview up on iTunes, then serves it from cache',
        () async {
      var calls = 0;
      final dio = Dio();
      dio.httpClientAdapter = _CannedAdapter((options) async {
        calls++;
        final term = options.queryParameters['term'] as String? ?? '';
        if (term.contains('Known')) {
          return {
            'results': [
              {
                'artistName': 'Known Artist',
                'trackName': 'Known Song',
                'previewUrl': 'https://example.com/known.m4a',
              }
            ]
          };
        }
        return {'results': []};
      });
      final notifier = AudioPlayerNotifier(FallbackSources(dio));
      const track = Track(artist: 'Known Artist', title: 'Known Song');
      expect(await notifier.resolvePreview(track),
          'https://example.com/known.m4a');
      expect(await notifier.resolvePreview(track),
          'https://example.com/known.m4a');
      expect(calls, 1);
    });

    test('returns null cleanly for an unknown track', () async {
      final dio = Dio();
      dio.httpClientAdapter =
          _CannedAdapter((_) async => {'results': []});
      final notifier = AudioPlayerNotifier(FallbackSources(dio));
      const track = Track(artist: 'Nobody', title: 'No Such Song');
      expect(await notifier.resolvePreview(track), isNull);
    });
  });

  group('playing-state observability', () {
    test('play() shows loading while resolving, then data(null) '
        'when no preview exists', () async {
      final gate = Completer<Map<String, dynamic>>();
      final dio = Dio();
      dio.httpClientAdapter = _CannedAdapter((_) => gate.future);
      final notifier = AudioPlayerNotifier(FallbackSources(dio));
      const track = Track(artist: 'Nobody', title: 'No Such Song');
      final key =
          RecommendationEngine.normalizeKey(track.artist, track.title);

      final playFuture = notifier.play(track);
      // Resolve is in flight: loading state + resolving key observable.
      expect(notifier.state, isA<AsyncLoading>());
      expect(notifier.resolvingKey, key);
      expect(notifier.playingKey, isNull);

      gate.complete({'results': []});
      await playFuture;
      // No preview anywhere: back to stopped, no stale loading state.
      expect(notifier.state, isA<AsyncData<String?>>());
      expect(notifier.state.valueOrNull, isNull);
      expect(notifier.resolvingKey, isNull);
      expect(notifier.playingKey, isNull);
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
      expect(
          result.previews[
              RecommendationEngine.normalizeKey('Singer', 'Hit Song')],
          'https://example.com/hit.m4a');
    });
  });
}

/// Answers iTunes-shaped JSON from [respond] for every request.
class _CannedAdapter implements HttpClientAdapter {
  final Future<Map<String, dynamic>> Function(RequestOptions) respond;
  _CannedAdapter(this.respond);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await requestStream?.drain<void>();
    return ResponseBody.fromString(
      jsonEncode(await respond(options)),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
