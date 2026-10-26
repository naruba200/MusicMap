# Music Man — Phase 5 notes (enrichment features)

Phase 5 built, in order: LRCLIB lyrics, then the three investigated
items, then Odesli, then Bandsintown last. Two features shipped, three
were cut after investigation, one ships dormant. Nothing here changes
recommendations; every item is a feature or an enrichment, and every
failure degrades to an empty state, never an abort.

## Shipped

### LRCLIB lyrics (push 1)

- `lib/data/lyrics/lrclib_client.dart` — no-key `GET
  https://lrclib.net/api/get` by artist/title/album/duration, with the
  required User-Agent. Plain lyrics first, synced (LRC) lines as the
  fallback text; instrumental tracks are reported as instrumental.
  The lookup never throws: 404 / 500 / network error all yield null.
- `lib/data/lyrics/lyrics_cache.dart` — Hive box `lyrics_cache`,
  30-day TTL for hits and misses (plan §0).
- `lib/presentation/screens/lyrics_screen.dart` — lyrics view reached
  from the lyrics button on a results song row. Unknown tracks get
  the honest "No lyrics found" state, never an error screen.
- Phone QA: real lyrics for a known track; honest empty state for an
  unknown one; instrumental track shows the instrumental state.

## Cut after investigation (not forced, not scraped)

### Release alerts — CUT (Muspy / MusicButler / Brew.fm all unusable as APIs)

Checked each service in turn (2026-10-26):

- **Muspy**: an account-based email/RSS notification service built on
  MusicBrainz data. It publishes no public third-party API; the only
  programmatic surface is a logged-in user's own feed. Its old Android
  app read MusicBrainz directly, not a Muspy API.
- **MusicButler**: an account-based daily-email / dashboard / RSS
  service (artists imported from Spotify/Apple Music/Last.fm). No
  public developer API was found; releases are served to the logged-in
  user's own dashboard only.
- **Brew.fm**: a Spotify-connected release-radar service. No public
  API for third-party apps was found.

Building any of the three would have meant screen-scraping a
logged-in account or faking a feed — both out of scope, so the
feature is cut rather than forced. Documented future alternative (not
built here): the app already has a MusicBrainz client + throttler
(Phase 2), and MusicBrainz release-group browse is public and no-key,
so a "recent releases from your favourited artists" list could later
be built on MusicBrainz alone without any of these three services.

### Soundtrack tags — CUT (Tunefind API gated)

Tunefind (tunefind.com, owned by Songtradr) catalogs songs featured
in TV, film and games, and has had a developer API since 2010 — but
access is commercial/partner-gated (licensing via Songtradr), with no
self-serve free key found. Scraping its pages instead was explicitly
ruled out by the task, so the "featured in …" card enrichment is cut
rather than scraped. No Tunefind code ships.

### Odesli / Songlink links — CUT (degradation unrefuted + no input IDs)

The earlier report (YouTube/Apple links missing, Spotify
rate-limiting) could not be refuted with verifiable current evidence
from this environment, and there is a structural blocker on top: the
Odesli lookup needs a platform entity URL/ID (e.g. a Spotify track
URI), which the app does not hold for recommended tracks — it holds
artist/title only. Using it would need a whole new platform-ID
resolution layer, not the drop-in "Open in…" improvement it was
supposed to be. Cut; the existing outbound sheet (platform search
URLs: Spotify / Deezer / YouTube / YouTube Music) stays as-is and
remains the fallback — it never depended on Odesli.

## Dormant (code path only, user-side steps pending)

### Bandsintown events (push 2, LAST)

- `lib/data/events/bandsintown_client.dart` — artist upcoming-events
  client (`GET https://rest.bandsintown.com/artists/{artist}/events
  ?app_id=…&date=upcoming`), defensive parsing, [] on any failure.
- `lib/presentation/screens/artist_events_screen.dart` — events for
  favourited artists (capped at 10 artists, one call each), reached
  from the event button on the Favorites screen.
- `lib/core/constants.dart` — `bandsintownAppId` placeholder, same
  pattern as Jamendo's `client_id`.

Dormant by design: while the placeholder is set, the client makes NO
network call and the screen shows a setup hint. Nothing here fakes
consent or claims access the app does not have.

User-side steps to activate (all outside the repo):

1. Accept the Bandsintown API terms at
   https://corp.bandsintown.com/dataapplicationsterms.
2. Contact Bandsintown (https://help.bandsintown.com) describing the
   intended use, and request written consent + an app ID.
3. Put the issued app ID in `bandsintownAppId`
   (`lib/core/constants.dart`) locally only — never commit a real one.
4. Phone QA once set: the Favorites → event button lists real
   upcoming events; with no events, the honest empty state shows.

## Pending verification (no Flutter SDK in the assistant VM)

- `flutter analyze` — 0 issues, and `flutter test` — all green,
  including `test/lrclib_lyrics_test.dart` and
  `test/bandsintown_events_test.dart` (user runs on PC).
- Phone QA per feature, as listed in the sections above.
