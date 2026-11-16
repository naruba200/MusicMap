// News (S-10): the front page. Latest / For you tabs, article rows
// with image, title, source and time, per-source failure notes, and a
// last-updated stamp. Pull to refresh; the News tab dot (see
// news_provider.dart) marks content newer than the last visit.
// For-you with no liked artists falls back to Latest with the hint
// about hearting songs.

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/appearance.dart';
import '../../../core/time_ago.dart';
import '../../data/news/news_source.dart';
import '../../data/news/rss_parser.dart';
import '../providers/news_provider.dart';
import '../providers/providers.dart';
import '../widgets/editorial_widgets.dart';

class NewsScreen extends ConsumerWidget {
  const NewsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final news = ref.watch(newsProvider);
    final repo = ref.watch(newsRepositoryProvider);
    final hasEnabled = repo.enabledSources.isNotEmpty;

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('News'),
          bottom: const TabBar(
            tabs: [Tab(text: 'Latest'), Tab(text: 'For you')],
          ),
        ),
        body: RefreshIndicator(
          onRefresh: () =>
              ref.read(newsProvider.notifier).refresh(force: true),
          child: _body(context, ref, news, hasEnabled),
        ),
      ),
    );
  }

  Widget _body(
      BuildContext context, WidgetRef ref, NewsState news, bool hasEnabled) {
    if (news.loading && news.articles.isEmpty) {
      return const EditorialLoadingState(
          message: 'Loading the latest stories');
    }
    if (news.error != null && news.articles.isEmpty) {
      return EditorialErrorState(
        message: 'Could not load news. Check your connection and retry.',
        onRetry: () =>
            ref.read(newsProvider.notifier).refresh(force: true),
      );
    }
    if (!hasEnabled) {
      return EditorialEmptyState(
        message: 'All news sources are off. Turn at least one source '
            'on to see stories here.',
        actionLabel: 'Open News sources',
        onAction: () =>
            ref.read(tabIndexProvider.notifier).state = 5, // Settings tab
      );
    }
    return Column(
      children: [
        if (news.fetchedAt != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      news.fromCache
                          ? Icons.cloud_off_outlined
                          : Icons.check_circle_outline,
                      size: 14,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      news.fromCache
                          ? 'Offline, updated ${timeAgo(news.fetchedAt!)}'
                          : 'Updated ${timeAgo(news.fetchedAt!)}',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurfaceVariant),
                    ),
                  ],
                ),
                if (_failedSources(news).isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Could not load ${_failedSources(news).join(', ')}. '
                    'Stories from the other sources are shown.',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Theme.of(context)
                            .colorScheme
                            .onSurfaceVariant),
                  ),
                ],
              ],
            ),
          ),
        Expanded(
          child: TabBarView(
            children: [
              _articleList(
                  ref, news.articles, 'news-latest', 'Latest stories', '最新'),
              _forYouTab(context, ref),
            ],
          ),
        ),
      ],
    );
  }

  /// Names of the enabled sources that failed on the last fetch.
  List<String> _failedSources(NewsState news) => [
        for (final s in newsSources)
          if (news.sourceOk[s.id] == false) s.name,
      ];

  Widget _forYouTab(BuildContext context, WidgetRef ref) {
    final liked = ref.watch(likedArtistsProvider);
    final articles = ref.watch(forYouArticlesProvider);
    if (liked.isEmpty) {
      // Fall back to Latest with a teaching hint.
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              'Heart some songs and this tab will learn your taste.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ),
          Expanded(
            child: _articleList(
                ref, articles, 'news-foryou', 'Latest stories', '最新'),
          ),
        ],
      );
    }
    if (articles.isEmpty) {
      return const EditorialEmptyState(
        message: 'No stories match your taste yet. Heart more songs '
            'from the artists you follow and check back.',
      );
    }
    return _articleList(ref, articles, 'news-foryou', 'For you', '最新');
  }

  Widget _articleList(WidgetRef ref, List<NewsArticle> articles,
      String storageKey, String headerTitle, String headerKanji) {
    if (articles.isEmpty) {
      return const EditorialEmptyState(
        message: 'No stories right now. Pull down to refresh.',
      );
    }
    return _ArticleListView(
      articles: articles,
      storageKey: storageKey,
      headerTitle: headerTitle,
      headerKanji: headerKanji,
    );
  }
}

/// The article list: a ruled list of rows (image, title, source and
/// time). In Complex the list gains a section header and larger
/// images; the rows themselves stay the same ruled list.
class _ArticleListView extends StatelessWidget {
  final List<NewsArticle> articles;
  final String storageKey;
  final String headerTitle;
  final String headerKanji;

  const _ArticleListView({
    required this.articles,
    required this.storageKey,
    required this.headerTitle,
    required this.headerKanji,
  });

  @override
  Widget build(BuildContext context) {
    final complex = Theme.of(context)
            .extension<MusicManDesignTokens>()
            ?.design ==
        AppDesign.complex;
    return ListView.builder(
      // Keep scroll position when returning from an article.
      key: PageStorageKey<String>(storageKey),
      padding: const EdgeInsets.only(top: 4, bottom: 16),
      itemCount: articles.length + (complex ? 1 : 0),
      itemBuilder: (context, i) {
        if (complex && i == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: SectionHeader(
              kanji: headerKanji,
              title: headerTitle,
            ),
          );
        }
        final article = articles[complex ? i - 1 : i];
        return _ArticleRow(article: article, imageSize: complex ? 96 : 72);
      },
    );
  }
}

class _ArticleRow extends StatelessWidget {
  final NewsArticle article;
  final double imageSize;

  const _ArticleRow({required this.article, required this.imageSize});

  Future<void> _open(BuildContext context) async {
    final uri = Uri.tryParse(article.link);
    if (uri == null) return;
    // Custom Tab: system back returns to the feed.
    if (!await launchUrl(uri, mode: LaunchMode.inAppBrowserView)) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open article.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return InkWell(
      onTap: () => _open(context),
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: scheme.outline)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (article.imageUrl != null && article.imageUrl!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: CachedNetworkImage(
                    imageUrl: article.imageUrl!,
                    width: imageSize,
                    height: imageSize,
                    fit: BoxFit.cover,
                    placeholder: (_, __) => Container(
                      width: imageSize,
                      height: imageSize,
                      color: scheme.surface,
                    ),
                    errorWidget: (_, __, ___) => Container(
                      width: imageSize,
                      height: imageSize,
                      color: scheme.surface,
                      alignment: Alignment.center,
                      child: Icon(
                        Icons.article_outlined,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(article.title,
                      style: theme.textTheme.titleSmall,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis),
                  if (article.summary != null &&
                      article.summary!.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(article.summary!,
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis),
                  ],
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: Text(article.sourceName,
                            style: theme.textTheme.labelSmall?.copyWith(
                                color: scheme.onSurfaceVariant),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                      ),
                      if (article.publishedAt != null) ...[
                        const SizedBox(width: 8),
                        Text(timeAgo(article.publishedAt!),
                            style: theme.textTheme.labelSmall?.copyWith(
                                color: scheme.onSurfaceVariant)),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
