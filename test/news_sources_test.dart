// News source registry sanity (FR-20): the bundled publications the
// News tab ships with.

import 'package:flutter_test/flutter_test.dart';
import 'package:music_man/data/news/news_source.dart';

void main() {
  test('registry holds the 9 bundled sources', () {
    expect(newsSources.length, 9);
  });

  test('ids are unique and names/feeds are well-formed', () {
    final ids = newsSources.map((s) => s.id).toSet();
    expect(ids.length, newsSources.length);
    for (final s in newsSources) {
      expect(s.name, isNotEmpty);
      expect(s.feedUrl, startsWith('https://'));
    }
  });
}
