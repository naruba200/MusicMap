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

  const NewsState({
    this.loading = false,
    this.articles = const [],
    this.fetchedAt,
    this.fromCache = false,
    this.sourceOk = const {},
    this.error,
  });

  NewsState copyWith({
    bool? loading,
    List<NewsArticle>? articles,
    DateTime? fetchedAt,
    bool? fromCache,
    Map<String, bool>? sourceOk,
    String? error,
  }) =>
      NewsState(
        loading: loading ?? this.loading,
        articles: articles ?? this.articles,
        fetchedAt: fetchedAt ?? this.fetchedAt,
        fromCache: fromCache ?? this.fromCache,
        sourceOk: sourceOk ?? this.sourceOk,
        error: error,
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
      state = NewsState(
        articles: result.articles,
        fetchedAt: result.fetchedAt,
        fromCache: result.fromCache,
        sourceOk: result.sourceOk,
      );
    } catch (e) {
      state = state.copyWith(
        loading: false,
        error: 'Couldn\'t load news. Pull to retry.',
      );
    }
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
