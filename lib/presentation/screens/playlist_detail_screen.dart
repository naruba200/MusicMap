// Playlist detail (S-03): a liner-notes sheet. Large cover left,
// name, platform badge, owner, track count, the track list as a
// numbered tracklist, count presets and modifier chips, Fresh finds
// toggle, Rescan, and the big "Get recommendations" button in the
// theme accent (disabled below 5 usable tracks, with the guidance
// line). Tap a track plays it at once (no double-tap window); the
// heart likes without playing; overflow opens the track elsewhere.
// In Complex the settings split into two columns and each track
// shows its duration (plus its YouTube match, once reviewed).

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/appearance.dart';
import '../../core/constants.dart';
import '../../core/time_ago.dart';
import '../../data/engine/recommendation_engine.dart';
import '../../data/export/youtube_export.dart';
import '../../data/models/music_models.dart';
import '../../data/platforms/music_platform.dart';
import '../providers/generation_provider.dart';
import '../providers/providers.dart';
import '../widgets/editorial_route.dart';
import '../widgets/editorial_widgets.dart';
import '../widgets/song_actions_sheet.dart';
import '../widgets/song_row.dart';
import '../widgets/spotify_youtube_review.dart';
import '../widgets/swipe_action_row.dart';
import '../widgets/undo_snackbar.dart';
import '../widgets/youtube_export_sheet.dart';
import 'generating_screen.dart';

