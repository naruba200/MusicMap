// Discover tab (Phase 4): one tab per new source, each kept separate from
// core recommendations. Audius tracks play in full inside this tab only;
// nothing here is merged into the main Last.fm recommendation pool.

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../data/discover/audius_client.dart';
import '../../data/discover/jamendo_client.dart';
import '../../data/models/music_models.dart';
import '../providers/discover_provider.dart';
import '../providers/generation_provider.dart';
import 'generating_screen.dart';

/// Discover screen: a TabBar with one tab per Phase 4 source.
/// Tabs are added one push at a time (Audius first); a tab whose source
/// fails shows its own error state and never blocks the other tabs.
class DiscoverScreen extends ConsumerWidget {
  const DiscoverScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Discover'),
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.audiotrack), text: 'Audius'),
              Tab(icon: Icon(Icons.library_music), text: 'Jamendo'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            _AudiusTab(),
            _JamendoTab(),
          ],
        ),
      ),
    );
  }
}

/// A small in-tab audio player: one AudioPlayer per tab, play/pause by
/// track id, stopped when the tab is disposed. Full streams only — this
/// player never touches the core preview player.
class _TabPlayer {
  final AudioPlayer _player = AudioPlayer();
  String? playingId;

  Future<void> toggle(String id, String url) async {
    if (playingId == id) {
      await _player.pause();
      playingId = null;
    } else {
      await _player.stop();
      await _player.play(UrlSource(url));
      playingId = id;
    }
  }

  Future<void> dispose() async {
    await _player.stop();
    await _player.dispose();
  }
}

// -- Audius tab -------------------------------------------------------------

class _AudiusTab extends ConsumerStatefulWidget {
  const _AudiusTab();

  @override
  ConsumerState<_AudiusTab> createState() => _AudiusTabState();
}

class _AudiusTabState extends ConsumerState<_AudiusTab> {
  static const _genres = [
    'all',
    'Electronic',
    'Hip-Hop/Rap',
    'Rock',
    'Pop',
    'R&B/Soul',
    'Alternative',
  ];

  String _genre = 'all';
  final _searchController = TextEditingController();
  final _playlistController = TextEditingController();
  String _search = '';
  String? _playlistId;
  final _player = _TabPlayer();

  @override
  void dispose() {
    _searchController.dispose();
    _playlistController.dispose();
    _player.dispose();
    super.dispose();
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  void _getRecommendations(PlaylistInfo info, List<Track> tracks) {
    if (tracks.length < minUsableTracks) {
      _snack('Need at least $minUsableTracks tracks — '
          'this playlist has ${tracks.length}.');
      return;
    }
    ref.read(generationProvider.notifier).reset();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => GeneratingScreen(
          args: GenerationArgs(
            surprise: false,
            seedName: info.name,
            seedPlaylistId: info.id,
            seedPlatformId: 'audius',
            tracks: tracks,
            settings: const DiscoverySettings(
              songCount: defaultSongCount,
              albumCount: defaultAlbumCount,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final trending = ref.watch(audiusTrendingProvider(_genre));
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Audius streams play in full here, inside this tab only. '
          'Audius tracks never mix into your main recommendations.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        Text('Trending', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final genre in _genres)
              FilterChip(
                label: Text(genre == 'all' ? 'All' : genre),
                selected: _genre == genre,
                onSelected: (v) {
                  if (v) setState(() => _genre = genre);
                },
              ),
          ],
        ),
        const SizedBox(height: 8),
        trending.when(
          data: (load) => _TrackList(
            load: load,
            player: _player,
            onRetry: () => ref.invalidate(audiusTrendingProvider(_genre)),
            onRefresh: () => setState(() {}),
          ),
          loading: () => const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => _ErrorRow(
            message: 'Couldn\'t load Audius trending.',
            onRetry: () => ref.invalidate(audiusTrendingProvider(_genre)),
          ),
        ),
        const SizedBox(height: 24),
        Text('Search tracks',
            style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _searchController,
                decoration: const InputDecoration(
                  hintText: 'Search Audius tracks…',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) =>
                    setState(() => _search = _searchController.text.trim()),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: () =>
                  setState(() => _search = _searchController.text.trim()),
              child: const Text('Search'),
            ),
          ],
        ),
        if (_search.isNotEmpty) ...[
          const SizedBox(height: 8),
          _AudiusSearchResults(
            query: _search,
            player: _player,
            onRefresh: () => setState(() {}),
          ),
        ],
        const SizedBox(height: 24),
        Text('Import an Audius playlist',
            style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _playlistController,
                decoration: const InputDecoration(
                  hintText: 'audius.co/…/playlist/… or playlist id',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.url,
                onSubmitted: (_) => _importPlaylist(),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _importPlaylist,
              child: const Text('Import'),
            ),
          ],
        ),
        if (_playlistId != null) ...[
          const SizedBox(height: 8),
          _AudiusPlaylistView(
            playlistId: _playlistId!,
            player: _player,
            onRecommendations: _getRecommendations,
            onRefresh: () => setState(() {}),
          ),
        ],
      ],
    );
  }

  void _importPlaylist() {
    // The view resolves raw text to a numeric id via
    // AudiusClient.parsePlaylistLink; an unparseable link shows a hint
    // there instead of a failed load.
    final text = _playlistController.text.trim();
    if (text.isEmpty) {
      _snack('Paste an Audius playlist link or id first.');
      return;
    }
    setState(() => _playlistId = text);
  }
}

