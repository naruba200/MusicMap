// Tests for the VISIONOS player client (see
// lib/data/export/visionos_player_client.dart): the youtubei/v1/player
// VISIONOS shape returns plain audio URLs where the WEB / ANDROID /
// IOS / EMBEDDED shapes return none (PO-token gated — live spike
// 2026-11-15). No live API is called: one canned Dio adapter answers
// the player endpoint. Only formats carrying a plain `url` are ever
// used; `signatureCipher` entries are ignored — there is no decipherer.

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_man/data/export/visionos_player_client.dart';

/// Canned adapter for the player endpoint. [response] is the player
/// envelope returned verbatim; [throwOnFetch] makes the fetch throw
/// a connection error instead. [lastOptions] captures the request so
/// tests can assert the VISIONOS client shape.
class _VisionOsAdapter implements HttpClientAdapter {
  final Map<String, dynamic>? response;
  final bool throwOnFetch;
  RequestOptions? lastOptions;

  _VisionOsAdapter({this.response, this.throwOnFetch = false});

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await requestStream?.drain<void>();
    lastOptions = options;
    if (throwOnFetch) {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
        error: 'boom',
      );
    }
    return ResponseBody.fromString(
      jsonEncode(response ?? {}),
      200,
      headers: {Headers.contentTypeHeader: ['application/json']},
    );
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _audioFormat(int itag, String url,
        {String mime = 'audio/webm; codecs="opus"'}) =>
    {'itag': itag, 'mimeType': mime, 'bitrate': 100000, 'url': url};

Map<String, dynamic> _envelope(
  List<Map<String, dynamic>> formats, {
  String status = 'OK',
  bool adaptive = true,
}) =>
    {
      'playabilityStatus': {'status': status},
      'streamingData': {
        if (adaptive) 'adaptiveFormats': formats else 'formats': formats,
      },
    };

void main() {
  group('VISIONOS player client', () {
    test('picks itag 251 over 140, regardless of document order', () async {
      final adapter = _VisionOsAdapter(
        response: _envelope([
          _audioFormat(139, 'https://example.test/139'),
          _audioFormat(140, 'https://example.test/140',
              mime: 'audio/mp4; codecs="mp4a.40.2"'),
          _audioFormat(251, 'https://example.test/251'),
          _audioFormat(249, 'https://example.test/249'),
          _audioFormat(250, 'https://example.test/250'),
        ]),
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final client = VisionOsPlayerClient(dio);
      final result = await client.resolveAudioUrl('abc123');
      expect(result.url, 'https://example.test/251');
      expect(result.itag, 251);
      expect(result.failure, isNull);
    });

    test('falls down the preference order when 251 is absent', () async {
      final adapter = _VisionOsAdapter(
        response: _envelope([
          _audioFormat(139, 'https://example.test/139'),
          _audioFormat(140, 'https://example.test/140',
              mime: 'audio/mp4; codecs="mp4a.40.2"'),
        ]),
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final result =
          await VisionOsPlayerClient(dio).resolveAudioUrl('abc123');
      expect(result.url, 'https://example.test/140');
      expect(result.itag, 140);
      expect(result.failure, isNull);
    });

    test('sends the VISIONOS client shape and Safari UA', () async {
      final adapter = _VisionOsAdapter(response: _envelope([]));
      final dio = Dio()..httpClientAdapter = adapter;
      await VisionOsPlayerClient(dio).resolveAudioUrl('abc123');
      final options = adapter.lastOptions!;
      expect(options.uri.host, 'www.youtube.com');
      expect(options.uri.path, '/youtubei/v1/player');
      final data = options.data as Map<String, dynamic>;
      final client = data['context']['client'] as Map<String, dynamic>;
      expect(client['clientName'], 'VISIONOS');
      expect(client['clientVersion'], '1.02');
      expect(data['videoId'], 'abc123');
      expect(options.headers['User-Agent'] as String?, contains('Safari'));
    });

    test('LOGIN_REQUIRED is bot-gated, not a match', () async {
      final adapter = _VisionOsAdapter(
        response: {
          'playabilityStatus': {
            'status': 'LOGIN_REQUIRED',
            'reason': "Sign in to confirm you're not a bot",
          },
        },
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final result =
          await VisionOsPlayerClient(dio).resolveAudioUrl('abc123');
      expect(result.url, isNull);
      expect(result.failure, VisionOsFailure.botGated);
    });

    test('playable status with no audio formats is noAudioUrl', () async {
      final adapter = _VisionOsAdapter(
        response: _envelope([
          {
            'itag': 18,
            'mimeType': 'video/mp4; codecs="avc1.42001E, mp4a.40.2"',
            'url': 'https://example.test/video18',
          },
        ]),
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final result =
          await VisionOsPlayerClient(dio).resolveAudioUrl('abc123');
      expect(result.url, isNull);
      expect(result.failure, VisionOsFailure.noAudioUrl);
    });

    test('empty envelope is noAudioUrl', () async {
      final adapter = _VisionOsAdapter(response: {});
      final dio = Dio()..httpClientAdapter = adapter;
      final result =
          await VisionOsPlayerClient(dio).resolveAudioUrl('abc123');
      expect(result.url, isNull);
      expect(result.failure, VisionOsFailure.noAudioUrl);
    });

    test('signatureCipher-only audio formats are ignored', () async {
      final adapter = _VisionOsAdapter(
        response: _envelope([
          {
            'itag': 251,
            'mimeType': 'audio/webm; codecs="opus"',
            'signatureCipher': 's=abc&url=https%3A%2F%2Fexample.test%2F251',
          },
        ]),
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final result =
          await VisionOsPlayerClient(dio).resolveAudioUrl('abc123');
      expect(result.url, isNull);
      expect(result.failure, VisionOsFailure.noAudioUrl);
    });

    test('audio in `formats` (not adaptiveFormats) is scanned too',
        () async {
      final adapter = _VisionOsAdapter(
        response: _envelope(
          [_audioFormat(140, 'https://example.test/140',
              mime: 'audio/mp4; codecs="mp4a.40.2"')],
          adaptive: false,
        ),
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final result =
          await VisionOsPlayerClient(dio).resolveAudioUrl('abc123');
      expect(result.url, 'https://example.test/140');
      expect(result.itag, 140);
    });

    test('network error propagates so the caller can log it', () async {
      final adapter = _VisionOsAdapter(throwOnFetch: true);
      final dio = Dio()..httpClientAdapter = adapter;
      await expectLater(
        VisionOsPlayerClient(dio).resolveAudioUrl('abc123'),
        throwsA(isA<DioException>()),
      );
    });
  });
}
