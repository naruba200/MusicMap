// "For you" ranking (FR-24): pure Dart, unit-tested.
//
// likedArtists = normalized artist names from favorites + recent seed
// playlists. Score = 10 × (matched liked artists) − hoursSincePublish / 12.
// Articles with score ≤ 0 fall below all positive ones; ties break by
// recency. Matching is normalized substring on title + summary.

import 'rss_parser.dart';

String normalizeArtist(String name) => name.toLowerCase().trim();

/// Rank articles for the For You tab. Returns the articles sorted; the
/// caller decides the empty-likes fallback (FR-25).
List<NewsArticle> rankForYou({
  required List<NewsArticle> articles,
  required Set<String> likedArtists,
  required DateTime now,
}) {
  final scored = <_Scored>[];
  for (final a in articles) {
    final haystack =
        '${a.title.toLowerCase()} ${a.summary?.toLowerCase() ?? ''}';
    var matched = 0;
    for (final artist in likedArtists) {
      if (artist.isNotEmpty && haystack.contains(artist)) matched++;
    }
    final hours = a.publishedAt == null
        ? 1e9 // unknown dates sink below everything dated
        : now.difference(a.publishedAt!).inMinutes / 60.0;
    final score = 10 * matched - hours / 12;
    scored.add(_Scored(a, score));
  }
  scored.sort((x, y) {
    final xp = x.score > 0;
    final yp = y.score > 0;
    if (xp != yp) return xp ? -1 : 1; // positives first
    final c = y.score.compareTo(x.score);
    if (c != 0) return c;
    final dx = x.article.publishedAt;
    final dy = y.article.publishedAt;
    if (dx == null && dy == null) return 0;
    if (dx == null) return 1;
    if (dy == null) return -1;
    return dy.compareTo(dx);
  });
  return [for (final s in scored) s.article];
}

class _Scored {
  final NewsArticle article;
  final double score;
  const _Scored(this.article, this.score);
}
