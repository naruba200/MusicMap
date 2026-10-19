# Music Map

Paste a playlist link. Get music you'll actually like.

Music Map turns any Deezer or YouTube Music playlist into personalized song
and album recommendations — powered by real listening data, with
plain-English explanations of *why* each pick fits your taste.

## Features

- **Playlist intake** — paste a Deezer or YouTube Music link; 500+ track
  playlists load fully (paginated, virtualized list). YouTube Music is
  beta (~100 tracks per playlist).
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

## Release

See [`docs/release-runbook.md`](docs/release-runbook.md) for the signing,
versioning, and Play Console steps, and
[`docs/play-listing.md`](docs/play-listing.md) for the store listing draft.

## CI

`.github/workflows/ci.yml` runs `flutter analyze` + `flutter test` on
every push to `main` (the file can't be pushed via the GitHub App — it was
added through the web UI).
