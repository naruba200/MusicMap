// News (S-02 tab, M4, FR-20…FR-27): Latest / For you tabs, pull-to-refresh,
// article cards with lazy images, Custom Tab article view, offline cache
// stamp, and empty states (all sources off → link to Settings).

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/time_ago.dart';
import '../../data/news/rss_parser.dart';
import '../providers/news_provider.dart';
import '../providers/providers.dart';

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
      return const Center(child: CircularProgressIndicator());
    }
    if (news.error != null && news.articles.isEmpty) {
      return _centerMessage(
        Icons.cloud_off_outlined,
        news.error!,
        action: TextButton(
          onPressed: () => ref.read(newsProvider.notifier).refresh(force: true),
          child: const Text('Retry'),
        ),
      );
    }
    if (!hasEnabled) {
      return _centerMessage(
        Icons.newspaper_outlined,
        'All news sources are off.',
        action: TextButton(
          onPressed: () =>
              ref.read(tabIndexProvider.notifier).state = 4, // Settings tab
          child: const Text('Open News sources'),
        ),
      );
    }
    return Column(
      children: [
        if (news.fetchedAt != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
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
                      ? 'Offline — updated ${timeAgo(news.fetchedAt!)}'
                      : 'Updated ${timeAgo(news.fetchedAt!)}',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        Expanded(
          child: TabBarView(
            children: [
              _articleList(ref, news.articles, 'news-latest'),
              _forYouTab(context, ref),
            ],
          ),
        ),
      ],
    );
  }

  Widget _forYouTab(BuildContext context, WidgetRef ref) {
    final liked = ref.watch(likedArtistsProvider);
    final articles = ref.watch(forYouArticlesProvider);
    if (liked.isEmpty) {
      // FR-25: fall back to Latest with a teaching hint.
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
          Expanded(child: _articleList(ref, articles, 'news-foryou')),
        ],
      );
    }
    if (articles.isEmpty) {
      return _centerMessage(
          Icons.star_outline, 'No stories match your taste yet.');
    }
    return _articleList(ref, articles, 'news-foryou');
  }

  Widget _articleList(
      WidgetRef ref, List<NewsArticle> articles, String storageKey) {
    if (articles.isEmpty) {
      return _centerMessage(
          Icons.newspaper_outlined, 'No stories right now.');
    }
    return ListView.builder(
      // Keep scroll position when returning from an article (FR-26).
      key: PageStorageKey<String>(storageKey),
      itemCount: articles.length,
      itemBuilder: (_, i) => _ArticleCard(article: articles[i]),
    );
  }

  Widget _centerMessage(IconData icon, String message, {Widget? action}) =>
      Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 56),
              const SizedBox(height: 12),
              Text(message, textAlign: TextAlign.center),
              if (action != null) ...[
                const SizedBox(height: 8),
                action,
              ],
            ],
          ),
        ),
      );
}

class _ArticleCard extends StatelessWidget {
  final NewsArticle article;

  const _ArticleCard({required this.article});

  Future<void> _open(BuildContext context) async {
    final uri = Uri.tryParse(article.link);
    if (uri == null) return;
    // Custom Tab: system back returns to the feed (FR-26).
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
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _open(context),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (article.imageUrl != null && article.imageUrl!.isNotEmpty)
              CachedNetworkImage(
                imageUrl: article.imageUrl!,
                height: 160,
                width: double.infinity,
                fit: BoxFit.cover,
                placeholder: (_, __) => Container(
                  height: 160,
                  color: theme.colorScheme.surfaceContainerHighest,
                ),
                errorWidget: (_, __, ___) => const SizedBox.shrink(),
              ),
            Padding(
              padding: const EdgeInsets.all(12),
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
                        style: theme.textTheme.bodySmall,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis),
                  ],
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Text(article.sourceName,
                          style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.primary)),
                      const SizedBox(width: 8),
                      if (article.publishedAt != null)
                        Text(timeAgo(article.publishedAt!),
                            style: theme.textTheme.labelSmall?.copyWith(
                                color: theme
                                    .colorScheme.onSurfaceVariant)),
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