bool _isComplex(BuildContext context) =>
    Theme.of(context).extension<MusicManDesignTokens>()?.design ==
    AppDesign.complex;

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

  /// YouTube-match review state (Spotify only, push 3): the finished
  /// resolution, plus the matched tracks as normalized keys for the
  /// per-row marks. Kept (not re-resolved) so push 4's Save to YouTube
  /// reuses the same resolution.
  ExportResolution? _youTubeResolution;
  Set<String> _youTubeMatchedKeys = const {};

  /// Rows the user removed with the swipe Remove action, by
  /// normalized artist+title. The track list here is the live
  /// platform fetch, so hiding the row is local; the removal
  /// itself lands in the saved playlist (see [_removeTrack]).
  final _dismissedKeys = <String>{};

  /// Swipe Remove on a playlist row: take the track out of the
  /// saved playlist and hide the row, with an Undo toast that
  /// puts it back where it was (its original position in the
  /// saved list, not appended at the end).
  Future<void> _removeTrack(
      PlaylistDetailData data, Track track) async {
    final key =
        RecommendationEngine.normalizeKey(track.artist, track.title);
    // The original position in the SAVED list, captured before the
    // removal: the displayed list is the live platform fetch, so
    // its index is not necessarily the saved one.
    final savedIndex = ref
            .read(playlistRepositoryProvider)
            .get(widget.platformId, widget.playlistId)
            ?.tracks
            .indexWhere((t) =>
                RecommendationEngine.normalizeKey(t.artist, t.title) ==
                key) ??
        -1;
    final removed = await ref
        .read(savedPlaylistsProvider.notifier)
        .removeTrack(widget.platformId, widget.playlistId, track);
    if (!mounted) return;
    setState(() => _dismissedKeys.add(key));
    showUndoSnackBar(
      context,
      message: removed
          ? 'Removed ${track.title} from ${data.info.name}'
          : 'Removed ${track.title} from this view',
      onUndo: () async {
        if (removed) {
          // Back where it was; a track the saved list never held
          // (live-only) falls back to appending at the end.
          if (savedIndex >= 0) {
            await ref
                .read(savedPlaylistsProvider.notifier)
                .insertTrackAt(
                    widget.platformId, widget.playlistId, track, savedIndex);
          } else {
            await ref
                .read(playlistRepositoryProvider)
                .addTrack(widget.platformId, widget.playlistId, track);
            // The direct repo write bypasses the notifier, so
            // re-read the saved lists.
            ref.invalidate(savedPlaylistsProvider);
          }
        }
        if (mounted) setState(() => _dismissedKeys.remove(key));
      },
    );
  }

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
        loading: () => const Center(
          child: EditorialLoadingState(
              message: 'Loading your playlist'),
        ),
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
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            EditorialErrorState(
              message: message,
              onRetry: () =>
                  ref.invalidate(playlistDetailProvider(_detailKey)),
            ),
            if (platform.isBeta) ...[
              const SizedBox(height: 8),
              Text(
                '${platform.displayName} is experimental (β). '
                'If this keeps failing, try Deezer instead.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
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
    final tracks = data.tracks
        .where((t) => !_dismissedKeys.contains(
            RecommendationEngine.normalizeKey(t.artist, t.title)))
        .toList();
    final isComplex = _isComplex(context);
    // Index 0 = header; the rest virtualize the track list.
    // Tapping anywhere in the list closes an open swipe row.
    return GestureDetector(
      onTap: SwipeActionRow.closeAnyOpen,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 16),
        itemCount: tracks.length + 1,
        itemBuilder: (context, i) {
          if (i == 0) return _buildHeader(context, data, isComplex);
          final t = tracks[i - 1];
          return EditorialSongRow(
            key: ValueKey('playlist-track-${i - 1}'),
            track: t,
            queue: tracks,
            rank: i,
            doubleTapToLike: false,
            meta: _rowMeta(t, isComplex),
            trailingMark: _youTubeMark(t),
            onOverflow: () => showSongActionsSheet(context, t),
            swipeActionsEnabled: true,
            onRemove: () => _removeTrack(data, t),
          );
        },
      ),
    );
  }

  /// Complex-only row metadata: the track duration, plus its YouTube
  /// match once the Spotify review has run. The match also has a
  /// per-row mark in both designs (see [_youTubeMark]); the text
  /// here is the Complex-only wording of the same state.
  String? _rowMeta(Track track, bool isComplex) {
    if (!isComplex) return null;
    final parts = <String>[];
    if (track.durationMs != null) {
      parts.add(_formatDuration(track.durationMs!));
    }
    if (_youTubeResolution != null) {
      parts.add(_isYouTubeMatched(track)
          ? 'Found on YouTube'
          : 'Not found on YouTube');
    }
    return parts.isEmpty ? null : parts.join(' · ');
  }

  /// Per-row YouTube match mark (both designs): a check in the theme
  /// accent when the track matched, a plain cross when it did not.
  /// Null before the Spotify review has run, so no mark is shown
  /// for a state that does not exist yet.
  Widget? _youTubeMark(Track track) {
    if (_youTubeResolution == null) return null;
    final scheme = Theme.of(context).colorScheme;
    final matched = _isYouTubeMatched(track);
    return Icon(
      matched ? Icons.check : Icons.close,
      size: 18,
      color: matched ? scheme.primary : scheme.onSurfaceVariant,
      semanticLabel:
          matched ? 'Found on YouTube' : 'Not found on YouTube',
    );
  }

  String _formatDuration(int ms) {
    final total = Duration(milliseconds: ms).inSeconds;
    return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')}';
  }

  /// Total runtime of the tracks that carry a duration, for the
  /// Complex tracklist header. Null when no track reports one.
  String? _totalRuntime(List<Track> tracks) {
    var totalMs = 0;
    var known = 0;
    for (final t in tracks) {
      if (t.durationMs != null) {
        totalMs += t.durationMs!;
        known++;
      }
    }
    if (known == 0) return null;
    final minutes = Duration(milliseconds: totalMs).inMinutes;
    if (minutes < 60) return '$minutes min total';
    return '${minutes ~/ 60} h ${minutes % 60} min total';
  }

  Widget _buildHeader(
      BuildContext context, PlaylistDetailData data, bool isComplex) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tokens = Theme.of(context).extension<MusicManDesignTokens>();
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

    final generation = ref.watch(generationProvider);
    final coverSize = isComplex ? 144.0 : 104.0;
    final totalRuntime = _totalRuntime(data.tracks);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: coverSize,
                height: coverSize,
                decoration: BoxDecoration(
                  color: scheme.surface,
                  border: Border.all(color: scheme.outline),
                  borderRadius:
                      BorderRadius.circular(tokens?.coverRadius ?? 2),
                  boxShadow: isComplex
                      ? (tokens?.raisedShadow ?? const [])
                      : const [],
                ),
                child: ClipRRect(
                  borderRadius:
                      BorderRadius.circular(tokens?.coverRadius ?? 2),
                  child: info.coverUrl != null
                      ? Image.network(info.coverUrl!,
                          width: coverSize,
                          height: coverSize,
                          fit: BoxFit.cover)
                      : Icon(Icons.queue_music,
                          size: 40, color: scheme.onSurfaceVariant),
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
                                color: scheme.onSurfaceVariant),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                'Only the first 100 tracks loaded. '
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
          const SizedBox(height: 16),
          const Divider(height: 1),
          const SizedBox(height: 16),

          // Settings. Complex lays them out in two columns (counts
          // and toggle left, modifier chips right); Compact stacks
          // them in one column.
          if (isComplex)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _countColumn(context, saved, platform),
                ),
                const SizedBox(width: 24),
                Expanded(
                  child: _chipsColumn(
                      context, visibleGenres, relatedAsync),
                ),
              ],
            )
          else ...[
            _countColumn(context, saved, platform),
            const SizedBox(height: 16),
            _chipsColumn(context, visibleGenres, relatedAsync),
          ],
          const SizedBox(height: 16),

          // CTA: the button turns into inline progress while a run
          // is in flight ("Analyzing track N of 20").
          _buildCta(context, data, generation),
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
            // Save to YouTube (push 4): reuses the review's resolution,
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
          Row(
            children: [
              // The count ticks to its new value in Complex (a short
              // fade over tokens.micro) and changes instantly in
              // Compact (micro is zero): a number that jumps feels
              // like a glitch, so it animates instead (DESIGN.md).
              AnimatedSwitcher(
                duration: tokens?.micro ?? Duration.zero,
                transitionBuilder: (child, animation) =>
                    FadeTransition(opacity: animation, child: child),
                child: Text(
                  'Tracks (${data.tracks.length})',
                  key: ValueKey(data.tracks.length),
                  style: theme.textTheme.titleSmall,
                ),
              ),
              if (isComplex && totalRuntime != null) ...[
                const Spacer(),
                Text(totalRuntime,
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant)),
              ],
            ],
          ),
          if (data.tracks.isEmpty)
            EditorialEmptyState(
              message: 'This playlist has no tracks to play.',
              actionLabel: saved != null ? 'Rescan' : null,
              onAction:
                  saved != null ? () => _rescan(platform) : null,
            ),
        ],
      ),
    );
  }

  /// Count presets, the Fresh finds toggle, and Rescan.
  Widget _countColumn(BuildContext context, SavedPlaylist? saved,
      MusicPlatform platform) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
        if (saved != null) const SizedBox(height: 12),
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
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Fresh finds', style: theme.textTheme.titleSmall),
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
    );
  }

  /// Discovery modifier chips: moods, genres, and related genres.
  Widget _chipsColumn(BuildContext context, List<String> visibleGenres,
      AsyncValue<List<String>> relatedAsync) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Discovery filters', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
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
                        color: scheme.secondary)),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final genre in related)
                      FilterChip(
                        label: Text(genre),
                        selected: _genres.contains(genre),
                        side: BorderSide(
                            color: scheme.secondary
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
      ],
    );
  }

  /// The big Get recommendations button. Disabled below 5 usable
  /// tracks, with the guidance line; turns into inline progress
  /// while a run is in flight.
  Widget _buildCta(BuildContext context, PlaylistDetailData data,
      GenerationState generation) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final progress = generation.progress;
    if (generation.running) {
      return Container(
        width: double.infinity,
        padding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: scheme.surface,
          border: Border.all(color: scheme.outline),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LinearProgressIndicator(value: progress?.fraction),
            const SizedBox(height: 8),
            Text(
              progress != null
                  ? 'Analyzing track ${progress.done} of ${progress.total}'
                  : 'Starting recommendations...',
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      );
    }
    final tooFew = data.tracks.length < minUsableTracks;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton(
          onPressed: tooFew
              ? null
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
                    editorialRoute(
                      context,
                      (_) => GeneratingScreen(
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
        if (tooFew) ...[
          const SizedBox(height: 8),
          Text(
            'Need at least $minUsableTracks tracks to generate '
            'recommendations. This playlist has ${data.tracks.length}.',
            style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }

  Widget _badge(BuildContext context, String label) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border.all(color: scheme.outline),
        borderRadius: BorderRadius.circular(2),
      ),
      child:
          Text(label, style: Theme.of(context).textTheme.labelSmall),
    );
  }
}
