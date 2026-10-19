// Unit tests for the For You ranking (M4, FR-24).

import 'package:flutter_test/flutter_test.dart';
import 'package:music_map/data/news/for_you.dart';
import 'package:music_map/data/news/rss_parser.dart';

NewsArticle _a(String title,
    {String? summary, DateTime? date, String link = ''}) {
  return NewsArticle(
    title: title,
    link: link.isEmpty ? 'https://x.test/${title.hashCode}' : link,
    sourceId: 't',
    sourceName: 'T',
    publishedAt: date,
    summary: summary,
  );
}

void main() {
  final now = DateTime.utc(2026, 10, 19, 12, 0, 0);

  test('liked-artist matches rank above non-matches', () {
    final articles = [
      _a('Market roundup',
          date: now.subtract(const Duration(hours: 1))),
      _a('Band X announces tour',
          date: now.subtract(const Duration(hours: 5))),
    ];
    final ranked =
        rankForYou(articles: articles, likedArtists: {'band x'}, now: now);
    expect(ranked[0].title, 'Band X announces tour');
  });

  test('recency decays the score: older match can lose to fresh match', () {
    final articles = [
      _a('Band X tour', date: now.subtract(const Duration(hours: 100))),
      _a('Band X album', date: now.subtract(const Duration(hours: 1))),
    ];
    final ranked =
        rankForYou(articles: articles, likedArtists: {'band x'}, now: now);
    // both match once: 10 - 100/12 < 0 vs 10 - 1/12 > 0
    expect(ranked[0].title, 'Band X album');
  });

  test('non-positive scores fall below all positives', () {
    final articles = [
      _a('Unrelated old news',
          date: now.subtract(const Duration(hours: 200))),
      _a('Band X single', date: now.subtract(const Duration(hours: 1))),
    ];
    final ranked =
        rankForYou(articles: articles, likedArtists: {'band x'}, now: now);
    expect(ranked[0].title, 'Band X single');
    expect(ranked[1].title, 'Unrelated old news');
  });

  test('matching is case-insensitive and covers the summary', () {
    final articles = [
      _a('Festival lineup revealed',
          summary: 'Headlined by BAND X and friends.',
          date: now.subtract(const Duration(hours: 2))),
    ];
    final ranked =
        rankForYou(articles: articles, likedArtists: {'band x'}, now: now);
    // would be negative without the summary match
    expect(ranked[0].title, 'Festival lineup revealed');
  });

  test('ties break by recency', () {
    final articles = [
      _a('Band X news A', date: now.subtract(const Duration(hours: 3))),
      _a('Band X news B', date: now.subtract(const Duration(hours: 1))),
    ];
    final ranked =
        rankForYou(articles: articles, likedArtists: {'band x'}, now: now);
    expect(ranked[0].title, 'Band X news B');
  });

  test('missing dates sink below dated articles', () {
    final articles = [
      _a('Band X mystery', date: null),
      _a('Band X tour', date: now.subtract(const Duration(hours: 2))),
    ];
    final ranked =
        rankForYou(articles: articles, likedArtists: {'band x'}, now: now);
    expect(ranked[0].title, 'Band X tour');
  });
}
