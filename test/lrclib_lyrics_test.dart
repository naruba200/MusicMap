// LRCLIB lyrics tests (Phase 5, push 1): response parsing, LRC
// timestamp parsing, failure tolerance (404 / 500 / network error
// all yield null, never throw), and the 30-day Hive cache behaviour
// (fresh hit, fresh miss, stale entry retries).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:music_man/data/lyrics/lrclib_client.dart';
import 'package:music_man/data/lyrics/lyrics_cache.dart';

class FakeLrclibAdapter implements HttpClientAdapter {
  final int status;
  final Map<String, dynamic>? payload;
  final bool throwError;

  FakeLrclibAdapter({
    this.status = 200,
    this.payload,
    this.throwError = false,
  });

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await requestStream?.drain<void>();
    if (throwError) {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
      );
    }
    // The client must send the required User-Agent on every request.
    expect(options.headers['User-Agent'], LrclibClient.userAgent);
    expect(options.uri.path, '/api/get');
    expect(options.uri.queryParameters['artist_name'], 'Artist');
    expect(options.uri.queryParameters['track_name'], 'Song');
    return ResponseBody.fromString(
      jsonEncode(payload ?? {}),
      status,
      headers: {Headers.contentTypeHeader: [Headers.jsonContentType]},
    );
  }

  @override
  void close({bool force = false}) {}
}

Dio _dioWith(FakeLrclibAdapter adapter) {
  final dio = Dio();
  dio.httpClientAdapter = adapter;
  return dio;
}

const _hit = {
  'id': 123,
  'trackName': 'Song',
  'artistName': 'Artist',
  'albumName': 'Album',
  'duration': 200.5,
  'instrumental': false,
  'plainLyrics': 'line one\nline two',
  'syncedLyrics': '[00:01.00] line one\n[00:05.50] line two',
};

void main() {
  group('LrclibLyrics.fromJson', () {
    test('parses a full hit; plain lyrics win for display', () {
      final lyrics = LrclibLyrics.fromJson(_hit);
      expect(lyrics.id, 123);
      expect(lyrics.trackName, 'Song');
      expect(lyrics.durationSec, 200.5);
      expect(lyrics.instrumental, isFalse);
      expect(lyrics.hasContent, isTrue);
      expect(lyrics.displayText, 'line one\nline two');
    });

    test('legacy name field is accepted as trackName', () {
      final lyrics = LrclibLyrics.fromJson({'name': 'Old'});
      expect(lyrics.trackName, 'Old');
      expect(lyrics.hasContent, isFalse);
    });

    test('synced-only match displays its lines without timestamps', () {
      final lyrics = LrclibLyrics.fromJson({
        'syncedLyrics': '[00:01.00] first\n[00:04.25] second',
      });
      expect(lyrics.hasContent, isTrue);
      expect(lyrics.displayText, 'first\nsecond');
    });

    test('instrumental result has content but no display text', () {
      final lyrics = LrclibLyrics.fromJson({'instrumental': true});
      expect(lyrics.hasContent, isTrue);
      expect(lyrics.displayText, isNull);
    });

    test('empty result has no content', () {
      expect(LrclibLyrics.fromJson({}).hasContent, isFalse);
    });

    test('round-trips through toJson', () {
      final lyrics = LrclibLyrics.fromJson(_hit);
      expect(LrclibLyrics.fromJson(lyrics.toJson()).plainLyrics,
          'line one\nline two');
    });
  });

  group('parseSyncedLyrics', () {
    test('parses mm:ss.xx timestamps, including fractional variants', () {
      final lines = parseSyncedLyrics(
          '[00:01.00] a\n[01:02.5] b\n[02:03] c');
      expect(lines.length, 3);
      expect(lines[0].timeSec, closeTo(1.0, 0.001));
      expect(lines[1].timeSec, closeTo(62.5, 0.001));
      expect(lines[2].timeSec, closeTo(123.0, 0.001));
      expect(lines.map((l) => l.text).toList(), ['a', 'b', 'c']);
    });

    test('skips metadata tags, blank lines and malformed lines', () {
      final lines = parseSyncedLyrics(
          '[ti:Title]\n[ar:Artist]\n\nnot a lyric\n[00:10.00] ok');
      expect(lines.length, 1);
      expect(lines.single.text, 'ok');
    });

    test('strips extra timestamps from multi-timestamp lines', () {
      final lines =
          parseSyncedLyrics('[00:01.00][00:05.00] repeated');
      expect(lines.length, 1);
      expect(lines.single.text, 'repeated');
    });

    test('null and empty input yield no lines', () {
      expect(parseSyncedLyrics(null), isEmpty);
      expect(parseSyncedLyrics('  '), isEmpty);
    });
  });

  group('LrclibClient.fetchLyrics', () {
    test('200 hit returns parsed lyrics', () async {
      final client = LrclibClient(
          _dioWith(FakeLrclibAdapter(payload: _hit)));
      final lyrics = await client.fetchLyrics(
          artist: 'Artist', title: 'Song', album: 'Album', durationSec: 200);
      expect(lyrics?.plainLyrics, 'line one\nline two');
    });

    test('404 (unknown track) returns null, never throws', () async {
      final client = LrclibClient(
          _dioWith(FakeLrclibAdapter(status: 404, payload: {})));
      expect(
          await client.fetchLyrics(artist: 'Artist', title: 'Song'),
          isNull);
    });

    test('500 returns null, never throws', () async {
      final client = LrclibClient(
          _dioWith(FakeLrclibAdapter(status: 500, payload: {})));
      expect(
          await client.fetchLyrics(artist: 'Artist', title: 'Song'),
          isNull);
    });

    test('network error returns null, never throws', () async {
      final client =
          LrclibClient(_dioWith(FakeLrclibAdapter(throwError: true)));
      expect(
          await client.fetchLyrics(artist: 'Artist', title: 'Song'),
          isNull);
    });

    test('result with no lyric content returns null', () async {
      final client = LrclibClient(
          _dioWith(FakeLrclibAdapter(payload: {'id': 1})));
      expect(
          await client.fetchLyrics(artist: 'Artist', title: 'Song'),
          isNull);
    });
  });

  group('LyricsCache', () {
    late Directory dir;

    setUpAll(() async {
      dir = await Directory.systemTemp.createTemp('music_man_lyrics_test');
      Hive.init(dir.path);
    });

    tearDownAll(() async {
      await Hive.close();
      await dir.delete(recursive: true);
    });

    test('hit, miss and stale-entry behaviour over 30 days', () async {
      final box = await Hive.openBox('lyrics_test');
      await box.clear();
      final cache = LyricsCache(box);
      final now = DateTime.now();

      expect(cache.lookup('Artist', 'Song'), isNull);
      expect(cache.shouldRetry('Artist', 'Song', now), isTrue);

      cache.store(
          'Artist', 'Song', LrclibLyrics.fromJson(_hit));
      expect(cache.lookup('Artist', 'Song')?.plainLyrics,
          'line one\nline two');
      expect(cache.shouldRetry('Artist', 'Song', now), isFalse);

      cache.storeMiss('Artist', 'Other');
      expect(cache.lookup('Artist', 'Other'), isNull);
      expect(cache.shouldRetry('Artist', 'Other', now), isFalse);
      // Past the 30-day TTL, both hits and misses retry.
      final later = now.add(const Duration(days: 31));
      expect(cache.shouldRetry('Artist', 'Song', later), isTrue);
      expect(cache.shouldRetry('Artist', 'Other', later), isTrue);
      expect(cache.lookup('Artist', 'Song'), isNotNull); // lookup uses now
      await box.close();
    });
  });
}
