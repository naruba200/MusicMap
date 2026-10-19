// News fetching + caching (FR-20/21/22): all enabled sources fetched
// concurrently with per-source isolation (a failing feed never breaks the
// tab), 10 s timeout each, browser-like User-Agent, redirects followed
// (Stereogum/EDM.com 301/308 to their feeds). Articles cached 1 h in Hive;
// offline readers get the cached feed with its stamp. Dedupe by link.

import 'package:dio/dio.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'news_source.dart';
import 'rss_parser.dart';

class NewsFetchResult {
  final List<NewsArticle> articles;
  final DateTime fetchedAt;
  final Map<String, bool> sourceOk;
  final bool fromCache;

  const NewsFetchResult({
    required this.articles,
    required this.fetchedAt,
    required this.sourceOk,
    this.fromCache = false,
  });
}

class NewsRepository {
  static const boxName = 'news';
  static const cacheTtl = Duration(hours: 1);
  static const _browserUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  final Box _box;
  final Dio _dio;

  NewsRepository(this._box, this._dio);

  static Future<NewsRepository> open(Dio dio) async {
    final box = await Hive.openBox(boxName);
    return NewsRepository(box, dio);
  }

  // -- Source toggles (FR-20, FR-27) ------------------------------------------

  bool isEnabled(String sourceId) =>
      _box.get('src_$sourceId', defaultValue: true) as bool;

  Future<void> setEnabled(String sourceId, bool enabled) =>
      _box.put('src_$sourceId', enabled);

  List<NewsSource> get enabledSources =>
      [for (final s in newsSources) if (isEnabled(s.id)) s];

  // -- Fetch ------------------------------------------------------------------

  Future<NewsFetchResult> fetch({bool forceRefresh = false}) async {
    final cached = _readCache();
    if (!forceRefresh && cached != null && !_isStale(cached.fetchedAt)) {
      return cached;
    }
    final sources = enabledSources;
    if (sources.isEmpty) {
      return NewsFetchResult(
        articles: cached?.articles ?? const [],
        fetchedAt: cached?.fetchedAt ?? DateTime.now(),
        sourceOk: const {},
        fromCache: cached != null,
      );
    }
    final fetches = await Future.wait([
      for (final s in sources) _fetchSource(s),
    ]);
    final articles = <NewsArticle>[];
    final sourceOk = <String, bool>{};
    for (final f in fetches) {
      sourceOk[f.sourceId] = f.ok;
      articles.addAll(f.articles);
    }
    final deduped = _dedupe(articles);
    _sortNewestFirst(deduped);
    if (deduped.isNotEmpty) {
      await _writeCache(deduped);
    }
    // Total failure but we have a cache: serve stale rather than nothing.
    if (deduped.isEmpty && cached != null) {
      return NewsFetchResult(
        articles: cached.articles,
        fetchedAt: cached.fetchedAt,
        sourceOk: sourceOk,
        fromCache: true,
      );
    }
    return NewsFetchResult(
      articles: deduped,
      fetchedAt: DateTime.now(),
      sourceOk: sourceOk,
    );
  }

  Future<_SourceFetch> _fetchSource(NewsSource source) async {
    try {
      final res = await _dio.get(
        source.feedUrl,
        options: Options(
          headers: {'User-Agent': _browserUa},
          sendTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 10),
          followRedirects: true,
        ),
      );
      final data = res.data;
      final xml = data is String ? data : data.toString();
      final articles = parseFeed(xml, source.id, source.name);
      return _SourceFetch(source.id, articles, true);
    } catch (_) {
      return _SourceFetch(source.id, const [], false);
    }
  }

  // -- Cache -------------------------------------------------------------------

  NewsFetchResult? _readCache() {
    final raw = _box.get('cache');
    if (raw is! Map) return null;
    try {
      final map = raw.cast<String, dynamic>();
      final articles = (map['articles'] as List?)
              ?.whereType<Map>()
              .map((m) => NewsArticle.fromJson(m.cast<String, dynamic>()))
              .toList() ??
          const [];
      return NewsFetchResult(
        articles: articles,
        fetchedAt:
            DateTime.tryParse(map['fetchedAt'] as String? ?? '') ??
                DateTime.fromMillisecondsSinceEpoch(0),
        sourceOk: const {},
        fromCache: true,
      );
    } catch (_) {
      return null;
    }
  }

  bool _isStale(DateTime fetchedAt) =>
      DateTime.now().difference(fetchedAt) > cacheTtl;

  Future<void> _writeCache(List<NewsArticle> articles) => _box.put('cache', {
        'fetchedAt': DateTime.now().toIso8601String(),
        'articles': [for (final a in articles) a.toJson()],
      });

  // -- Dedupe + sort (FR-22, FR-23) ----------------------------------------------

  /// Drop duplicate links, keeping the first occurrence.
  static List<NewsArticle> _dedupe(List<NewsArticle> articles) {
    final seen = <String>{};
    return [
      for (final a in articles)
        if (seen.add(a.link)) a,
    ];
  }

  /// Newest first; missing/invalid dates sort last.
  static void _sortNewestFirst(List<NewsArticle> articles) {
    articles.sort((a, b) {
      final da = a.publishedAt;
      final db = b.publishedAt;
      if (da == null && db == null) return 0;
      if (da == null) return 1;
      if (db == null) return -1;
      return db.compareTo(da);
    });
  }
}

class _SourceFetch {
  final String sourceId;
  final List<NewsArticle> articles;
  final bool ok;

  const _SourceFetch(this.sourceId, this.articles, this.ok);
}
