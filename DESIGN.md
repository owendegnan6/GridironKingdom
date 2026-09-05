# Design — The Kingdom's Ledger

<!-- impeccable:design-schema 1 -->

## World

A worn leather program ledger under desk-lamp light, not a glowing tech dashboard. This replaces the app's previous identity (near-black ground, single flat gold accent, soft radial glow) because that pairing is a recognized AI-generated-interface default — named explicitly in this project's own design tooling as one of the handful of looks AI output clusters around regardless of subject.

Direction was assigned by the project's concept-seed process from 7 candidate visual worlds grounded in college-football broadcast/program culture (network graphics, media guides, stadium signage, recruiting-rankings UI, coach's whiteboard, trading cards, varsity heritage). The rolled assignment was "Stadium Signage & Scoreboard"; the user reviewed it alongside challenger alternates and pinned "Heritage leather archive" instead, fused specifically to this product (a coaching-dynasty program ledger, not a generic bookshelf) rather than built as originally pitched. A user-pinned choice overrides the roll per the process's own rule.

## Palette — `GKColors` (`lib/main.dart`)

- **Ground**: `ledgerBlack` (0xFF150F0B), `oxblood` (0xFF3A1E17), `saddleLeather` (0xFF3D2A1B), `elevatedLeather` (0xFF4A3323) — dark tooled-leather tiers, used by depth (ground → panel → raised panel).
- **Structure**: `stitchLine` (0xFF7A5B37) — thread-colored dividers/borders, replaces the old flat `divider`.
- **Paper** (contained insets only, never the full ground): `agedPaper` (0xFFE9DDBE), `paperShadow` (0xFFCBB98F), `inkBlack` (0xFF241A10) for text on paper.
- **Ink on leather**: `parchmentWhite` (0xFFF4E9D2) primary text, `fadedInk` (0xFFBBA47D) secondary/muted text.
- **Accent**: `kingdomBrass` (0xFFC08A3E) / `brightBrass` (0xFFDCAA5C) — the single accent family (buttons, active states, stat emphasis). No second neon accent anywhere in the app; the former `_commandCyan` (KingdomNetworkScreen) and `_gameCyan` (GameSimScreen) neon-cyan sub-palettes were repointed to this same brass/`fieldGreen`/`stampRed` family.
- **Status**: `fieldGreen` (0xFF3F6B49, positive/good), `stampRed` (0xFFAE4530, warning/negative), `wardenBlue` (0xFF3D6B8C, used sparingly).

Legacy short tokens (`kGold`, `kRed`, `kDark`, `kCardColor`, `kBorder`, `kGreen`) are kept as aliases onto the palette above so the ~150 call sites still written against them repaint without a per-site edit. `kRed` previously duplicated `kGold`'s exact value — a pre-existing bug, since every call site (hot seat, cut, outside-looking-in, no-bowl) is a warning state — now corrected to resolve to `stampRed`.

Team colors (real NCAA school colors, `CollegeTeam.primary`/`.secondary`) are used as-is throughout — team identity is data, not part of this palette, and stays a first-class accent wherever a program's own colors should read (headers, badges, panels).

## Type — `GKText`

- **Display/headings**: Cinzel (`GoogleFonts.cinzel`) — an engraved/carved-serif face with the "lettering stamped into leather" character the direction's own system grammar specified. All-caps friendly, matching the app's existing heavy use of `.toUpperCase()`.
- **Body/data**: Zilla Slab (`GoogleFonts.zillaSlab`) — the workhorse face for dense tabular content (rosters, stat tables, standings), set as the app's ambient `ThemeData.textTheme` font so screens that never touch `GKText` directly still repaint (Flutter's default `TextStyle.inherit` pulls `fontFamily` from the ambient theme when a style doesn't set its own).
- Real weight steps replace the prior near-uniform `FontWeight.w900` everywhere: `body` is w400, `bodyStrong`/`cardTitle` w600–700, `display`/`sectionLabel` reserved for true headline moments.
- No system display face (Roboto/SF) carries any heading — both faces are sourced via the `google_fonts` package (added to `pubspec.yaml`), not left as a training-data-default fallback.

## Components — `lib/main.dart`

