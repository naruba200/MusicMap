# Music Man

Paste a playlist link. Get music you'll actually like.

Music Man turns any Deezer or YouTube Music playlist into personalized song
and album recommendations — powered by real listening data, with
plain-English explanations of *why* each pick fits your taste.

## Features

- **Playlist intake** — paste a Deezer or YouTube Music link; 500+ track
  playlists load fully (paginated, virtualized list). YouTube Music is
  beta, but full playlists import with no key (see below).
- **Recommendation engine** — Last.fm-powered scoring (rank-decay,
  genre/mood boosts, fresh-finds): 30–150 songs and 5–30 albums per run,
  each with an explanation.
- **Tune it** — 28 genre chips + 7 mood chips, or hit **Surprise me** to
  discover with no seed playlist at all.
- **Library** — favorites (songs & albums) with daily picks, full run
  history, saved playlists with one-tap rescan ("N new tracks" badge),
  JSON export of everything.
- **News tab** — 9 music-news RSS sources with a For You ranking based on
  the artists you like; articles open in Custom Tabs, works offline from
  cache.
- **Open anywhere** — every song/album links out to Spotify, Deezer,
  YouTube, or YouTube Music (search links, no auth needed).
- **Discover tab** — one tab per new source, kept out of core Last.fm
  scoring. Audius: trending tracks, track/playlist search, playlist
  import with a "Get recommendations" run, and full streams that play
  inside the Audius tab only. Jamendo: Creative Commons track search,
  playlist import, and radios (same in-tab playback). Openwhyd: public
  playlist import, tracks opening on their original platform. Mixcloud:
  popular/hot/new shows, show + tag search — a browser only, it never
  feeds the song generator.
- **Private by design** — no accounts, no servers, no ads, no tracking.
  Everything lives on your device. ([Privacy policy](docs/privacy.html))

## Tech

Flutter (Android-first) · Riverpod · Dio · Hive + flutter_secure_storage ·
pure-Dart recommendation engine & RSS parser · unit-tested
(`flutter test`).

**Spec:** this project is built spec-first — the product specification is
the source of truth for behavior. Ask the maintainer for the latest copy
before changing behavior.

## Setup (developers)

```bash
flutter pub get
flutter analyze
flutter test
flutter run
```

Then add the two intent-filters from `docs/android-share-intent.md` to
`android/app/src/main/AndroidManifest.xml` (OAuth redirect + share-intent).

Windows builds (`flutter run -d windows`) work for UI testing; receiving
share intents is Android-only and is skipped on desktop.

## Keys & setup notes

- **Spotify**: **parked for v1** (adapter kept in-repo). Since Feb 2026
  Spotify blocks Dev Mode apps from the Web API unless the dashboard
  account holds Premium, and playlist creation needs user OAuth — so v1
  does intake via Deezer (no auth) and links out via Spotify search URLs
  (no auth).
- **Deezer**: no key needed for public playlists — the zero-setup intake
  path.
- **SoundCloud**: parked for v1 — SoundCloud now requires an Artist Pro
  account for API access. The adapter
  (`lib/data/platforms/soundcloud_platform.dart`) is kept in-repo and can
  be re-enabled in the dropdown when a `client_id` exists.
- **Last.fm**: free API key (spec §10) in `lastFmApiKey`
  (`lib/core/constants.dart`). Free-tier, revocable — never commit a paid
  key.
- **Audius (Phase 4)**: no key needed. The discovery host is resolved
  from `https://api.audius.co` at runtime (hard-coded fallback host if
  that lookup fails); all calls send `app_name=MusicMan`.
- **Jamendo (Phase 4)**: free `client_id` from
  https://devportal.jamendo.com, put in `jamendoClientId`
  (`lib/core/constants.dart`) locally — never commit a real id. Until
  it is set, the Jamendo Discover tab shows a setup hint.
- **Openwhyd (Phase 4)**: no key needed. Public playlists import via
  the no-auth Data Export API (`?format=json`); the export carries no
  playlist name, so the tab names imports from their URL. Tracks open
  on YouTube/SoundCloud/Deezer/Vimeo — no in-app Openwhyd playback.
- **Mixcloud (Phase 4)**: no key needed for reads. Shows list only and
  open in Mixcloud; Mixcloud serves streams through its widget/embed,
  not a public stream URL, so no in-app playback is built and no show
  is ever converted into a generator seed.
- **YouTube Music full playlists (Phase 4a)**: no key needed. The
  WEB_REMIX client caps a playlist shelf at 100 tracks and its
  continuation token dead-ends, so the adapter now also walks the same
  playlist via the TVHTML5 client (15 tracks/page, no auth) and merges
  by videoId — WEB_REMIX entries keep their richer artist/title
  columns, TVHTML5 supplies the remainder (titles split on "Artist -
  Title"). Verified live 2026-10-26: DJMax OST 294/294, "Iconic songs
  of osu!" 346 unique tracks with a clean end (vs 371 in Oct 2024 —
  most plausibly videos removed/privated since). If the full walk
  fails or hits its ~1000-track page cap, the import still returns
  what it got and the detail screen warns that the list stopped early
  instead of silently truncating. The YouTube Data API v3 route was
  deliberately not built: the no-key route fully works, so no key
  setup is required; a Data API key would only arbitrate counts for
  removed/private videos.

## Release

See [`docs/release-runbook.md`](docs/release-runbook.md) for the signing,
versioning, and Play Console steps, and
[`docs/play-listing.md`](docs/play-listing.md) for the store listing draft.

## CI

`.github/workflows/ci.yml` runs `flutter analyze` + `flutter test` on
every push to `main` (the file can't be pushed via the GitHub App — it was
added through the web UI).
