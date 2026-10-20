// ConnectionRetryInterceptor policy tests:
//
// - GETs retry on connection failure (the TLS-RST recovery Deezer relies on).
// - POSTs do NOT retry by default — the OAuth token exchange must never
//   blind-retry a single-use auth code.
// - A POST may opt in per-request with extra {'retryReadOnly': true}
//   (the youtubei browse calls — read-only queries over POST).

import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_map/data/network/retry_interceptor.dart';

/// Fails with a connection error for the first [failures] requests,
/// then answers 200. Counts every request it sees.
class FlakyAdapter implements HttpClientAdapter {
  final int failures;
  int calls = 0;

  FlakyAdapter(this.failures);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await requestStream?.drain<void>();
    calls++;
    if (calls <= failures) {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
        message: 'simulated TLS reset',
      );
    }
    return ResponseBody.fromString(
      '{}',
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Dio dioWith(FlakyAdapter adapter) {
  final dio = Dio();
  dio.httpClientAdapter = adapter;
  dio.interceptors.add(
    ConnectionRetryInterceptor(
      dio,
      baseDelay: const Duration(milliseconds: 1),
    ),
  );
  return dio;
}

void main() {
  test('GET retries connection failures and succeeds', () async {
    final adapter = FlakyAdapter(2);
    final dio = dioWith(adapter);

    final res = await dio.get('https://example.test/feed');

    expect(res.statusCode, 200);
    expect(adapter.calls, 3);
  });

  test('POST without opt-in is never retried (OAuth safety)', () async {
    final adapter = FlakyAdapter(2);
    final dio = dioWith(adapter);

    await expectLater(
      dio.post('https://example.test/token', data: {'code': 'single-use'}),
      throwsA(isA<DioException>()),
    );
    expect(adapter.calls, 1);
  });

  test('POST with retryReadOnly opt-in retries and succeeds', () async {
    final adapter = FlakyAdapter(2);
    final dio = dioWith(adapter);

    final res = await dio.post(
      'https://example.test/browse',
      data: {'browseId': 'VLx'},
      options: Options(extra: const {'retryReadOnly': true}),
    );

    expect(res.statusCode, 200);
    expect(adapter.calls, 3);
  });
}