- **`GKBackground`**: deterministic leather-grain texture (`_LeatherGrainPainter`, seeded `Random`, `RepaintBoundary`-cached) plus a soft upper-third lamplight pool and edge vignette. Replaces the old flat navy gradient + two soft glow circles — the glow circles were the exact "near-black + neon-glow-edges" cliché this direction refuses.
- **`GKCard`**: leather panel with a dashed brass stitch-seam along the top edge, real offset+blur shadow (not a zero-offset colored halo), sharp 6px corners. A `paper` variant (`GKCard(paper: true)`) renders an aged-paper inset with a torn/deckle top edge (`_DeckleEdgeClipper`) for dense tabular data.
- **`GKPrimaryButton`/`GKSecondaryButton`**: stamped-brass (top-lit gradient bevel) and leather-strap (saddle fill, brass hairline) respectively, both with real directional drop shadows.
- **`GKSectionHeader`**: no kicker/eyebrow above the heading — removed per the project's craft-floor rule ("a kicker or eyebrow above a heading… no brief earns it back"). Screens that passed an `eyebrow` (e.g. team name, step context) now fold that information into the subtitle or drop it where the surrounding UI (step-progress dots) already carries it.
- **`GKStudioMark`**: brass medallion with a real two-stop gradient bevel and offset shadow, replacing a glossy diagonal-gradient badge with a colored glow halo.
- **`GKTeamBadge`**: varsity letter-patch — team's own primary/secondary colors, brass stitched frame, authored typographic monogram (`teamMonogram()`, e.g. "Ohio State" → "OSU"). Replaces `teamEmoji()`, a 60-branch function mapping real school names to mascot emoji standing in for a crest — an absolute craft-floor ban ("unicode glyphs or emoji standing in for an icon system"). All 13 call sites across the app (mini/small/big logo helpers, rankings rows, bracket seeds, program-legacy headers) now route through this one component; `teamEmoji()` was deleted as dead code.
- `GKRadius` collapsed from 17 ad-hoc values (1–30px) to 6 deliberate steps; a leather-and-paper world reads architectural, not soft-rounded-everything.
- Zero-offset "glow halo" `BoxShadow`s (color + blur, no offset — a named craft-floor default to refuse) were given real directional offsets across ~10 call sites app-wide.

## Known gaps (not yet migrated)

This was a large single-file app (~20k lines) redesigned in one pass; coverage is broad but not total:

- **`RecruitProfileScreen`, `ContractSigningScreen`, `_OffseasonScreenState`, `_CoachSetupScreenState`** still carry a handful of raw hex-literal colors (mostly single-digit counts per screen) that weren't migrated to `GKColors`. Some of these (hair/eye-color picker swatches, avatar-painter literals) are intentionally-literal art colors and should stay as-is; others are leftover panel/border colors from the old palette and should be repointed in a follow-up pass.
- Full visual verification only covered the Home screen (reviewed in code) and the Dashboard screen (verified live on an iOS Simulator screenshot, iPhone 17). Team Selection, Coach Setup, Contract Signing, Recruiting, Trophy Room, National History, Championship Celebration, and Game Sim were reviewed in code and via their shared-component usage, but not individually screenshotted.
- `GameSimScreen`'s GAMECAST tab now has a field/play-by-play visualization (`_FootballFieldPainter`, `_fieldVisualization()`): a yard-line diagram sketched in the ledger's own ink-on-paper register (`GKCard(paper: true)`), with each team's own colors in the end zones, a brass football marker that animates (`AnimationController`, 750ms `easeOutCubic`) from the drive's start to a synthetic result position after each play. The underlying sim resolves whole drives (touchdown / field goal / turnover / explosive play / punt / three-and-out), not real per-play yardage, so field position is a display-only reconstruction (`_DriveOutcome`, `_animateDriveOnField`) layered on top — it never feeds back into score or turnover logic. This compiled clean (`flutter analyze`) and was reviewed carefully in code, but was not screenshotted live in this session — reaching GameSimScreen requires playing several screens deep into a simulated game, past the reach of the tap-automation available in this environment. Worth a live check before shipping.

## Platform

Cross-platform Flutter (iOS/Android primary; web/macOS/Windows/Linux secondary) — one shared visual identity everywhere, no per-OS HIG/Material conformance (explicit product decision, see `PRODUCT.md`). The web build target does not currently run: `main()` awaits `MobileAds.instance.initialize()` before `runApp()`, and this hangs indefinitely on Flutter web (pre-existing, unrelated to this redesign) — verification used an iOS Simulator instead.
