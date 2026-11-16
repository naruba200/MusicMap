// Favorites (S-07, FR-12/12b/12c): "Today's picks" editorial block
// on top with a refresh action, then hearted items grouped into
// Songs and Albums with counts, multi-select mode with a bottom
// action bar, swipe-to-remove. Tap a song plays it (EditorialSongRow
// with the double-tap window); overflow opens it elsewhere. No swipe
// quick actions here (that is Phase C).

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/appearance.dart';
import '../../core/theme.dart';
import '../../data/engine/recommendation_engine.dart';
import '../../data/models/music_models.dart';
import '../providers/daily_picks_provider.dart';
import '../providers/providers.dart';
import '../widgets/editorial_route.dart';
import '../widgets/editorial_widgets.dart';
import '../widgets/outbound_sheet.dart';
import '../widgets/song_row.dart';
import '../widgets/youtube_export_sheet.dart';
import 'album_detail_screen.dart';
import 'artist_events_screen.dart';

bool _isComplex(BuildContext context) =>
    Theme.of(context).extension<MusicManDesignTokens>()?.design ==
    AppDesign.complex;

String _formatDuration(int ms) {
  final total = Duration(milliseconds: ms).inSeconds;
  return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')}';
}

class FavoritesScreen extends ConsumerStatefulWidget {
  const FavoritesScreen({super.key});

