# Music Man — Full-song playback

Status: shipped in the full-song pivot (push 1 + VISIONOS rung, heads
`81fb9b39` → `f8d043e6`) and the Phase C player (heads `afc1f99` →
`c88d283e`). This file describes what the app actually does. The
design of the player screens is in `docs/design.md`.

## Full songs only — previews are scrapped

A track plays as a full song or fails with a logged reason. There is
no 30-second preview anywhere in the app: the old preview chain
(`resolvePreview` and the iTunes/Deezer preview lookups) was deleted,
and nothing in playback consults `track.previewUrl` anymore (the
field survives only for serialized-data compatibility).

## The resolver chain

`lib/data/fullsong/full_song_resolver.dart` finds a full song for a
track, in priority order. Sources run concurrently *within* a phase
(one phase per priority band) and phases run in order, so an in-app
match always beats an outbound link. Every attempted source is
logged, and each source is bounded by an 8-second timeout.

1. **The track's own `streamUrl`** (Audius/Jamendo-imported tracks) —
   plays in-app.
2. **Audius search** — plays in-app. The artist check is *required*
   when the artist is clean; title-only only when the artist is
   really unknown.
3. **Jamendo search** — plays in-app, only when the user has set a
   Jamendo `client_id` (`lib/core/constants.dart`, local only).
4. **YouTube Music finder → VISIONOS player client** — the finder
   matches strictly on title + artist and returns a videoId; the
   VISIONOS client resolves a direct audio-only stream URL that
   plays in-app. On failure (bot-gated, no audio URL, network) the
   match stays external (opens in the YouTube / YouTube Music app)
   and the log records why.
5. **Spotify metadata search → one re-resolve round** — Spotify finds
   the canonical track, then the resolver tries Audius + the YTM
   finder once more with the corrected metadata. Metadata only (see
   below). This phase runs only when no in-app match was found yet.
6. **Deezer / iTunes links** (strict match) — external match only.

**Matching is always artist + title** (cleaned title equality + the
artist first-word rule). Title-only is allowed only when the artist
is really unknown (`RecommendationEngine.isPollutedArtist`) — the
old title-only steps that played wrong same-title songs are gone,
and a wrong match is no longer cached.

**Caching:** successful in-app resolutions are cached (stream URL
per normalized key). Failures are never cached — a failed source may
succeed later. External matches are not cached (links rot, and
re-finding them is cheap).

No audio extraction, no yt-dlp-style downloading, no signature
decipherer, no PO-token solver. In-app YouTube audio comes only from
the VISIONOS player response's plain stream URLs.

## YouTube Music in-app audio via VISIONOS

`lib/data/export/visionos_player_client.dart` calls
`youtubei/v1/player` with the VISIONOS client shape (client 1.02,
Safari UA) and the public InnerTube web key. It picks audio by itag
preference 251 (Opus ~160kbps) → 140 → 250 → 249 → 139, uses only
formats carrying a plain `url`, and ignores `signatureCipher`
entries entirely.

Verified live 2026-11-15: `dQw4w9WgXcQ` returned playability OK
with 27 formats and 5 audio URLs; the itag 251 URL was fetched
(HTTP 206, real WebM audio). The WEB / ANDROID / IOS / EMBEDDED
client shapes return zero audio URLs for the same videos (PO-token
gated), so VISIONOS is the only client shape that serves direct
audio URLs without a token.

**Bot-gate caveat:** two other test videos returned
`LOGIN_REQUIRED` ("Sign in to confirm you're not a bot") from a
datacenter IP — likely IP reputation, and a phone on mobile data may
do better. The resolver treats that as a normal fall-through to the
external handoff, never as an error. Phone QA is the decider: worst
case on the phone is the old external-handoff behavior, not a crash.

## Spotify is metadata-only

Spotify search uses the app's existing internal contract
(`searchTracks` persisted query over the web-player GraphQL
endpoint, reusing the `sp_dc` session from the playlist import) to
find the canonical track. It gives metadata, never audio: Spotify
web audio is Widevine-DRM and cannot play in-app, and the Spotify
step never claims otherwise. If the canonical track has no playable
stream anywhere else, the failure is reported as "Spotify audio
can't play in-app".

Background: the official Web API route needs Premium and a client
secret that cannot ship in an APK, so it is out. A plain-web-player
WebView wrapper was tested live 2026-11-16 in a logged-in browser
session (free account): sign-in worked, but playback never started
in five attempts and no playback state was exposed — not viable
there. The phone WebView is the only remaining proof path; until
that proves otherwise, Spotify stays metadata-only.

## The resolution log

Every resolve records one entry in the resolution log
(`lib/data/fullsong/resolution_log.dart`): the track, each source
tried, the outcome, and the reason. Read it in the app at
Settings → Playback → Playback log (newest first, per-source reason
inline, Clear). The log holds the last 100 attempts.

Playback failures are reported with the reason, not a generic
message:

- `No full stream found for this track` — no source had a strict
  match.
- `Couldn't reach <source> — check your connection` — a source
  could not be reached.
- `Spotify audio can't play in-app` — Spotify knew the track but
  nothing else had a playable stream.

## The player

- **Full player** (`lib/presentation/screens/full_player_screen.dart`):
  big cover, title/artist, seekable progress with real times,
  previous / play-pause / next / stop, like, add to playlist, queue
  list below with the current row marked, shuffle and repeat.
  Swipe down dismisses to the mini-player; drag the progress rule
  to scrub (time bubble, thumb grows while scrubbing); swipe a
  queue row to remove it; double-tap the cover to like. Complex
  adds a related-picks section from the other queue tracks.
- **Real progress time:** the duration is fetched with
  `AudioPlayer.getDuration()` after play starts (the old
  `onDurationChanged`-during-play race dropped it, so the bar used
  to show "Live" for every song). "Live" now shows only for true
  live streams (Jamendo radio).
- **Queue, shuffle, repeat:** `PlaybackState` carries
  `shuffleEnabled`, `repeatMode` (`off` / `all` / `one`) and
  `shuffledOrder` (current track first). Queue editing: move,
  remove, play-next, add-to-queue.
- **Mini-player:** hoisted above the Navigator (`AppShell` in
  `lib/main.dart`), so it stays visible on pushed screens. Hides
  while the full player is open. Real time labels, no "Live"
  fallback except for true live streams.
- **Media notification:** Android notification player via
  `audio_service` (previous / play-pause / stop / next).

## Known gaps

- **Same-track retap toggles pause.** Tapping a playing track again
  pauses it (existing `AudioPlayerNotifier` behavior), so two taps
  ~400 ms apart on the same row pause instead of replaying. This is
  the player behavior, not the tap rule; changing it is a
  player-level change.
- **No Undo for:** `FavoriteButton` / `FavoriteAlbumButton` (plain
  SnackBar), Favorites swipe-to-remove (no toast at all),
  multi-select remove (plain SnackBar), History clear (would need a
  snapshot), Save to YouTube (external playlist, cannot be undone).
- **Per-track platform is not recorded** (see `docs/design.md`):
  the resolver knows which source matched, but `Track` carries no
  platform field, so the UI cannot show it.
- **Phone QA is still pending:** full songs playing in-app, wrong-
  artist same-title tracks rejected, the three failure messages,
  the Playback log, the Spotify 401 path, and queue / mini-player /
  notification regressions — pull `main`, run on the phone, and
  check them live.
