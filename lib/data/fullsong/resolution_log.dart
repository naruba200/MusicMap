// Resolution log (full-song pivot, push 1): every full-song resolve
// attempt is recorded here — which sources were tried, in order, and
// why each one matched or failed — so a wrong-song / no-song case can
// be diagnosed from the app instead of guessed at. In-memory only
// (last ~100 attempts, ring buffer); nothing is persisted. The
// SnackBar keeps the short reason; this log has the detail, shown on
// the "Playback log" screen (reachable from Settings).

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../engine/recommendation_engine.dart';
import '../models/music_models.dart';

/// How one source attempt ended.
enum SourceOutcome {
  /// A strict match was found (in-app stream or outbound link).
  matched,

  /// The source answered but nothing matched strictly.
  noMatch,

  /// The source could not be reached (timeout / connection failure).
  networkError,

  /// A match was found but it carries no playable audio URL in-app
  /// (YouTube Music finder: the VISIONOS player call returned no
  /// audio URL — bot-gated, or no audio-only format with a plain
  /// URL — so the match stays an outbound link).
  noDirectUrl,

  /// The track exists on the source but its audio cannot play in-app
  /// (Spotify: Widevine-DRM web streams).
  drmUnplayable,

  /// The source rejected the session (Spotify 401/403): the user must
  /// sign in again.
  sessionRejected,

  /// The source was not attempted (no client configured, or the
  /// resolve already had a better match).
  skipped,
}

/// Human label for a [SourceOutcome], for the log screen.
extension SourceOutcomeLabel on SourceOutcome {
  String get label {
    switch (this) {
      case SourceOutcome.matched:
        return 'Matched';
      case SourceOutcome.noMatch:
        return 'No match';
      case SourceOutcome.networkError:
        return 'Network error';
      case SourceOutcome.noDirectUrl:
        return 'No direct audio URL';
      case SourceOutcome.drmUnplayable:
        return 'Audio cannot play in-app';
      case SourceOutcome.sessionRejected:
        return 'Session rejected';
      case SourceOutcome.skipped:
        return 'Skipped';
    }
  }
}

/// One source tried for one track, in attempt order.
class SourceAttempt {
  /// Source label: 'own stream', 'audius', 'jamendo', 'youtube',
  /// 'spotify', 'spotify-audius', 'spotify-youtube', 'deezer',
  /// 'itunes', 'cache'.
  final String source;
  final SourceOutcome outcome;

  /// Free-text detail: why it matched / failed (e.g. "title matched
  /// but artist did not match", "SocketException: Failed host
  /// lookup", "videoId abc123, no direct audio URL").
  final String detail;

  const SourceAttempt({
    required this.source,
    required this.outcome,
    this.detail = '',
  });
}

/// One full resolve attempt for one track.
class ResolutionEntry {
  /// Normalized "artist - title" key, same as generation uses.
  final String trackKey;
  final String title;
  final String artist;
  final DateTime time;

  /// Per-source attempts, in the order they ran.
  final List<SourceAttempt> attempts;

  /// Short summary of the outcome ('Audius stream', 'YouTube link',
  /// 'No full stream found', ...).
  final String result;

  const ResolutionEntry({
    required this.trackKey,
    required this.title,
    required this.artist,
    required this.time,
    required this.attempts,
    required this.result,
  });

  factory ResolutionEntry.forTrack(
    Track track, {
    required List<SourceAttempt> attempts,
    required String result,
    DateTime? time,
  }) =>
      ResolutionEntry(
        trackKey:
            RecommendationEngine.normalizeKey(track.artist, track.title),
        title: track.title,
        artist: track.artist,
        time: time ?? DateTime.now(),
        attempts: List.unmodifiable(attempts),
        result: result,
      );
}

/// In-memory ring buffer of the last [maxEntries] resolve attempts.
/// Plain Dart (no Riverpod) so the resolver can record into it
/// directly; [ResolutionLogNotifier] exposes it to the UI.
///
/// Wiring note: the resolver records straight into this object, so
/// [onChanged] is how the notifier learns about it. Without the
/// callback the notifier's state would stay empty forever even
/// though the buffer holds entries, which is exactly how the
/// Playback log screen ended up blank: the resolver wrote here, the
/// notifier never re-emitted, and the screen watches the notifier's
/// state, not this buffer.
class ResolutionLog {
  static const int maxEntries = 100;

  final List<ResolutionEntry> _entries = [];

  /// Called after every [record] and [clear]; the notifier sets this
  /// to re-emit the entry list for the screen.
  void Function()? onChanged;

  List<ResolutionEntry> get entries => List.unmodifiable(_entries);

  void record(ResolutionEntry entry) {
    _entries.add(entry);
    while (_entries.length > maxEntries) {
      _entries.removeAt(0);
    }
    onChanged?.call();
  }

  void clear() {
    _entries.clear();
    onChanged?.call();
  }
}

/// Riverpod wrapper around a [ResolutionLog]: state is the entry list,
/// newest last (the screen reverses it). The resolver records through
/// [log]; the screen watches the state. The constructor wires
/// [ResolutionLog.onChanged] so a record made straight into [log]
/// (which is how the resolver writes) re-emits the state. Without
/// that wiring the screen would stay empty while the buffer fills.
class ResolutionLogNotifier extends StateNotifier<List<ResolutionEntry>> {
  final ResolutionLog log = ResolutionLog();

  ResolutionLogNotifier() : super(const []) {
    log.onChanged = () => state = log.entries;
  }

  void record(ResolutionEntry entry) {
    log.record(entry);
    state = log.entries;
  }

  void clear() {
    log.clear();
    state = const [];
  }
}
