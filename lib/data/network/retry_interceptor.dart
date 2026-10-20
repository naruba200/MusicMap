import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';

/// Retries idempotent requests when the connection dies before any HTTP
/// response is received — e.g. some networks / CDN edges intermittently RST
/// Dart's TLS ClientHello (observed against api.deezer.com: ~60% of fresh
/// connections failed the handshake while Chrome/curl on the same machine
/// worked; a retry on a new connection succeeds).
///
/// Only safe methods (GET/HEAD/OPTIONS) are retried — never POSTs such as the
/// OAuth token exchange, where an auth code is single-use and a blind retry
/// could burn it.
///
/// Exception: a POST that is a read-only query in disguise (e.g. the
/// `youtubei` browse calls — they change no server state) may opt in
/// per-request with `Options(extra: {'retryReadOnly': true})`. OAuth and
/// other state-changing POSTs never set it, so they stay unretried.
class ConnectionRetryInterceptor extends Interceptor {
  final Dio _dio;
  final int maxAttempts;
  final Duration baseDelay;

  ConnectionRetryInterceptor(
    this._dio, {
    this.maxAttempts = 5,
    this.baseDelay = const Duration(milliseconds: 300),
  });

  static const _idempotent = {'GET', 'HEAD', 'OPTIONS'};

  @override
  Future<void> onError(DioException err, ErrorInterceptorHandler handler) async {
    final opts = err.requestOptions;
    final attempt = (opts.extra['retryAttempt'] as int?) ?? 0;
    final retryableMethod = _idempotent.contains(opts.method.toUpperCase()) ||
        opts.extra['retryReadOnly'] == true;
    if (attempt + 1 < maxAttempts &&
        retryableMethod &&
        _isConnectionFailure(err)) {
      opts.extra['retryAttempt'] = attempt + 1;
      await Future<void>.delayed(baseDelay * (attempt + 1));
      try {
        handler.resolve(await _dio.fetch(opts));
      } on DioException catch (e) {
        handler.next(e);
      }
      return;
    }
    handler.next(err);
  }

  bool _isConnectionFailure(DioException err) {
    switch (err.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.connectionError:
        return true;
      case DioExceptionType.unknown:
        final cause = err.error;
        return cause is HandshakeException || cause is SocketException;
      default:
        return false;
    }
  }
}
