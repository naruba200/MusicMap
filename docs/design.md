# Music Man — Design system (Japanese editorial)

Status: shipped in Phases A–C of the redesign (heads `deca01bd` →
`39e4d52` → `c88d283e`). The design authority is
`~/workspace/musicman-player/DESIGN.md` (kept outside the repo with
the interactable prototype); this file summarizes what actually
shipped in the repo. Where the shipped app deliberately differs from
DESIGN.md, the divergence is listed at the bottom — DESIGN.md is the
authority, this file is the record.

## Identity

A streaming app that reads like a Japanese music magazine, with a
recommendation feature that turns a playlist into picks:
paper, ink, one accent, and cover art doing the talking. No
gradients, no glass, no glow. Sharp corners (4px cards/buttons, 2px
covers/chips). The vermillion stamp motif marks each screen with one
kanji: 音 Home, 選 Results, 新 Discover, 聞 player, 記 History.
Japanese accents appear sparingly as graphic marks (おすすめ,
お気に入り, 最新).

Dials: ENERGY 2 / RHYTHM 3 / MOTION 0 in Compact, MOTION 2 in
Complex.

## Theme system

Six named themes. Every theme uses the same seven roles: Paper (page
background), Paper 2 (raised surface), Ink (headlines/body/icons),
Ink soft (secondary text), Hairline (borders and rules only, never
text), Accent (the one accent), Accent text (the accent darkened for
small text).

| Theme | Paper | Paper 2 | Ink | Ink soft | Hairline | Accent | Accent text |
|---|---|---|---|---|---|---|---|
| Editorial (default) | #F5F1E8 | #EFE9DC | #1A1A1A | #55524A | #D8D2C4 | #D43D2A vermillion | #A82A1C |
| Tako (dark) | #221A33 | #2C2140 | #F2EEF5 | #C4B8D4 | #453A5C | #DE4F27 coral | #E86A4A |
| Cappuccino | #F3EBDD | #EADFCB | #2B2118 | #6B5B49 | #D9CBB2 | #A96F2C caramel | #7E4F1A |
| Matcha | #EFF3E4 | #E4EAD2 | #1E3320 | #4F6248 | #D2DCC0 | #4A7C2E leaf | #35611F |
| Sakura | #F9EDEF | #F3DFE4 | #3D2430 | #6E5560 | #E3C9D1 | #C2456B rose | #9C2F50 |
| Midnight (dark) | #141B2D | #1C2539 | #E9EAF0 | #A9B2C6 | #2E3A52 | #E3C878 gold | #E3C878 |

Contrast floors, verified in `test/appearance_test.dart` for all six
themes: ink/paper ≥12:1, ink soft/paper ≥5.5:1, accent text/paper
≥5.2:1, accent/paper ≥3.4:1, paper text on accent ≥3.4:1, accent on
paper 2 ≥3.1:1. The accent is used only for large text (18px and up),
bold labels, and graphic marks; small accent text uses the theme's
accent-text color.

## Theme and Design are independent axes

Settings → Appearance (the first section in Settings) holds both
controls, and changing one never changes the other:

- **Theme picker**: the six named themes as swatches in each theme's
  own palette. Tap applies; long-press previews the whole app in
  that theme until release.
- **Design toggle**: Compact / Complex segmented control. Switching
  re-lays out every screen; it never changes color. Default:
  Compact.

Defaults: Editorial + Compact. The choice is stored on-device in
Hive (`SettingsRepository`, keys `theme` / `design`) and restored on
launch; unknown stored values fall back to the defaults. The theme
is also part of the data-export bundle. `MaterialApp` theme and
darkTheme are the same selected ThemeData, so the chosen theme
always wins over system brightness.

## Typography

- Display/headlines: Archivo 700/800 (masthead, screen titles), 600
  (section titles).
- Body/labels: Archivo 400/500, with tabular figures for numbers
  (chart positions, counts, times).
- Stamp kanji and Japanese accents: Noto Sans JP 700.

Fonts come from the `google_fonts` package (6.3.3): each weight is
downloaded once and cached in the app's support directory, so after
the first fetch the app is fully offline in the new type. A first
launch with no network degrades gracefully to the system font.

**Bundled-font swap path (prepared, not in the repo):** the push
path cannot deliver binary files, so the six subsetted TTFs
(Archivo 400–800 Latin subset, Noto Sans JP 700 subset to the 14
stamp/accent characters; 313,952 bytes) are prepared at
`~/workspace/musicman-player/fonts/` with a README. From the user's
PC: copy them to `assets/fonts/`, declare them in `pubspec.yaml`
(family `Archivo` weights 400/500/600/700/800; family `Noto Sans JP`
weight 700), replace the two `GoogleFonts` calls in
`lib/core/theme.dart` with plain `fontFamily` styles, and remove the
`google_fonts` dependency.

