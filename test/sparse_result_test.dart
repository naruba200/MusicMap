// Tests for the Phase 1 sparse-result explanation carried on
// GenerationResult: it round-trips through history JSON, and old
// history entries without the field still read back as null.

import 'package:flutter_test/flutter_test.dart';
import 'package:music_man/presentation/providers/generation_provider.dart';

void main() {
  group('GenerationResult.sparseExplanation', () {
    test('round-trips through JSON', () {
      const result = GenerationResult(
        songs: [],
        albums: [],
        seedName: 'DJMax OST',
        isSurprise: false,
        seedCount: 10,
        skippedSeeds: 9,
        sparseExplanation: 'Only 9 of 20 requested songs could be found.',
      );
      final restored = GenerationResult.fromJson(result.toJson());
      expect(restored.sparseExplanation,
          'Only 9 of 20 requested songs could be found.');
      expect(restored.seedName, 'DJMax OST');
      expect(restored.skippedSeeds, 9);
    });

    test('is null for results saved before this field existed', () {
      final restored = GenerationResult.fromJson({
        'songs': [],
        'albums': [],
        'seedName': 'Old run',
        'isSurprise': false,
        'seedCount': 5,
        'skippedSeeds': 0,
      });
      expect(restored.sparseExplanation, isNull);
    });

    test('defaults to null when not given', () {
      const result = GenerationResult(
        songs: [],
        albums: [],
        seedName: 'Surprise picks',
        isSurprise: true,
        seedCount: 0,
        skippedSeeds: 0,
      );
      expect(result.sparseExplanation, isNull);
    });
  });
}
