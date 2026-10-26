// Favorites (S-07, FR-12/12b/12c): Daily picks on top, hearted items grouped
// Songs/Albums, multi-select mode via the selection icon, swipe-to-remove.

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/engine/recommendation_engine.dart';
import '../../data/models/music_models.dart';
import '../providers/daily_picks_provider.dart';
import '../providers/providers.dart';
import '../widgets/outbound_sheet.dart';
import '../widgets/youtube_export_sheet.dart';
import 'album_detail_screen.dart';
import 'artist_events_screen.dart';

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

  @override
  Widget build(BuildContext context) {
    final tracks = ref.watch(favoriteTracksProvider);
    final albums = ref.watch(favoriteAlbumsProvider);
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
                MaterialPageRoute(
                  builder: (_) => ArtistEventsScreen(
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
          bottom: const TabBar(
            tabs: [Tab(text: 'Songs'), Tab(text: 'Albums')],
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
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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

  Widget _dailyPicksSection() {
    final picks = ref.watch(dailyPicksProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
          child: Row(
            children: [
              Text('Daily picks',
                  style: Theme.of(context).textTheme.titleSmall),
              const Spacer(),
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
          height: 132,
          child: picks.when(
            loading: () =>
                const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(
              child: TextButton(
                onPressed: () =>
                    ref.read(dailyPicksProvider.notifier).refresh(),
                child: const Text('Couldn\'t load picks — retry'),
              ),
            ),
            data: (p) {
              if (p == null) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 32),
                    child: Text(
                      'Heart some songs to get daily picks.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                );
              }
              final items = [
                for (final s in p.songs) _PickItem.song(s),
                for (final a in p.albums) _PickItem.album(a),
              ];
              if (items.isEmpty) {
                return const Center(child: Text('No picks today.'));
              }
              return ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: items.length,
                separatorBuilder: (_, __) => const SizedBox(width: 12),
                itemBuilder: (_, i) {
                  final item = items[i];
                  return InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => item.song != null
                        ? showOutboundSheet(context, item.song!.track)
                        : Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) =>
                                AlbumDetailScreen(album: item.album!))),
                    child: SizedBox(
                      width: 104,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _pickArt(item),
                          const SizedBox(height: 4),
                          Text(item.title,
                              style: Theme.of(context).textTheme.bodySmall,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                          Text(item.artist,
                              style: Theme.of(context)
                                  .textTheme
                                  .labelSmall
                                  ?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant),
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

  Widget _pickArt(_PickItem item) {
    final url = item.artUrl;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: url != null && url.isNotEmpty
          ? CachedNetworkImage(
              imageUrl: url,
              width: 104,
              height: 88,
              fit: BoxFit.cover,
              errorWidget: (_, __, ___) =>
                  const Icon(Icons.music_note_outlined, size: 40),
            )
          : Container(
              width: 104,
              height: 88,
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: const Icon(Icons.music_note_outlined, size: 40),
            ),
    );
  }

  // -- Songs tab ---------------------------------------------------------------

  Widget _songsTab(List<Track> tracks) {
    if (tracks.isEmpty) {
      return _emptyState(Icons.favorite_outline,
          'No favorite songs yet.\nTap the heart on any recommendation.');
    }
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
            ref.read(favoritesRepositoryProvider).remove(t.artist, t.title);
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
                : t.imageUrl != null && t.imageUrl!.isNotEmpty
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: CachedNetworkImage(
                          imageUrl: t.imageUrl!,
                          width: 48,
                          height: 48,
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) =>
                              const Icon(Icons.music_note_outlined),
                        ),
                      )
                    : const Icon(Icons.music_note_outlined, size: 40),
            title: Text(t.title,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(t.artist,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: _selectMode
                ? null
                : IconButton(
                    icon: const Icon(Icons.open_in_new, size: 20),
                    tooltip: 'Open in…',
                    onPressed: () => showOutboundSheet(context, t),
                  ),
            onTap: _selectMode
                ? () => setState(() =>
                    selected ? _selected.remove(k) : _selected.add(k))
                : () => showOutboundSheet(context, t),
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
      return _emptyState(Icons.album_outlined,
          'No favorite albums yet.\nTap the heart on any album.');
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
                        borderRadius: BorderRadius.circular(8),
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
                : () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => AlbumDetailScreen(album: a))),
          ),
        );
      },
    );
  }

  Widget _emptyState(IconData icon, String message) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 56),
              const SizedBox(height: 12),
              Text(message, textAlign: TextAlign.center),
            ],
          ),
        ),
      );
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