/// Search results for the Audius tab (track list with in-tab playback).
class _AudiusSearchResults extends ConsumerWidget {
  final String query;
  final _TabPlayer player;
  final VoidCallback onRefresh;

  const _AudiusSearchResults({
    required this.query,
    required this.player,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final results = ref.watch(audiusSearchProvider(query));
    return results.when(
      data: (load) => _TrackList(
        load: load,
        player: player,
        onRetry: () => ref.invalidate(audiusSearchProvider(query)),
        onRefresh: onRefresh,
      ),
      loading: () => const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => _ErrorRow(
        message: 'Audius search failed.',
        onRetry: () => ref.invalidate(audiusSearchProvider(query)),
      ),
    );
  }
}

/// An imported Audius playlist: track list + "Get recommendations".
class _AudiusPlaylistView extends ConsumerWidget {
  final String playlistId;
  final _TabPlayer player;
  final void Function(PlaylistInfo, List<Track>) onRecommendations;
  final VoidCallback onRefresh;

  const _AudiusPlaylistView({
    required this.playlistId,
    required this.player,
    required this.onRecommendations,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The provider takes a numeric id; resolve links here so a bad link
    // shows a hint instead of a failed load.
    final resolved = AudiusClient.parsePlaylistLink(playlistId);
    if (resolved == null) {
      return const Text(
        'That doesn\'t look like an Audius playlist link or id — '
        'an Audius playlist link ends in a number, e.g. '
        'audius.co/user/playlist/name-123456.',
        style: TextStyle(fontStyle: FontStyle.italic),
      );
    }
    final load = ref.watch(audiusPlaylistProvider(resolved));
    return load.when(
      data: (data) {
        if (data.error != null) {
          return _ErrorRow(
            message: data.error!,
            onRetry: () =>
                ref.invalidate(audiusPlaylistProvider(resolved)),
          );
        }
        final info = data.info!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: info.coverUrl != null
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: Image.network(info.coverUrl!,
                          width: 48, height: 48, fit: BoxFit.cover),
                    )
                  : const Icon(Icons.queue_music, size: 40),
              title: Text(info.name),
              subtitle: Text(
                  '${info.owner ?? 'Audius'} · ${data.tracks.length} tracks'),
            ),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => onRecommendations(info, data.tracks),
                child: const Text('Get recommendations'),
              ),
            ),
            const SizedBox(height: 8),
            _TrackList(
              load: DiscoverLoad(items: data.tracks),
              player: player,
              onRetry: () =>
                  ref.invalidate(audiusPlaylistProvider(resolved)),
              onRefresh: onRefresh,
            ),
          ],
        );
      },
      loading: () => const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => _ErrorRow(
        message: 'Couldn\'t import that Audius playlist.',
        onRetry: () => ref.invalidate(audiusPlaylistProvider(resolved)),
      ),
    );
  }
}

