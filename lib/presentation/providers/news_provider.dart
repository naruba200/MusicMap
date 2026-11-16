// News state (M4, FR-20…FR-27).

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/news/for_you.dart';
import '../../data/news/news_repository.dart';
import '../../data/news/rss_parser.dart';
import 'providers.dart';

class NewsState {
  final bool loading;
  final List<NewsArticle> articles;
  final DateTime? fetchedAt;
  final bool fromCache;
  final Map<String, bool> sourceOk;
  final String? error;

  /// True when a refresh returned articles the user has not seen yet
  /// (DESIGN.md: News tab dot). Cleared by [NewsNotifier.markSeen].
  final bool hasNew;

  /// Article links the user has seen (recorded by [markSeen], and
  /// baselined on the first load so the first load never counts as
  /// new). A refresh compares its links against this set.
  final Set<String> seenLinks;

  /// True once a seen set has been established (first load or a
  /// visit), even when that set is empty: without this, an empty
  /// first load would leave [seenLinks] empty and the next refresh
  /// would look like another first load instead of new content.
  final bool seenBaseline;

  const NewsState({
    this.loading = false,
    this.articles = const [],
    this.fetchedAt,
    this.fromCache = false,
    this.sourceOk = const {},
    this.error,
    this.hasNew = false,
    this.seenLinks = const {},
    this.seenBaseline = false,
  });

  NewsState copyWith({
    bool? loading,
    List<NewsArticle>? articles,
    DateTime? fetchedAt,
    bool? fromCache,
    Map<String, bool>? sourceOk,
    String? error,
    bool? hasNew,
    Set<String>? seenLinks,
    bool? seenBaseline,
  }) =>
      NewsState(
        loading: loading ?? this.loading,
        articles: articles ?? this.articles,
        fetchedAt: fetchedAt ?? this.fetchedAt,
        fromCache: fromCache ?? this.fromCache,
        sourceOk: sourceOk ?? this.sourceOk,
        error: error,
        hasNew: hasNew ?? this.hasNew,
        seenLinks: seenLinks ?? this.seenLinks,
        seenBaseline: seenBaseline ?? this.seenBaseline,
      );
}

class NewsNotifier extends StateNotifier<NewsState> {
  final NewsRepository _repo;

  NewsNotifier(this._repo) : super(const NewsState(loading: true)) {
    refresh();
  }

  Future<void> refresh({bool force = false}) async {
    state = state.copyWith(loading: true, error: null);
    try {
      final result = await _repo.fetch(forceRefresh: force);
      final links = result.articles.map((a) => a.link).toSet();
      // No prior seen set: this is the first load, so it baselines
      // the seen set instead of counting as new.
      final hasNew = !state.seenBaseline
          ? false
          : links.difference(state.seenLinks).isNotEmpty;
      state = NewsState(
        articles: result.articles,
        fetchedAt: result.fetchedAt,
        fromCache: result.fromCache,
        sourceOk: result.sourceOk,
        hasNew: hasNew,
        seenLinks: state.seenBaseline ? state.seenLinks : links,
        seenBaseline: true,
      );
    } catch (e) {
      state = state.copyWith(
        loading: false,
        error: 'Couldn\'t load news. Pull to retry.',
      );
    }
  }

  /// The user visited News: clear the dot and record the current
  /// articles as seen, so the next refresh can tell new from old.
  void markSeen() {
    state = state.copyWith(
      hasNew: false,
      seenLinks: state.articles.map((a) => a.link).toSet(),
      seenBaseline: true,
    );
  }
}

/// Overridden in main() after Hive opens.
final newsRepositoryProvider =
    Provider<NewsRepository>((ref) => throw UnimplementedError());

final newsProvider =
    StateNotifierProvider<NewsNotifier, NewsState>(
        (ref) => NewsNotifier(ref.watch(newsRepositoryProvider)));

/// Normalized liked-artist set: favorites + last 3 seed playlists (FR-24).
final likedArtistsProvider = Provider<Set<String>>((ref) {
  ref.watch(favoritesVersionProvider);
  final liked = <String>{};
  final favRepo = ref.watch(favoritesRepositoryProvider);
  for (final a in favRepo.favoritedArtists()) {
    final n = normalizeArtist(a);
    if (n.isNotEmpty) liked.add(n);
  }
  final playlists = ref.watch(savedPlaylistsProvider);
  for (final p in playlists.take(3)) {
    for (final t in p.tracks) {
      final n = normalizeArtist(t.artist);
      if (n.isNotEmpty) liked.add(n);
    }
  }
  return liked;
});

/// For You ranking (FR-24); empty-likes fallback handled by the screen (FR-25).
final forYouArticlesProvider = Provider<List<NewsArticle>>((ref) {
  final articles = ref.watch(newsProvider).articles;
  final liked = ref.watch(likedArtistsProvider);
  if (liked.isEmpty) return articles;
  return rankForYou(articles: articles, likedArtists: liked, now: DateTime.now());
});
