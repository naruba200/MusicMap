// Request pacing (Phase 2). MusicBrainz allows 1 req/s, so calls
// never burst. Delay/clock are injectable so tests assert pacing
// without actually waiting seconds.

/// Waits until [minInterval] has passed since the previous slot.
class RequestThrottler {
  final Duration minInterval;
  final Future<void> Function(Duration duration) _delay;
  final DateTime Function() _now;
  DateTime? _lastRequest;

  RequestThrottler({
    required this.minInterval,
    Future<void> Function(Duration duration)? delay,
    DateTime Function()? now,
  })  : _delay = delay ?? Future.delayed,
        _now = now ?? DateTime.now;

  /// Blocks until a request slot is available, then claims it.
  Future<void> waitForSlot() async {
    final last = _lastRequest;
    if (last != null) {
      final elapsed = _now().difference(last);
      if (elapsed < minInterval) {
        await _delay(minInterval - elapsed);
      }
    }
    _lastRequest = _now();
  }
}