/// Shared track list with in-tab full-stream playback. The [load] error
/// label is shown inline; an empty list with no error means "nothing
/// found", not a failure.
class _TrackList extends StatefulWidget {
  final DiscoverLoad<Track> load;
  final _TabPlayer player;
  final VoidCallback onRetry;
  final VoidCallback onRefresh;

  const _TrackList({
    required this.load,
    required this.player,
    required this.onRetry,
    required this.onRefresh,
  });

  @override
  State<_TrackList> createState() => _TrackListState();
}

class _TrackListState extends State<_TrackList> {
  @override
  Widget build(BuildContext context) {
    if (widget.load.error != null) {
      return _ErrorRow(
          message: widget.load.error!, onRetry: widget.onRetry);
    }
    if (widget.load.items.isEmpty) {
      return Text(
        'Nothing here yet.',
        style: Theme.of(context).textTheme.bodySmall,
      );
    }
    return Column(
      children: [
        for (final track in widget.load.items)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: track.imageUrl != null
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.network(track.imageUrl!,
                        width: 48, height: 48, fit: BoxFit.cover),
                  )
                : const Icon(Icons.audiotrack, size: 40),
            title: Text(track.title,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text('From Audius · ${track.artist}',
                maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: track.streamUrl == null
                ? null
                : IconButton(
                    icon: Icon(
                      widget.player.playingId == track.platformTrackId
                          ? Icons.pause
                          : Icons.play_arrow,
                    ),
                    onPressed: () async {
                      await widget.player.toggle(
                          track.platformTrackId!, track.streamUrl!);
                      if (mounted) setState(() {});
                      widget.onRefresh();
                    },
                  ),
          ),
      ],
    );
  }
}

class _ErrorRow extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorRow({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(message,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.error)),
        ),
        TextButton(onPressed: onRetry, child: const Text('Retry')),
      ],
    );
  }
}


// -- Jamendo tab ------------------------------------------------------------
// Creative Commons catalog: track search, playlist import (with a
// "Get recommendations" run, same as Audius), and curated radios.
// Same separation as Audius: nothing here feeds core scoring.

class _JamendoTab extends ConsumerStatefulWidget {
  const _JamendoTab();

  @override
  ConsumerState<_JamendoTab> createState() => _JamendoTabState();
}

class _JamendoTabState extends ConsumerState<_JamendoTab> {
  final _searchController = TextEditingController();
  final _playlistController = TextEditingController();
  String _search = '';
  String? _playlistId;
  final _player = _TabPlayer();

