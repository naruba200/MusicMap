// Tests for the extended on-demand preview chain (see
// lib/data/fallback/fallback_sources.dart and
// AudioPlayerNotifier.resolvePreview in
// lib/presentation/providers/generation_provider.dart):
// iTunes artist+title -> Deezer artist+title -> iTunes title-only
// (strict title match, no first-result fallback) -> Deezer title-only
// (strict) -> Audius title search as a last resort (full track,
// labelled 'audius' via previewSourceFor, never as a preview).
// No live API is called: iTunes/Deezer responses are canned via a Dio
// adapter, and Audius uses a canned Dio with a host override.

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_man/data/discover/audius_client.dart';
import 'package:music_man/data/fallback/fallback_sources.dart';
import 'package:music_man/data/models/music_models.dart';
import 'package:music_man/presentation/providers/generation_provider.dart';

/// Answers iTunes- and Deezer-shaped JSON by request host and query.
/// [itunes] maps an iTunes `term` to its `results` list; [deezer]
/// maps a Deezer `q` to its `data` list.
class _ChainAdapter implements HttpClientAdapter {
  final Map<String, List<Map<String, dynamic>>> itunes;
  final Map<String, List<Map<String, dynamic>>> deezer;

  _ChainAdapter({required this.itunes, required this.deezer});

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await requestStream?.drain<void>();
    final host = options.uri.host;
    Map<String, dynamic> body;
    if (host == 'itunes.apple.com') {
      final term = options.queryParameters['term'] as String? ?? '';
      body = {'results': itunes[term] ?? const []};
    } else if (host == 'api.deezer.com') {
      final q = options.queryParameters['q'] as String? ?? '';
      body = {'data': deezer[q] ?? const []};
    } else {
      body = {};
    }
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {Headers.contentTypeHeader: ['application/json']},
    );
  }

  @override
  void close({bool force = false}) {}
}

Dio _chainDio({
  Map<String, List<Map<String, dynamic>>> itunes = const {},
  Map<String, List<Map<String, dynamic>>> deezer = const {},
}) {
  final dio = Dio();
  dio.httpClientAdapter = _ChainAdapter(itunes: itunes, deezer: deezer);
  return dio;
}

void main() {
  group('preview chain (Deezer + title-only + Audius)', () {
    test('falls through to Deezer artist+title after an iTunes miss',
        () async {
      final notifier = AudioPlayerNotifier(FallbackSources(_chainDio(
        deezer: {
          'Singer Song': [
            {
              'artist': {'name': 'Singer'},
              'title': 'Song',
              'preview': 'https://example.com/dz.m4a',
            },
          ],
        },
      )));
      const track = Track(artist: 'Singer', title: 'Song');
      expect(await notifier.resolvePreview(track),
          'https://example.com/dz.m4a');
      expect(notifier.previewSourceFor(track), 'preview');
    });

    test('iTunes title-only finds a strict title match past a wrong '
        'first result', () async {
      final notifier = AudioPlayerNotifier(FallbackSources(_chainDio(
        itunes: {
          'Glory Day': [
            {
              'artistName': 'Someone Else',
              'trackName': 'Wrong Song',
              'previewUrl': 'https://example.com/wrong.m4a',
            },
            {
              'artistName': 'Real Artist',
              'trackName': 'Glory Day',
              'previewUrl': 'https://example.com/title.m4a',
            },
          ],
        },
      )));
      // Polluted artist: artist+title lookups miss, title-only must
      // skip the wrong first result and return the title match.
      const track = Track(artist: 'Unknown artist', title: 'Glory Day');
      expect(await notifier.resolvePreview(track),
          'https://example.com/title.m4a');
    });

    test('title-only lookups return null when nothing matches the '
        'title, even if a first result has a preview', () async {
      final notifier = AudioPlayerNotifier(FallbackSources(_chainDio(
        itunes: {
          'Glory Day': [
            {
              'artistName': 'Someone Else',
              'trackName': 'Wrong Song',
              'previewUrl': 'https://example.com/wrong.m4a',
            },
          ],
        },
      )));
      const track = Track(artist: 'Unknown artist', title: 'Glory Day');
      // No first-result fallback on title-only steps: the wrong
      // track's preview must never play for this track.
      expect(await notifier.resolvePreview(track), isNull);
    });

    test('falls through to Deezer title-only after iTunes title-only '
        'misses', () async {
      final notifier = AudioPlayerNotifier(FallbackSources(_chainDio(
        deezer: {
          'Glory Day': [
            {
              'artist': {'name': 'Real Artist'},
              'title': 'Glory Day',
              'preview': 'https://example.com/dz-title.m4a',
            },
          ],
        },
      )));
      const track = Track(artist: 'Unknown artist', title: 'Glory Day');
      expect(await notifier.resolvePreview(track),
          'https://example.com/dz-title.m4a');
    });

    test('Audius title search is a labelled full-track last resort',
        () async {
      final audiusDio = Dio();
      // The Audius search path is answered by a canned adapter with
      // one title-matching track.
      audiusDio.httpClientAdapter = _AudiusSearchAdapter();
      final notifier = AudioPlayerNotifier(
        FallbackSources(_chainDio()),
        audiusClient: AudiusClient(audiusDio,
            hostOverride: 'https://audius.test'),
      );
      const track = Track(artist: 'Unknown artist', title: 'Rare Song');
      expect(await notifier.resolvePreview(track),
          'https://audius.test/v1/tracks/7/stream?app_name=MusicMan');
      // Honest labelling: a full track, never a "preview".
      expect(notifier.previewSourceFor(track), 'audius');
    });

    test('a track with its own streamUrl resolves as a full track '
        'without any network lookup', () async {
      final notifier = AudioPlayerNotifier(FallbackSources(_chainDio()));
      const track = Track(
        artist: 'Indie Artist',
        title: 'Rare Song',
        streamUrl: 'https://audius.test/v1/tracks/7/stream?app_name=MusicMan',
      );
      expect(await notifier.resolvePreview(track),
          'https://audius.test/v1/tracks/7/stream?app_name=MusicMan');
      expect(notifier.previewSourceFor(track), 'audius');
    });
  });
}

/// Answers an Audius /v1/tracks/search with one title-matching track.
class _AudiusSearchAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await requestStream?.drain<void>();
    return ResponseBody.fromString(
      jsonEncode({
        'data': [
          {
            'id': '7',
            'title': 'Rare Song',
            'user': {'name': 'Indie Artist'},
          },
        ],
      }),
      200,
      headers: {Headers.contentTypeHeader: ['application/json']},
    );
  }

  @override
  void close({bool force = false}) {}
}
