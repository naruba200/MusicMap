// tagForLabel: chip label -> Last.fm tag (genreTagMapping + fallback).

import 'package:flutter_test/flutter_test.dart';
import 'package:music_man/presentation/providers/generation_provider.dart';

void main() {
  group('tagForLabel', () {
    test('mapped labels use the Last.fm tag spelling', () {
      expect(tagForLabel('J-Rock'), 'j-rock');
      expect(tagForLabel('R&B'), 'rnb');
      expect(tagForLabel('City Pop'), 'city pop');
      expect(tagForLabel('Hip-Hop'), 'hip-hop');
    });

    test('unmapped labels fall back to lowercase', () {
      expect(tagForLabel('Metal'), 'metal');
      expect(tagForLabel('Chill'), 'chill');
      expect(tagForLabel('Visual Kei'), 'visual kei');
    });
  });
}