  @override
  void dispose() {
    _searchController.dispose();
    _playlistController.dispose();
    _player.dispose();
    super.dispose();
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  void _getRecommendations(PlaylistInfo info, List<Track> tracks) {
    if (tracks.length < minUsableTracks) {
      _snack('Need at least $minUsableTracks tracks — '
          'this playlist has ${tracks.length}.');
      return;
    }
    ref.read(generationProvider.notifier).reset();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => GeneratingScreen(
          args: GenerationArgs(
            surprise: false,
            seedName: info.name,
            seedPlaylistId: info.id,
            seedPlatformId: 'jamendo',
            tracks: tracks,
            settings: const DiscoverySettings(
              songCount: defaultSongCount,
              albumCount: defaultAlbumCount,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final clientId = ref.watch(jamendoClientIdProvider);
    final configured =
        clientId.isNotEmpty && !clientId.startsWith('YOUR_');
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (!configured)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                'Jamendo needs a free client_id before this tab can load: '
                'register an app at devportal.jamendo.com and put its '
                'client_id in jamendoClientId (lib/core/constants.dart). '
                'Until then, everything below shows this hint instead of '
                'failing calls.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
        if (!configured) const SizedBox(height: 16),
        Text(
          'Jamendo is Creative Commons music — free to stream in full '
          'here, inside this tab only. Jamendo tracks never mix into '
          'your main recommendations.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        Text('Search tracks',
            style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _searchController,
                decoration: const InputDecoration(
                  hintText: 'Search Jamendo tracks…',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) =>
                    setState(() => _search = _searchController.text.trim()),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: () =>
                  setState(() => _search = _searchController.text.trim()),
              child: const Text('Search'),
            ),
          ],
        ),
        if (_search.isNotEmpty) ...[
          const SizedBox(height: 8),
          _JamendoSearchResults(
            query: _search,
            player: _player,
            onRefresh: () => setState(() {}),
          ),
        ],
        const SizedBox(height: 24),
        Text('Import a Jamendo playlist',
            style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _playlistController,
                decoration: const InputDecoration(
                  hintText: 'jamendo.com/playlist/… or playlist id',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.url,
                onSubmitted: (_) => setState(
                    () => _playlistId = _playlistController.text.trim()),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: () => setState(
                  () => _playlistId = _playlistController.text.trim()),
              child: const Text('Import'),
            ),
          ],
        ),
        if (_playlistId != null && _playlistId!.isNotEmpty) ...[
          const SizedBox(height: 8),
          _JamendoPlaylistView(
            playlistId: _playlistId!,
            player: _player,
            onRecommendations: _getRecommendations,
            onRefresh: () => setState(() {}),
          ),
        ],
        const SizedBox(height: 24),
        Text('Radios', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        _JamendoRadiosView(
          player: _player,
          onRefresh: () => setState(() {}),
        ),
      ],
    );
  }
}

/// Search results for the Jamendo tab (track list with in-tab playback).
class _JamendoSearchResults extends ConsumerWidget {
  final String query;
  final _TabPlayer player;
  final VoidCallback onRefresh;

  const _JamendoSearchResults({
    required this.query,
    required this.player,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final results = ref.watch(jamendoSearchProvider(query));
    return results.when(
      data: (load) => _JamendoTrackList(
        load: load,
        player: player,
        onRetry: () => ref.invalidate(jamendoSearchProvider(query)),
        onRefresh: onRefresh,
      ),
      loading: () => const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => _ErrorRow(
        message: 'Jamendo search failed.',
        onRetry: () => ref.invalidate(jamendoSearchProvider(query)),
      ),
    );
  }
}

/// Jamendo track list: same shape as the Audius list, but labelled
/// "From Jamendo" so the source is never ambiguous.
class _JamendoTrackList extends StatefulWidget {
  final DiscoverLoad<Track> load;
  final _TabPlayer player;
  final VoidCallback onRetry;
  final VoidCallback onRefresh;

  const _JamendoTrackList({
    required this.load,
    required this.player,
    required this.onRetry,
    required this.onRefresh,
  });

  @override
  State<_JamendoTrackList> createState() => _JamendoTrackListState();
}

class _JamendoTrackListState extends State<_JamendoTrackList> {
  @override
  Widget build(BuildContext context) {
    if (widget.load.error != null) {
      return _ErrorRow(
          message: widget.load.error!, onRetry: widget.onRetry);
    }
    if (widget.load.items.isEmpty) {
      return Text(
        'Nothing here yet.',
        style: Theme.of(context).textTheme.bodySmall,
      );
    }
    return Column(
      children: [
        for (final track in widget.load.items)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: track.imageUrl != null
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.network(track.imageUrl!,
                        width: 48, height: 48, fit: BoxFit.cover),
                  )
                : const Icon(Icons.audiotrack, size: 40),
            title: Text(track.title,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text('From Jamendo · ${track.artist}',
                maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: track.streamUrl == null
                ? null
                : IconButton(
                    icon: Icon(
                      widget.player.playingId == track.platformTrackId
                          ? Icons.pause
                          : Icons.play_arrow,
                    ),
                    onPressed: () async {
                      await widget.player.toggle(
                          track.platformTrackId!, track.streamUrl!);
                      if (mounted) setState(() {});
                      widget.onRefresh();
                    },
                  ),
          ),
      ],
    );
  }
}

/// An imported Jamendo playlist: track list + "Get recommendations".
class _JamendoPlaylistView extends ConsumerWidget {
  final String playlistId;
  final _TabPlayer player;
  final void Function(PlaylistInfo, List<Track>) onRecommendations;
  final VoidCallback onRefresh;

