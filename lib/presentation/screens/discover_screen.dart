// Discover tab (Phase 4): one tab per new source, each kept separate from
// core recommendations. Audius tracks play in full inside this tab only;
// nothing here is merged into the main Last.fm recommendation pool.

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../data/discover/audius_client.dart';
import '../../data/discover/jamendo_client.dart';
import '../../data/discover/mixcloud_client.dart';
import '../../data/discover/openwhyd_client.dart';
import '../../data/platforms/open_in_app.dart';
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
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Discover'),
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.audiotrack), text: 'Audius'),
              Tab(icon: Icon(Icons.library_music), text: 'Jamendo'),
              Tab(icon: Icon(Icons.people), text: 'Openwhyd'),
              Tab(icon: Icon(Icons.radio), text: 'Mixcloud'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            _AudiusTab(),
            _JamendoTab(),
            _OpenwhydTab(),
            _MixcloudTab(),
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
            sourceLabel: 'From Audius',
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
          _DiscoverSearchResults(
            searchProvider: audiusSearchProvider,
            query: _search,
            sourceLabel: 'From Audius',
            errorMessage: 'Audius search failed.',
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
          _DiscoverPlaylistView(
            playlistId: _playlistId!,
            playlistProvider: audiusPlaylistProvider,
            parseLink: AudiusClient.parsePlaylistLink,
            hint: 'That doesn\'t look like an Audius playlist link or id — '
                'an Audius playlist link ends in a number, e.g. '
                'audius.co/user/playlist/name-123456.',
            fallbackOwner: 'Audius',
            showCover: true,
            sourceLabel: 'From Audius',
            importErrorMessage: 'Couldn\'t import that Audius playlist.',
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
/// Search results for a streamable Discover source (Audius/Jamendo):
/// track list with in-tab playback, labelled with [sourceLabel] so the
/// source is never ambiguous.
class _DiscoverSearchResults extends ConsumerWidget {
  final FutureProviderFamily<DiscoverLoad<Track>, String> searchProvider;
  final String query;
  final String sourceLabel;
  final String errorMessage;
  final _TabPlayer player;
  final VoidCallback onRefresh;

  const _DiscoverSearchResults({
    required this.searchProvider,
    required this.query,
    required this.sourceLabel,
    required this.errorMessage,
    required this.player,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final results = ref.watch(searchProvider(query));
    return results.when(
      data: (load) => _TrackList(
        load: load,
        sourceLabel: sourceLabel,
        player: player,
        onRetry: () => ref.invalidate(searchProvider(query)),
        onRefresh: onRefresh,
      ),
      loading: () => const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => _ErrorRow(
        message: errorMessage,
        onRetry: () => ref.invalidate(searchProvider(query)),
      ),
    );
  }
}

/// An imported Audius playlist: track list + "Get recommendations".
/// An imported playlist for a streamable Discover source (Audius/
/// Jamendo): track list + "Get recommendations". The provider takes a
/// resolved id, so links are parsed here and a bad link shows [hint]
/// instead of a failed load.
class _DiscoverPlaylistView extends ConsumerWidget {
  final String playlistId;
  final FutureProviderFamily<PlaylistLoad, String> playlistProvider;
  final String? Function(String) parseLink;
  final String hint;
  final String fallbackOwner;
  final bool showCover;
  final String sourceLabel;
  final String importErrorMessage;
  final _TabPlayer player;
  final void Function(PlaylistInfo, List<Track>) onRecommendations;
  final VoidCallback onRefresh;

  const _DiscoverPlaylistView({
    required this.playlistId,
    required this.playlistProvider,
    required this.parseLink,
    required this.hint,
    required this.fallbackOwner,
    required this.showCover,
    required this.sourceLabel,
    required this.importErrorMessage,
    required this.player,
    required this.onRecommendations,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final resolved = parseLink(playlistId);
    if (resolved == null) {
      return Text(
        hint,
        style: const TextStyle(fontStyle: FontStyle.italic),
      );
    }
    final load = ref.watch(playlistProvider(resolved));
    return load.when(
      data: (data) {
        if (data.error != null) {
          return _ErrorRow(
            message: data.error!,
            onRetry: () => ref.invalidate(playlistProvider(resolved)),
          );
        }
        final info = data.info!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: showCover && info.coverUrl != null
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: Image.network(info.coverUrl!,
                          width: 48, height: 48, fit: BoxFit.cover),
                    )
                  : const Icon(Icons.queue_music, size: 40),
              title: Text(info.name),
              subtitle: Text(
                  '${info.owner ?? fallbackOwner} · '
                  '${data.tracks.length} tracks'),
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
              sourceLabel: sourceLabel,
              player: player,
              onRetry: () => ref.invalidate(playlistProvider(resolved)),
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
        message: importErrorMessage,
        onRetry: () => ref.invalidate(playlistProvider(resolved)),
      ),
    );
  }
}

/// Shared track list with in-tab full-stream playback. The [load] error
/// label is shown inline; an empty list with no error means "nothing
/// found", not a failure.
class _TrackList extends StatefulWidget {
  final DiscoverLoad<Track> load;
  final String sourceLabel;
  final _TabPlayer player;
  final VoidCallback onRetry;
  final VoidCallback onRefresh;

  const _TrackList({
    required this.load,
    required this.sourceLabel,
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
            subtitle: Text('${widget.sourceLabel} · ${track.artist}',
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
          _DiscoverSearchResults(
            searchProvider: jamendoSearchProvider,
            query: _search,
            sourceLabel: 'From Jamendo',
            errorMessage: 'Jamendo search failed.',
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
          _DiscoverPlaylistView(
            playlistId: _playlistId!,
            playlistProvider: jamendoPlaylistProvider,
            parseLink: JamendoClient.parsePlaylistLink,
            hint: 'That doesn\'t look like a Jamendo playlist link or id — '
                'a Jamendo playlist link contains /playlist/<number>.',
            fallbackOwner: 'Jamendo',
            showCover: false,
            sourceLabel: 'From Jamendo',
            importErrorMessage: 'Couldn\'t import that Jamendo playlist.',
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

// -- Openwhyd tab -----------------------------------------------------------
// Small-community curation: import a public playlist via the no-auth Data
// Export API. Tracks resolve back to YouTube/SoundCloud/Deezer/Vimeo, so
// each row opens its original instead of playing in-app (Openwhyd has no
// in-app stream). Same separation as the other tabs: nothing here feeds
// core scoring, but a playlist can seed a one-off recommendations run.

class _OpenwhydTab extends ConsumerStatefulWidget {
  const _OpenwhydTab();

  @override
  ConsumerState<_OpenwhydTab> createState() => _OpenwhydTabState();
}

class _OpenwhydTabState extends ConsumerState<_OpenwhydTab> {
  final _playlistController = TextEditingController();
  String? _playlistKey;

  @override
  void dispose() {
    _playlistController.dispose();
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
            seedPlatformId: 'openwhyd',
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
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Openwhyd playlists are curated lists of tracks from other '
          'platforms — each track opens on its original site. Nothing '
          'here mixes into your main recommendations.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        Text('Import a public Openwhyd playlist',
            style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _playlistController,
                decoration: const InputDecoration(
                  hintText: 'openwhyd.org/<user>/playlist/<number>',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.url,
                onSubmitted: (_) => _import(),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _import,
              child: const Text('Import'),
            ),
          ],
        ),
        if (_playlistKey != null) ...[
          const SizedBox(height: 8),
          _OpenwhydPlaylistView(
            playlistKey: _playlistKey!,
            onRecommendations: _getRecommendations,
          ),
        ],
      ],
    );
  }

  void _import() {
    final text = _playlistController.text.trim();
    if (text.isEmpty) {
      _snack('Paste an Openwhyd playlist link first.');
      return;
    }
    final parsed = OpenwhydClient.parsePlaylistLink(text);
    if (parsed == null) {
      _snack('That doesn\'t look like an Openwhyd playlist link.');
      return;
    }
    setState(() => _playlistKey = '${parsed.user}::${parsed.playlistId}');
  }
}

/// An imported Openwhyd playlist: track list + "Get recommendations".
/// Each row opens its original source-platform page.
class _OpenwhydPlaylistView extends ConsumerWidget {
  final String playlistKey;
  final void Function(PlaylistInfo, List<Track>) onRecommendations;

  const _OpenwhydPlaylistView({
    required this.playlistKey,
    required this.onRecommendations,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final load = ref.watch(openwhydPlaylistProvider(playlistKey));
    return load.when(
      data: (data) {
        if (data.error != null) {
          return _ErrorRow(
            message: data.error!,
            onRetry: () =>
                ref.invalidate(openwhydPlaylistProvider(playlistKey)),
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
                  '${info.owner ?? 'Openwhyd'} · ${data.tracks.length} tracks'),
            ),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => onRecommendations(info, data.tracks),
                child: const Text('Get recommendations'),
              ),
            ),
            const SizedBox(height: 8),
            // The export posts carry no stream URL; rows open their
            // original source-platform pages instead.
            _OpenwhydTrackList(tracks: data.tracks),
          ],
        );
      },
      loading: () => const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => _ErrorRow(
        message: 'Couldn\'t import that Openwhyd playlist.',
        onRetry: () =>
            ref.invalidate(openwhydPlaylistProvider(playlistKey)),
      ),
    );
  }
}

/// Openwhyd track rows: title/artist plus an "open original" button.
/// The eId stored on [Track.platformTrackId] is translated back to its
/// source URL with [OpenwhydClient.originalUrl].
class _OpenwhydTrackList extends StatelessWidget {
  final List<Track> tracks;

  const _OpenwhydTrackList({required this.tracks});

  @override
  Widget build(BuildContext context) {
    if (tracks.isEmpty) {
      return Text(
        'Nothing here yet.',
        style: Theme.of(context).textTheme.bodySmall,
      );
    }
    final rows = <Widget>[];
    for (final track in tracks) {
      // No button when the eId prefix is unknown: tapping a dead button
      // would be worse than showing none.
      final url = track.platformTrackId == null
          ? null
          : OpenwhydClient.originalUrl({'eId': track.platformTrackId});
      rows.add(
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
          subtitle: Text('From Openwhyd · ${track.artist}',
              maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: url == null
              ? null
              : IconButton(
                  icon: const Icon(Icons.open_in_new),
                  onPressed: () async {
                    await openLinkInAppFirst(Uri.parse(url));
                  },
                ),
        ),
      );
    }
    return Column(children: rows);
  }
}

// -- Mixcloud tab -----------------------------------------------------------
// Shows/mixes browser ONLY: popular/hot/new feeds, show search, and tag
// search. Shows open in Mixcloud (app/browser) — there is no in-app
// Mixcloud playback, and nothing here feeds the song generator at all.

class _MixcloudTab extends ConsumerStatefulWidget {
  const _MixcloudTab();

  @override
  ConsumerState<_MixcloudTab> createState() => _MixcloudTabState();
}

class _MixcloudTabState extends ConsumerState<_MixcloudTab> {
  String _feed = 'popular';
  final _showSearchController = TextEditingController();
  final _tagSearchController = TextEditingController();
  String _showQuery = '';
  String _tagQuery = '';
  String? _tagKey;
  String? _tagName;

  @override
  void dispose() {
    _showSearchController.dispose();
    _tagSearchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Mixcloud is DJ mixes, radio shows and podcasts. Shows open '
          'in Mixcloud — they never play here and never feed the song '
          'generator.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final feed in ['popular', 'hot', 'new'])
              FilterChip(
                label: Text(feed[0].toUpperCase() + feed.substring(1)),
                selected: _feed == feed && _tagKey == null,
                onSelected: (v) {
                  if (!v) return;
                  setState(() {
                    _feed = feed;
                    _tagKey = null;
                    _tagName = null;
                    _showQuery = '';
                    _showSearchController.clear();
                  });
                },
              ),
          ],
        ),
        const SizedBox(height: 16),
        Text('Search shows',
            style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _showSearchController,
                decoration: const InputDecoration(
                  hintText: 'Search Mixcloud shows…',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => setState(() {
                  _showQuery = _showSearchController.text.trim();
                  _tagKey = null;
                  _tagName = null;
                }),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: () => setState(() {
                _showQuery = _showSearchController.text.trim();
                _tagKey = null;
                _tagName = null;
              }),
              child: const Text('Search'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text('Search tags',
            style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _tagSearchController,
                decoration: const InputDecoration(
                  hintText: 'e.g. funk, jazz, ambient…',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => setState(
                    () => _tagQuery = _tagSearchController.text.trim()),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: () => setState(
                  () => _tagQuery = _tagSearchController.text.trim()),
              child: const Text('Search'),
            ),
          ],
        ),
        if (_tagQuery.isNotEmpty) ...[
          const SizedBox(height: 8),
          _MixcloudTagResults(
            query: _tagQuery,
            onPick: (tag) => setState(() {
              _tagKey = tag.key;
              _tagName = tag.name;
              _showQuery = '';
              _showSearchController.clear();
            }),
          ),
        ],
        const SizedBox(height: 16),
        if (_tagKey != null)
          Row(
            children: [
              Expanded(
                child: Text('Shows tagged "$_tagName"',
                    style: Theme.of(context).textTheme.titleSmall),
              ),
              TextButton(
                onPressed: () => setState(() {
                  _tagKey = null;
                  _tagName = null;
                }),
                child: const Text('Clear'),
              ),
            ],
          )
        else if (_showQuery.isNotEmpty)
          Text('Results for "$_showQuery"',
              style: Theme.of(context).textTheme.titleSmall)
        else
          Text(
              _feed[0].toUpperCase() + _feed.substring(1) + ' shows',
              style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        _MixcloudShowSection(
          feed: _feed,
          showQuery: _showQuery,
          tagKey: _tagKey,
        ),
      ],
    );
  }
}

/// Watches exactly one show provider for the current view (tag shows,
/// show search, or the selected feed) and renders its list or error.
class _MixcloudShowSection extends ConsumerWidget {
  final String feed;
  final String showQuery;
  final String? tagKey;

  const _MixcloudShowSection({
    required this.feed,
    required this.showQuery,
    required this.tagKey,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<DiscoverLoad<MixcloudShow>> shows;
    final VoidCallback onRetry;
    if (tagKey != null) {
      shows = ref.watch(mixcloudTagShowsProvider(tagKey!));
      onRetry = () => ref.invalidate(mixcloudTagShowsProvider(tagKey!));
    } else if (showQuery.isNotEmpty) {
      shows = ref.watch(mixcloudSearchProvider(showQuery));
      onRetry = () => ref.invalidate(mixcloudSearchProvider(showQuery));
    } else {
      shows = ref.watch(mixcloudFeedProvider(feed));
      onRetry = () => ref.invalidate(mixcloudFeedProvider(feed));
    }
    return shows.when(
      data: (load) => _MixcloudShowList(load: load, onRetry: onRetry),
      loading: () => const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => _ErrorRow(
        message: 'Couldn\'t load Mixcloud shows.',
        onRetry: onRetry,
      ),
    );
  }
}

/// Pure show list renderer: artwork, name, user + length, open button.
class _MixcloudShowList extends StatelessWidget {
  final DiscoverLoad<MixcloudShow> load;
  final VoidCallback onRetry;

  const _MixcloudShowList({required this.load, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    if (load.error != null) {
      return _ErrorRow(message: load.error!, onRetry: onRetry);
    }
    if (load.items.isEmpty) {
      return Text(
        'Nothing here yet.',
        style: Theme.of(context).textTheme.bodySmall,
      );
    }
    return Column(
      children: [
        for (final show in load.items)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: show.imageUrl != null
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.network(show.imageUrl!,
                        width: 48, height: 48, fit: BoxFit.cover),
                  )
                : const Icon(Icons.radio, size: 40),
            title: Text(show.name,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              [
                if (show.userName != null) show.userName!,
                if (show.audioLengthSec != null)
                  MixcloudClient.formatLength(show.audioLengthSec!),
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: show.url.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.open_in_new),
                    onPressed: () async {
                      await openLinkInAppFirst(Uri.parse(show.url));
                    },
                  ),
          ),
      ],
    );
  }
}

/// Tag search results as chips; tapping one shows that tag's shows.
class _MixcloudTagResults extends ConsumerWidget {
  final String query;
  final void Function(MixcloudTag) onPick;

  const _MixcloudTagResults({required this.query, required this.onPick});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tags = ref.watch(mixcloudTagSearchProvider(query));
    return tags.when(
      data: (load) {
        if (load.error != null) {
          return _ErrorRow(
            message: load.error!,
            onRetry: () =>
                ref.invalidate(mixcloudTagSearchProvider(query)),
          );
        }
        if (load.items.isEmpty) {
          return Text(
            'No tags found.',
            style: Theme.of(context).textTheme.bodySmall,
          );
        }
        return Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final tag in load.items)
              ActionChip(
                label: Text(tag.name),
                onPressed: () => onPick(tag),
              ),
          ],
        );
      },
      loading: () => const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => _ErrorRow(
        message: 'Mixcloud tag search failed.',
        onRetry: () => ref.invalidate(mixcloudTagSearchProvider(query)),
      ),
    );
  }
}
