// Bandsintown events tests (Phase 5, push 2): event parsing,
// place/date lines, the dormant placeholder behaviour (no network
// call at all until a real app ID is set), and failure tolerance
// (error responses and network errors yield [], never throw).

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_man/data/events/bandsintown_client.dart';

class FakeBandsintownAdapter implements HttpClientAdapter {
  final int status;
  final dynamic payload;

  FakeBandsintownAdapter({this.status = 200, this.payload = const []});

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await requestStream?.drain<void>();
    expect(options.uri.host, 'rest.bandsintown.com');
    expect(options.uri.queryParameters['date'], 'upcoming');
    expect(options.uri.queryParameters['app_id'], 'real-app-id');
    return ResponseBody.fromString(
      jsonEncode(payload),
      status,
      headers: {Headers.contentTypeHeader: [Headers.jsonContentType]},
    );
  }

  @override
  void close({bool force = false}) {}
}

Dio _dioWith(HttpClientAdapter adapter) {
  final dio = Dio();
  dio.httpClientAdapter = adapter;
  return dio;
}

const _event = {
  'datetime': '2026-11-05T20:00:00',
  'venue': {
    'name': 'Paradise Rock Club',
    'city': 'Boston',
    'region': 'MA',
    'country': 'United States',
  },
  'url': 'https://www.bandsintown.com/e/123',
  'lineup': ['Artist', 'Support Act'],
  'description': 'A show.',
  'offers': [
    {'url': 'https://tickets.example.com/123', 'type': 'Tickets'},
  ],
};

void main() {
  group('isBandsintownConfigured', () {
    test('placeholder and empty ids are dormant', () {
      expect(isBandsintownConfigured(''), isFalse);
      expect(isBandsintownConfigured('YOUR_BANDSINTOWN_APP_ID'), isFalse);
      expect(isBandsintownConfigured('real-app-id'), isTrue);
    });
  });

  group('BandsintownEvent', () {
    test('parses a full event; place and date lines are clean', () {
      final event = BandsintownEvent.fromJson('Artist', _event);
      expect(event.venueName, 'Paradise Rock Club');
      expect(event.placeLine,
          'Paradise Rock Club, Boston, MA, United States');
      expect(event.dateLine, '2026-11-05 20:00');
      expect(event.ticketUrl, 'https://tickets.example.com/123');
      expect(event.lineup, ['Artist', 'Support Act']);
    });

    test('missing venue parts are dropped, not rendered as null', () {
      final event = BandsintownEvent.fromJson('Artist', {
        'venue': {'city': 'Osaka'},
      });
      expect(event.placeLine, 'Osaka');
      expect(event.dateLine, 'Date to be announced');
    });
  });

  group('parseBandsintownEvents', () {
    test('parses a list, skips non-map items', () {
      final events = parseBandsintownEvents('Artist', [_event, 'junk']);
      expect(events.length, 1);
      expect(events.single.artist, 'Artist');
    });

    test('error objects and non-lists yield []', () {
      expect(parseBandsintownEvents('Artist', {'error': 'nope'}), isEmpty);
      expect(parseBandsintownEvents('Artist', null), isEmpty);
      expect(parseBandsintownEvents('Artist', 'garbage'), isEmpty);
    });
  });

  group('BandsintownClient.upcomingEvents', () {
    test('dormant client makes no network call', () async {
      final dio = Dio();
      dio.interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) =>
            handler.reject(DioException(
              requestOptions: options,
              error: 'network must not be touched while dormant',
            )),
      ));
      final client = BandsintownClient(dio, appId: 'YOUR_BANDSINTOWN_APP_ID');
      expect(await client.upcomingEvents('Artist'), isEmpty);
    });

    test('configured client returns parsed events', () async {
      final client = BandsintownClient(
        _dioWith(FakeBandsintownAdapter(payload: [_event])),
        appId: 'real-app-id',
      );
      final events = await client.upcomingEvents('Artist');
      expect(events.length, 1);
      expect(events.single.venueCity, 'Boston');
    });

    test('error status yields [], never throws', () async {
      final client = BandsintownClient(
        _dioWith(FakeBandsintownAdapter(
            status: 403, payload: {'error': 'forbidden'})),
        appId: 'real-app-id',
      );
      expect(await client.upcomingEvents('Artist'), isEmpty);
    });
  });
}