  const _JamendoPlaylistView({
    required this.playlistId,
    required this.player,
    required this.onRecommendations,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final resolved = JamendoClient.parsePlaylistLink(playlistId);
    if (resolved == null) {
      return const Text(
        'That doesn\'t look like a Jamendo playlist link or id — '
        'a Jamendo playlist link contains /playlist/<number>.',
        style: TextStyle(fontStyle: FontStyle.italic),
      );
    }
    final load = ref.watch(jamendoPlaylistProvider(resolved));
    return load.when(
      data: (data) {
        if (data.error != null) {
          return _ErrorRow(
            message: data.error!,
            onRetry: () =>
                ref.invalidate(jamendoPlaylistProvider(resolved)),
          );
        }
        final info = data.info!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.queue_music, size: 40),
              title: Text(info.name),
              subtitle: Text(
                  '${info.owner ?? 'Jamendo'} · ${data.tracks.length} tracks'),
            ),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => onRecommendations(info, data.tracks),
                child: const Text('Get recommendations'),
              ),
            ),
            const SizedBox(height: 8),
            _JamendoTrackList(
              load: DiscoverLoad(items: data.tracks),
              player: player,
              onRetry: () =>
                  ref.invalidate(jamendoPlaylistProvider(resolved)),
              onRefresh: onRefresh,
            ),
          ],
        );
      },
      loading: () => const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => _ErrorRow(
        message: 'Couldn\'t import that Jamendo playlist.',
        onRetry: () => ref.invalidate(jamendoPlaylistProvider(resolved)),
      ),
    );
  }
}

/// Curated Jamendo radios. Playback is best-effort: when the radios/stream
/// endpoint returns no stream URL, the row explains instead of failing.
class _JamendoRadiosView extends ConsumerStatefulWidget {
  final _TabPlayer player;
  final VoidCallback onRefresh;

  const _JamendoRadiosView({
    required this.player,
    required this.onRefresh,
  });

  @override
  ConsumerState<_JamendoRadiosView> createState() =>
      _JamendoRadiosViewState();
}

class _JamendoRadiosViewState extends ConsumerState<_JamendoRadiosView> {
  @override
  Widget build(BuildContext context) {
    final radios = ref.watch(jamendoRadiosProvider);
    return radios.when(
      data: (load) {
        if (load.error != null) {
          return _ErrorRow(
              message: load.error!,
              onRetry: () => ref.invalidate(jamendoRadiosProvider));
        }
        if (load.items.isEmpty) {
          return Text(
            'No radios here yet.',
            style: Theme.of(context).textTheme.bodySmall,
          );
        }
        return Column(
          children: [
            for (final radio in load.items)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: radio.imageUrl != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: Image.network(radio.imageUrl!,
                            width: 48, height: 48, fit: BoxFit.cover),
                      )
                    : const Icon(Icons.radio, size: 40),
                title: Text(radio.name,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: const Text('From Jamendo · radio'),
                trailing: IconButton(
                  icon: Icon(
                    widget.player.playingId == 'radio:${radio.id}'
                        ? Icons.pause
                        : Icons.play_arrow,
                  ),
                  onPressed: () async {
                    final stream = await ref
                        .read(jamendoClientProvider)
                        .radioStreamUrl(radio.id);
                    if (stream == null) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                                'This radio has no in-app stream — '
                                'listen to it on jamendo.com.'),
                          ),
                        );
                      }
                      return;
                    }
                    await widget.player
                        .toggle('radio:${radio.id}', stream);
                    if (mounted) setState(() {});
                    widget.onRefresh();
                  },
                ),
              ),
          ],
        );
      },
      loading: () => const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => _ErrorRow(
        message: 'Couldn\'t load Jamendo radios.',
        onRetry: () => ref.invalidate(jamendoRadiosProvider),
      ),
    );
  }
}
