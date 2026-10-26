// Tests for mapBatched (see lib/presentation/providers/
// generation_provider.dart): the batching primitive behind the
// results-first generation speedup. Pure Dart, no network, no
// providers: it only checks batching order, concurrency bounds, and
// early stopping.

import 'package:flutter_test/flutter_test.dart';
import 'package:music_man/presentation/providers/generation_provider.dart';

void main() {
  group('mapBatched', () {
    test('preserves input order across batches', () async {
      final input = List<int>.generate(12, (i) => i);
      final out = await mapBatched<int, int>(
        input,
        5,
        (i, v) async => v * 2,
      );
      expect(out, [for (final v in input) v * 2]);
    });

    test('runs at most batchSize items concurrently', () async {
      var active = 0;
      var maxActive = 0;
      final out = await mapBatched<int, int>(
        List<int>.generate(12, (i) => i),
        5,
        (i, v) async {
          active++;
          if (active > maxActive) maxActive = active;
          await Future<void>.delayed(Duration.zero);
          active--;
          return v;
        },
      );
      expect(out.length, 12);
      expect(maxActive, 5);
    });

    test('stops early when shouldStop becomes true between batches',
        () async {
      var stop = false;
      final out = await mapBatched<int, int>(
        List<int>.generate(12, (i) => i),
        5,
        (i, v) async => v,
        onProgress: (done, total) {
          if (done >= 5) stop = true;
        },
        shouldStop: () => stop,
      );
      // First batch only; the caller (generation) checks cancellation
      // itself and aborts instead of merging a partial list.
      expect(out, [0, 1, 2, 3, 4]);
    });

    test('a single-item batch behaves like a sequential loop',
        () async {
      final out = await mapBatched<String, String>(
        ['a', 'b', 'c'],
        1,
        (i, v) async => '$i:$v',
      );
      expect(out, ['0:a', '1:b', '2:c']);
    });
  });
}
