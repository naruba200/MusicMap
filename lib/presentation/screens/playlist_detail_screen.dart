// Playlist detail (S-03): cover + meta, virtualized track list (500+ safe),
// count presets, discovery modifier chips, Fresh finds toggle, Rescan,
// and the "Get recommendations" CTA (M2 engine).

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/constants.dart';
import '../../core/time_ago.dart';
import '../../data/engine/recommendation_engine.dart';
import '../../data/export/youtube_export.dart';
import '../../data/models/music_models.dart';
import '../../data/platforms/music_platform.dart';
import '../providers/generation_provider.dart';
import '../providers/providers.dart';
import '../widgets/favorite_button.dart';
import '../widgets/preview_button.dart';
import '../widgets/spotify_youtube_review.dart';
import '../widgets/youtube_export_sheet.dart';
import 'generating_screen.dart';

class PlaylistDetailScreen extends ConsumerStatefulWidget {
  final String platformId;
  final String playlistId;

  const PlaylistDetailScreen({
    super.key,
    required this.platformId,
    required this.playlistId,
  });

  @override
  ConsumerState<PlaylistDetailScreen> createState() =>
      _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState
    extends ConsumerState<PlaylistDetailScreen> {
  int _songCount = defaultSongCount;
  int _albumCount = defaultAlbumCount;
  final Set<String> _moods = {};
  final Set<String> _genres = {};
  bool _freshFinds = false;
  bool _showAllGenres = false;
  String? _lastGenre;
  bool _initialized = false;
  bool _rescanning = false;
  bool _retrying = false;

  /// YouTube-match review state (Spotify only, push 3): the finished
  /// resolution, plus the matched tracks as normalized keys for the
  /// per-row marks. Kept (not re-resolved) so push 4's Save to YouTube
  /// reuses the same resolution.
  ExportResolution? _youTubeResolution;
  Set<String> _youTubeMatchedKeys = const {};

  String get _detailKey => '${widget.platformId}::${widget.playlistId}';

  bool _isYouTubeMatched(Track track) => _youTubeMatchedKeys.contains(
      RecommendationEngine.normalizeKey(track.artist, track.title));

  void _snack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// Seeds the local control state from the saved playlist (or app defaults)
  /// exactly once, then auto-saves the imported playlist.
  void _initFromData(PlaylistDetailData data) {
    if (_initialized) return;
    _initialized = true;
    final repo = ref.read(playlistRepositoryProvider);
    final existing =
        repo.get(widget.platformId, widget.playlistId);
    final settingsRepo = ref.read(settingsRepositoryProvider);
    if (existing != null) {
      _songCount = existing.settings.songCount;
      _albumCount = existing.settings.albumCount;
      _moods.addAll(existing.settings.moods);
      _genres.addAll(existing.settings.genres);
      _freshFinds = existing.settings.freshFinds;
      if (_genres.isNotEmpty) _lastGenre = _genres.last;
    } else {
      _songCount = settingsRepo.songCount;
      _albumCount = settingsRepo.albumCount;
    }
    // Auto-save the import (FR-15), preserving any existing settings.
    ref.read(savedPlaylistsProvider.notifier).save(
          existing ??
              SavedPlaylist(
                info: data.info,
                tracks: data.tracks,
                settings: DiscoverySettings(
                  songCount: _songCount,
                  albumCount: _albumCount,
                ),
                importedAt: DateTime.now(),
                lastScannedAt: DateTime.now(),
              ),
        );
  }

  Future<void> _persistSettings() async {
    await ref.read(savedPlaylistsProvider.notifier).updateSettings(
          widget.platformId,
          widget.playlistId,
          DiscoverySettings(
            songCount: _songCount,
            albumCount: _albumCount,
            moods: Set.of(_moods),
            genres: Set.of(_genres),
            freshFinds: _freshFinds,
          ),
        );
  }

  Future<void> _rescan(MusicPlatform platform) async {
    setState(() => _rescanning = true);
    try {
      final saved = ref
          .read(playlistRepositoryProvider)
          .get(widget.platformId, widget.playlistId);
      if (saved == null) return;
      final newCount = await ref
          .read(savedPlaylistsProvider.notifier)
          .rescan(platform, saved);
      ref.invalidate(playlistDetailProvider(_detailKey));
      if (mounted) {
        _snack(newCount == 0
            ? 'Already up to date.'
            : '$newCount new track${newCount == 1 ? '' : 's'} found.');
      }
    } on PlatformException catch (e) {
      _snack(e.message);
    } finally {
      if (mounted) setState(() => _rescanning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final detail = ref.watch(playlistDetailProvider(_detailKey));

    return Scaffold(
      appBar: AppBar(title: const Text('Playlist')),
      body: detail.when(
        data: (data) {
          _initFromData(data);
          return _buildContent(context, data);
        },
        loading: () =>
            const Center(child: CircularProgressIndicator()),
        error: (e, _) => _buildError(context, e),
      ),
    );
  }

  Widget _buildError(BuildContext context, Object e) {
    final platform =
        ref.read(platformRegistryProvider).byId(widget.platformId);
    final message =
        e is PlatformException ? e.message : 'Could not load playlist: $e';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined,
                size: 48,
                color: Theme.of(context).colorScheme.error),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            if (platform.isBeta) ...[
              const SizedBox(height: 8),
              Text(
                '${platform.displayName} is experimental (β) — '
                'if this keeps failing, try Deezer instead.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 16),
            if (_retrying) ...[
              const SizedBox(
                height: 56,
                child: Center(child: CircularProgressIndicator(strokeWidth: 3)),
              ),
              const SizedBox(height: 8),
              Text('Retrying…', style: Theme.of(context).textTheme.bodySmall),
            ] else
              FilledButton.tonal(
                onPressed: () async {
                  setState(() => _retrying = true);
                  ref.invalidate(playlistDetailProvider(_detailKey));
                  if (mounted) setState(() => _retrying = false);
                },
                child: const Text('Retry'),
              ),
            TextButton(
              onPressed: () => platform.openPlaylist(widget.playlistId),
              child: Text('Open in ${platform.displayName} instead'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context, PlaylistDetailData data) {
    final tracks = data.tracks;
    // Index 0 = header; the rest virtualize the track list.
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: tracks.length + 1,
      itemBuilder: (context, i) {
        if (i == 0) return _buildHeader(context, data);
        final t = tracks[i - 1];
        return ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: t.imageUrl != null
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Image.network(t.imageUrl!,
                      width: 40, height: 40, fit: BoxFit.cover),
                )
              : const Icon(Icons.music_note),
          title: Text(t.title,
              maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(t.artist,
              maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // YouTube-match mark (Spotify review, push 3): shown
              // once the review has run for this playlist.
              if (_youTubeResolution != null)
                Icon(
                  _isYouTubeMatched(t)
                      ? Icons.check_circle
                      : Icons.close,
                  size: 18,
                  color: _isYouTubeMatched(t)
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              FavoriteButton(track: t),
              PreviewButton(track: t),
            ],
          ),
        );
      },
    );
  }

  Widget _buildHeader(BuildContext context, PlaylistDetailData data) {
    final theme = Theme.of(context);
    final info = data.info;
    final platform = data.platform;
    // Spotify skips unreadable items (restricted/removed tracks): say
    // how many of the playlist's total were readable instead of
    // presenting the partial list as complete. Other platforms only
    // show this when their import comes up short too.
    final readableLabel = readableCountLabel(
      total: info.trackCount,
      readable: data.tracks.length,
      platformName: platform.displayName,
    );
    final saved = ref
        .watch(savedPlaylistsProvider)
        .where((s) =>
            s.info.platformId == widget.platformId &&
            s.info.id == widget.playlistId)
        .firstOrNull;

    final visibleGenres = _showAllGenres
        ? genreChips
        : genreChips.take(visibleGenreCount).toList();
    // Related genres: live via Last.fm tag.getSimilar, static fallback map
    // on failure (spec FR-04e, wired live in M2).
    final relatedAsync = _lastGenre != null
        ? ref.watch(relatedGenresProvider(_lastGenre!))
        : const AsyncValue<List<String>>.data(<String>[]);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: info.coverUrl != null
                  ? Image.network(info.coverUrl!,
                      width: 96, height: 96, fit: BoxFit.cover)
                  : Container(
                      width: 96,
                      height: 96,
                      color: theme.colorScheme.surfaceContainerHighest,
                      child: const Icon(Icons.queue_music, size: 40),
                    ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(info.name,
                      style: theme.textTheme.titleLarge,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 6,
                    children: [
                      _badge(context, platform.displayName),
                      if (platform.isBeta) _badge(context, 'β'),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${info.owner ?? 'Unknown owner'} · '
                    '${data.tracks.length} tracks'
                    '${saved != null ? ' · scanned ${timeAgo(saved.lastScannedAt)}' : ''}',
                    style: theme.textTheme.bodySmall,
                  ),
                  if (readableLabel != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        readableLabel,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  // Phase 4a: the import stopped early (e.g. YouTube
                  // Music's 100-track shelf cap with a dead-end
                  // continuation). Say so plainly instead of presenting
                  // a partial list as the whole playlist.
                  if (data.truncated)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.warning_amber,
                              size: 16,
                              color: theme.colorScheme.tertiary),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              'Only the first 100 tracks loaded — '
                              'YouTube Music cut the list short. '
                              'Reopen this playlist to retry the '
                              'full import.',
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (saved != null)
          OutlinedButton.icon(
            onPressed: _rescanning ? null : () => _rescan(platform),
            icon: _rescanning
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh),
            label: const Text('Rescan'),
          ),
        const SizedBox(height: 8),

        // Count presets (FR-04d).
        Text('Songs', style: theme.textTheme.titleSmall),
        Wrap(
          spacing: 8,
          children: [
            for (final n in songCountPresets)
              ChoiceChip(
                label: Text('$n'),
                selected: _songCount == n,
                onSelected: (_) {
                  setState(() => _songCount = n);
                  ref
                      .read(settingsRepositoryProvider)
                      .setDefaultSongCount(n);
                  _persistSettings();
                },
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text('Albums', style: theme.textTheme.titleSmall),
        Wrap(
          spacing: 8,
          children: [
            for (final n in albumCountPresets)
              ChoiceChip(
                label: Text('$n'),
                selected: _albumCount == n,
                onSelected: (_) {
                  setState(() => _albumCount = n);
                  ref
                      .read(settingsRepositoryProvider)
                      .setDefaultAlbumCount(n);
                  _persistSettings();
                },
              ),
          ],
        ),
        const SizedBox(height: 12),

        // Discovery modifiers (FR-04e).
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Discovery filters', style: theme.textTheme.titleSmall),
            Row(
              children: [
                const Text('Fresh finds'),
                Switch(
                  value: _freshFinds,
                  onChanged: (v) {
                    setState(() => _freshFinds = v);
                    _persistSettings();
                  },
                ),
              ],
            ),
          ],
        ),
        Text('Moods', style: theme.textTheme.labelMedium),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final mood in moodChips)
              FilterChip(
                label: Text(mood),
                selected: _moods.contains(mood),
                onSelected: (v) {
                  setState(() {
                    v ? _moods.add(mood) : _moods.remove(mood);
                  });
                  _persistSettings();
                },
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text('Genres', style: theme.textTheme.labelMedium),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final genre in visibleGenres)
              FilterChip(
                label: Text(genre),
                selected: _genres.contains(genre),
                onSelected: (v) {
                  setState(() {
                    if (v) {
                      _genres.add(genre);
                      _lastGenre = genre;
                    } else {
                      _genres.remove(genre);
                    }
                  });
                  _persistSettings();
                },
              ),
            ActionChip(
              label: Text(_showAllGenres ? 'Show less' : 'Show more'),
              onPressed: () =>
                  setState(() => _showAllGenres = !_showAllGenres),
            ),
          ],
        ),
        relatedAsync.when(
          data: (related) {
            if (related.isEmpty) return const SizedBox.shrink();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 4),
                Text('Related',
                    style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.secondary)),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final genre in related)
                      FilterChip(
                        label: Text(genre),
                        selected: _genres.contains(genre),
                        side: BorderSide(
                            color: theme.colorScheme.secondary
                                .withValues(alpha: 0.5)),
                        onSelected: (v) {
                          setState(() {
                            if (v) {
                              _genres.add(genre);
                              _lastGenre = genre;
                            } else {
                              _genres.remove(genre);
                            }
                          });
                          _persistSettings();
                        },
                      ),
                  ],
                ),
              ],
            );
          },
          loading: () => const SizedBox.shrink(),
          error: (_, __) => const SizedBox.shrink(),
        ),
        const SizedBox(height: 16),

        // CTA.
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: data.tracks.length < minUsableTracks
                ? () => _snack(
                    'Need at least $minUsableTracks tracks — this playlist has ${data.tracks.length}.')
                : () {
                    final settings = DiscoverySettings(
                      songCount: _songCount,
                      albumCount: _albumCount,
                      moods: Set.of(_moods),
                      genres: Set.of(_genres),
                      freshFinds: _freshFinds,
                    );
                    _persistSettings();
                    ref.read(generationProvider.notifier).reset();
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => GeneratingScreen(
                          args: GenerationArgs(
                            surprise: false,
                            seedName: data.info.name,
                            seedPlaylistId: widget.playlistId,
                            seedPlatformId: widget.platformId,
                            tracks: data.tracks,
                            settings: settings,
                          ),
                        ),
                      ),
                    );
                  },
            child: const Text('Get recommendations'),
          ),
        ),
        const SizedBox(height: 8),

        // Spotify import review (push 3): resolve the imported tracks
        // to YouTube and mark each row matched/unmatched.
        if (platform.id == PlatformIds.spotify) ...[
          SpotifyYouTubeReview(
            tracks: data.tracks,
            onResolved: (resolution) => setState(() {
              _youTubeResolution = resolution;
              _youTubeMatchedKeys = {
                for (final s in resolution.songs)
                  if (s.matched)
                    RecommendationEngine.normalizeKey(
                        s.track.artist, s.track.title),
              };
            }),
          ),
          // Save to YouTube (push 4): reuses the review's resolution —
          // no second resolve. Only when something matched.
          if (canSaveToYouTube(_youTubeResolution)) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => showYouTubeExportResultSheet(
                    context, _youTubeResolution!),
                icon: const Icon(Icons.open_in_new),
                label: const Text('Save to YouTube'),
              ),
            ),
          ],
          const SizedBox(height: 8),
        ],
        Text('Tracks (${data.tracks.length})',
            style: theme.textTheme.titleSmall),
      ],
    );
  }

  Widget _badge(BuildContext context, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        color: Theme.of(context).colorScheme.secondaryContainer,
      ),
      child: Text(label,
          style: Theme.of(context).textTheme.labelSmall),
    );
  }
}