## Motion

- **Compact (MOTION 0)**: strictly instant. All durations zero, one
  soft shadow only (the playing cover in the full player). The
  playing row shows a static playing mark instead of the animated
  equalizer. Stillness is the point, not a missing feature.
- **Complex (MOTION 2)**: screen transitions ~200 ms, full player
  rises ~220 ms, tab switch ~220 ms, micro-interactions ~150 ms,
  progress tick 250 ms. Three-level elevation: flat (paper page),
  raised (paper 2 panels, short soft shadow), floating (playing
  cover, full player sheet, deeper shadow). Dark themes get stronger
  shadows.
- **Reduced motion**: `reduceMotion` zeroes all five durations, read
  from the platform dispatcher and `MediaQuery.disableAnimations`.

Every interaction works in both designs; only the motion changes.

## Gesture map

| Gesture | Where | Result |
|---|---|---|
| Tap a song row | Results | Plays after a 250 ms window (see below) |
| Fast double-tap a song row | Results | Likes the song instead of playing |
| Tap a track | Playlist detail | Plays immediately (no double-tap window) |
| Tap the reason line | Results row | Opens Why this song |
| Tap an album cover | Cards, album detail | Expands the tracklist inline |
| Double-tap a cover | Player, album cards | Likes it |
| Swipe a song row | Results, Playlist detail, Favorites | Quick actions: Like, Add to playlist, Remove |
| Swipe again (same direction) | Favorites, actions open | Removes at once (button stays too) |
| Long-press a song row (~500 ms) | Any song row | Context sheet (see below) |
| Press, hold, then drag a row | Any song row | Drag onto a playlist to add it (drop bar + Undo) |
| Swipe left/right | Tab screens | Switch tabs, next tab previewing as you drag |
| Pull down at the top | News, Discover | Refresh that tab |
| Swipe the full player down | Full player | Dismiss to the mini-player |
| Drag the progress rule | Full player | Scrub, with a time bubble and growing thumb |
| Drag a queue row by its grip | Full player | Reorder (keyboard: move-up/down buttons) |
| Swipe a queue row | Full player | Remove from the queue (Undo) |
| Long-press a theme swatch | Settings → Appearance | Preview the theme until release; tap applies |

The 250 ms double-tap window: a single tap on a result row waits
out the window before playing, so a second tap inside it likes
instead. The same rule applies to the row's cover thumb. A second
tap after the window has closed is a second single tap. The heart
button on the row always likes on its own. (One behavior note: a
same-track retap currently toggles pause instead of replaying — the
existing `AudioPlayerNotifier` behavior, listed under Known gaps.)

The context sheet (overflow button or long-press) holds six entries:
Play next, Add to queue, Add to playlist, Lyrics, Why this song,
Share. Lyrics is in the sheet because it is the only entry point to
the lyrics view. Why this song appears only when the row has a
reason.

The mini-player is hoisted above the Navigator (`AppShell` in
`lib/main.dart`), so it stays visible on every screen including
pushed screens (Results, Playlist detail). It hides while the full
player itself is open, since the player duplicates it. Toasts appear
above the mini-player strip, with Undo where the action can be
undone.

The News tab dot marks real new content: visiting News clears it,
new content arriving shows it again.

## Where the shipped app differs from DESIGN.md (deliberate)

1. **Context sheet has six entries, not five.** DESIGN.md's
   round-4 list predates Lyrics joining the sheet. Lyrics is the
   only entry point to the lyrics view, so the sheet carries it:
   Play next, Add to queue, Add to playlist, Lyrics, Why this song,
   Share.
2. **Tab swipe uses PageView's native snap semantics**, not the
   prototype's exact 60 px release threshold. The behavior is the
   same: the next tab previews as you drag, release completes the
   switch or snaps back (velocity-aware).
3. **The mini-player hides while the full player is open.** The
   player duplicates the strip, so the strip would be a dead
   duplicate.

## Known gaps

- **Per-track platform is not in the data model.** `Track` has no
  platform field and no per-track source is recorded, so Complex
  result rows show year + duration only, not platform, even though
  DESIGN.md lists platform in the Complex metadata. Showing it
  needs a data source first; nothing was invented.
- **Per-theme dark variants for the four light themes** (Editorial,
  Cappuccino, Matcha, Sakura) are a follow-up, defined from each
  theme's own palette. Tako and Midnight are the set's two dark
  themes.
- **Phone QA is still pending**: all six themes × both designs,
  slide/instant transitions, haptics, and the gestures on a real
  device.