  @override
  ConsumerState<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends ConsumerState<FavoritesScreen> {
  bool _selectMode = false;
  final _selected = <String>{}; // normalizeKey(artist, title/name)

  String _key(String artist, String name) =>
      RecommendationEngine.normalizeKey(artist, name);

  void _toggleSelectMode() {
    setState(() {
      _selectMode = !_selectMode;
      _selected.clear();
    });
  }

  Future<void> _removeSelected() async {
    final repo = ref.read(favoritesRepositoryProvider);
    for (final k in _selected) {
      repo.removeByKey(k);
    }
    ref.read(favoritesVersionProvider.notifier).state++;
    final n = _selected.length;
    setState(() {
      _selectMode = false;
      _selected.clear();
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Removed $n favorite${n == 1 ? '' : 's'}.')),
      );
    }
  }

  void _goHome() {
    ref.read(tabIndexProvider.notifier).state = 0;
  }

  @override
  Widget build(BuildContext context) {
    final tracks = ref.watch(favoriteTracksProvider);
    final albums = ref.watch(favoriteAlbumsProvider);
    final scheme = Theme.of(context).colorScheme;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Favorites'),
          actions: [
            IconButton(
              icon: const Icon(Icons.event_outlined),
              tooltip: 'Upcoming events',
              onPressed: () => Navigator.of(context).push(
                editorialRoute(
                  context,
                  (_) => ArtistEventsScreen(
                    artists: ref
                        .read(favoritesRepositoryProvider)
                        .favoritedArtists(),
                  ),
                ),
              ),
            ),
            if (tracks.isNotEmpty || albums.isNotEmpty)
              IconButton(
                icon: Icon(_selectMode ? Icons.close : Icons.checklist),
                tooltip: _selectMode ? 'Cancel selection' : 'Select',
                onPressed: _toggleSelectMode,
              ),
          ],
          bottom: TabBar(
            tabs: [
              Tab(text: 'Songs (${tracks.length})'),
              Tab(text: 'Albums (${albums.length})'),
            ],
          ),
        ),
        body: Column(
          children: [
            _dailyPicksSection(),
            const Divider(height: 1),
            Expanded(
              child: TabBarView(
                children: [
                  _songsTab(tracks),
                  _albumsTab(albums),
                ],
              ),
            ),
          ],
        ),
        bottomNavigationBar: _selectMode && _selected.isNotEmpty
            ? SafeArea(
                child: Container(
                  decoration: BoxDecoration(
                    color: scheme.surface,
                    border: Border(
                        top: BorderSide(color: scheme.outline)),
                  ),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: FilledButton.tonal(
                          onPressed: _removeSelected,
                          child: Text('Remove (${_selected.length})'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      TextButton(
                        onPressed: _toggleSelectMode,
                        child: const Text('Cancel'),
                      ),
                    ],
                  ),
                ),
              )
            : null,
      ),
    );
  }

  // -- Daily picks (FR-12b) ---------------------------------------------------

  bool _hasPicks(AsyncValue<DailyPicks?> picks) => picks.maybeWhen(
        data: (p) =>
            p != null && (p.songs.isNotEmpty || p.albums.isNotEmpty),
        orElse: () => false,
      );

  Widget _dailyPicksSection() {
    final picks = ref.watch(dailyPicksProvider);
    final isComplex = _isComplex(context);
    final artWidth = isComplex ? 128.0 : 104.0;
    final artHeight = isComplex ? 112.0 : 88.0;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Text("Today's picks",
                        style: theme.textTheme.titleLarge),
                    const SizedBox(width: 8),
                    Text(
                      'お気に入り',
                      style: AppTheme.stampKanjiStyle(
                        color: theme.colorScheme.primary,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.refresh, size: 20),
                tooltip: 'Regenerate picks',
                onPressed: () =>
                    ref.read(dailyPicksProvider.notifier).refresh(),
              ),
            ],
          ),
        ),
        SizedBox(
          // The horizontal list is short; the loading, error, and
          // empty states carry a message plus a button, so they get
          // the taller slot instead of overflowing the list height.
          height: _hasPicks(picks)
              ? (isComplex ? 168 : 140)
              : 184,
          child: picks.when(
            loading: () => const EditorialLoadingState(
                message: "Loading today's picks"),
            error: (e, _) => EditorialErrorState(
              message: "Couldn't load today's picks. "
                  'Check your connection and try again.',
              onRetry: () =>
                  ref.read(dailyPicksProvider.notifier).refresh(),
            ),
            data: (p) {
              if (p == null) {
                return Center(
                  child: EditorialEmptyState(
                    message: 'No picks yet. Heart some songs and fresh '
                        'picks will appear here.',
                    actionLabel: 'Browse home',
                    onAction: _goHome,
                  ),
                );
              }
              final items = [
                for (final s in p.songs) _PickItem.song(s),
                for (final a in p.albums) _PickItem.album(a),
              ];
              if (items.isEmpty) {
                return Center(
                  child: EditorialEmptyState(
                    message: 'No picks today. Heart some songs and '
                        'fresh picks will appear here.',
                    actionLabel: 'Browse home',
                    onAction: _goHome,
                  ),
                );
              }
              return ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: items.length,
                separatorBuilder: (_, __) => const SizedBox(width: 12),
                itemBuilder: (_, i) {
                  final item = items[i];
                  return InkWell(
                    borderRadius: BorderRadius.circular(2),
                    onTap: () => item.song != null
                        ? showOutboundSheet(context, item.song!.track)
                        : Navigator.of(context).push(editorialRoute(
                            context,
                            (_) =>
                                AlbumDetailScreen(album: item.album!))),
                    child: SizedBox(
                      width: artWidth,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _pickArt(item, artWidth, artHeight),
                          const SizedBox(height: 4),
                          Text(item.title,
                              style: theme.textTheme.bodySmall,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                          Text(item.artist,
                              style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _pickArt(_PickItem item, double width, double height) {
    final url = item.artUrl;
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: url != null && url.isNotEmpty
          ? CachedNetworkImage(
              imageUrl: url,
              width: width,
              height: height,
              fit: BoxFit.cover,
              errorWidget: (_, __, ___) =>
                  const Icon(Icons.music_note_outlined, size: 40),
            )
          : Container(
              width: width,
              height: height,
              color: Theme.of(context).colorScheme.surface,
              child: const Icon(Icons.music_note_outlined, size: 40),
            ),
    );
  }

  // -- Songs tab ---------------------------------------------------------------

  Widget _songsTab(List<Track> tracks) {
    if (tracks.isEmpty) {
      return Center(
        child: EditorialEmptyState(
          message: 'No favorite songs yet. '
              'Tap the heart on any recommendation.',
          actionLabel: 'Browse home',
          onAction: _goHome,
        ),
      );
    }
    final isComplex = _isComplex(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(
              onPressed: () => showYouTubeExportSheet(context, ref, tracks),
              icon: const Icon(Icons.open_in_new),
              label: const Text('Export to YouTube'),
            ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: tracks.length,
            itemBuilder: (_, i) {
              final t = tracks[i];
              final k = _key(t.artist, t.title);
              final selected = _selected.contains(k);
              return Dismissible(
                key: ValueKey('fav-song-$k'),
                direction: _selectMode
                    ? DismissDirection.none
                    : DismissDirection.endToStart,
                background: Container(
                  color: Theme.of(context).colorScheme.errorContainer,
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 20),
                  child: const Icon(Icons.delete_outline),
                ),
                onDismissed: (_) {
                  ref
                      .read(favoritesRepositoryProvider)
                      .remove(t.artist, t.title);
                  ref.read(favoritesVersionProvider.notifier).state++;
                },
                child: _selectMode
                    ? ListTile(
                        leading: Checkbox(
                          value: selected,
                          onChanged: (_) => setState(() => selected
                              ? _selected.remove(k)
                              : _selected.add(k)),
                        ),
                        title: Text(t.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                        subtitle: Text(t.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                        onTap: () => setState(() => selected
                            ? _selected.remove(k)
                            : _selected.add(k)),
                      )
                    : EditorialSongRow(
                        track: t,
                        queue: tracks,
                        meta: isComplex && t.durationMs != null
                            ? _formatDuration(t.durationMs!)
                            : null,
                        onOverflow: () => showOutboundSheet(context, t),
                      ),
              );
            },
          ),
        ),
      ],
    );
  }

  // -- Albums tab --------------------------------------------------------------

  Widget _albumsTab(List<AlbumRec> albums) {
    if (albums.isEmpty) {
      return Center(
        child: EditorialEmptyState(
          message: 'No favorite albums yet. '
              'Tap the heart on any album.',
          actionLabel: 'Browse home',
          onAction: _goHome,
        ),
      );
    }
    return ListView.builder(
      itemCount: albums.length,
      itemBuilder: (_, i) {
        final a = albums[i];
        final k = _key(a.artist, a.name);
        final selected = _selected.contains(k);
        return Dismissible(
          key: ValueKey('fav-album-$k'),
          direction: _selectMode
              ? DismissDirection.none
              : DismissDirection.endToStart,
          background: Container(
            color: Theme.of(context).colorScheme.errorContainer,
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 20),
            child: const Icon(Icons.delete_outline),
          ),
          onDismissed: (_) {
            ref.read(favoritesRepositoryProvider).remove(a.artist, a.name);
            ref.read(favoritesVersionProvider.notifier).state++;
          },
          child: ListTile(
            leading: _selectMode
                ? Checkbox(
                    value: selected,
                    onChanged: (_) => setState(() => selected
                        ? _selected.remove(k)
                        : _selected.add(k)),
                  )
                : a.artUrl != null && a.artUrl!.isNotEmpty
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: CachedNetworkImage(
                          imageUrl: a.artUrl!,
                          width: 48,
                          height: 48,
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) =>
                              const Icon(Icons.album_outlined),
                        ),
                      )
                    : const Icon(Icons.album_outlined, size: 40),
            title:
                Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle:
                Text(a.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: _selectMode
                ? null
                : IconButton(
                    icon: const Icon(Icons.open_in_new, size: 20),
                    tooltip: 'Open album in…',
                    onPressed: () => showAlbumOutboundSheet(
                        context, a.artist, a.name),
                  ),
            onTap: _selectMode
                ? () => setState(() =>
                    selected ? _selected.remove(k) : _selected.add(k))
                : () => Navigator.of(context).push(editorialRoute(
                    context,
                    (_) => AlbumDetailScreen(album: a))),
          ),
        );
      },
    );
  }
}

class _PickItem {
  final ScoredTrack? song;
  final AlbumRec? album;

  _PickItem.song(this.song) : album = null;
  _PickItem.album(this.album) : song = null;

  String get title => song?.track.title ?? album!.name;
  String get artist => song?.track.artist ?? album!.artist;
  String? get artUrl => song?.track.imageUrl ?? album?.artUrl;
}
