# Product

<!-- impeccable:product-schema 1 -->

## Platform

adaptive

Cross-platform Flutter, ships both iOS and Android as the primary targets; web/macOS/Windows/Linux are secondary builds of the same code. **One shared visual identity across every platform, by explicit user decision, not per-OS adaptive design.** Do not load `ios.md` / `android.md` native-HIG-conformance guidance for this project: the user declined per-OS component/navigation conformance in favor of a single committed look everywhere. Native *mechanical* guarantees that aren't about visual conformance (safe-area insets, minimum touch target size, honoring Reduce Motion/system back gesture) still apply as baseline usability, not as a native-look mandate.

Primary distribution is mobile app stores (iOS/Android) — `google_mobile_ads` and `in_app_purchase` are integrated and must keep working. Desktop/web builds exist but are secondary.

## Users

Sports-management/dynasty-sim players — comfortable with stats, rosters, and multi-season progression (inferred from the game's mechanics: coach career mode, recruiting, trophy room, CFP bracket; not explicitly confirmed by the user). Sessions range from quick check-ins to long dynasty-building stretches.

## Product Purpose

A college football dynasty/coaching-career simulator built in Flutter (single `lib/main.dart`, ~20k lines). The player takes a coaching job, builds a roster through recruiting, simulates games and seasons, and chases championships and program history over a multi-season career. Confirmed screens/systems: team selection, coach setup, contract signing, dashboard, game simulation, standings, rankings, CFP predictions/bracket, season awards, offseason management, recruiting/mock draft, press conferences, trophy room, national title history, championship celebration.

**Success is explicitly a compulsion loop**: the user's own stated goal is "make it feel addictive, feeling of wanting to play one more" — this is a core, durable product principle, not just a nice-to-have.

## Positioning

An entirely invented college football universe: 128 fictional schools (`lib/main.dart`'s `g5Teams` list) and 8 fictional conferences, each built to evoke a real region/prestige tier without reusing any actual NCAA institution's name (e.g. the SEC → "Southern Crown Conference"). Bowl games and the national championship are also invented ("CFP" → "KP" / "Kingdom Football Playoff", Rose Bowl → "Arroyo Bowl", etc.). School colors and relative competitive tiers were kept close to their real-world counterparts so the game still *feels* like real college football; the names themselves are not real. Individual player/recruit names remain generated separately (`NameGenerator`).

*Correction history: an earlier pass through this document first assumed the universe was fictional (wrong — it originally used 128 real school names/colors/conferences), then corrected to "real NCAA teams" (accurate at the time), and was renamed to a fully invented universe on 2026-07-31 specifically to remove the trademark/licensing exposure real school and conference names created. This section now reflects the current, correct state.*

**2026-07-31 (later same day) — identifiability update, an explicit accepted-risk decision:** the user asked for the fictional schools to be more clearly identifiable as their real-world counterparts, specifically: (1) renamed 33 schools from invented regional nicknames to their real host city/town name (e.g. Ohio State → "Columbus", Alabama → "Tuscaloosa", Texas → "Austin") — city/town names are generic geography, not a school's trademark, so this carries materially less exposure than reusing the school's own name; (2) added a real mascot emoji per team (`CollegeTeam.emoji`, e.g. 🐘 for the Tuscaloosa team, 🐶 for Athens-Clarke) as a visual hint next to the team name. **Point (2) was flagged explicitly before building it**: combining a real host city with that school's real mascot reconstructs much of the "this is obviously [real school]" association the earlier rename was meant to remove — the user chose to proceed with real mascots anyway, an informed call on their own product's risk tolerance, not an oversight. One exception applied unilaterally: schools whose real mascot is a human ethnic/tribal representation (e.g. Chippewas, Utes, Seminoles, Aztecs) got a neutral symbol instead of a literal depiction — that substitution is about not stereotyping a real ethnic group, a different concern from the trademark question the user was deciding, so it wasn't treated as covered by that answer.

## Operating Context

- Mobile-first play session (phone), with desktop/web as secondary builds of the same shared identity.
- Monetized via ads (`AdManager`) and in-app purchases (`PurchaseManager`); ads and purchase flows must remain functional and clearly distinguishable from game content.
- Career progress persists locally (`shared_preferences`); players load/resume saved dynasties (`LoadCareerScreen`).

## Capabilities and Constraints

- Flutter/Dart codebase, currently a single ~20k-line `lib/main.dart`. A visual redesign should not require a functional rewrite; game logic, save data, ad/IAP integration, and existing screens/flows must keep working.
- Existing partial design system in code: `GKColors`, `GKSpace`, `GKRadius`, `GKText`, plus components `GKCard`, `GKPrimaryButton`, `GKSecondaryButton`, `GKSectionHeader`, `GKBackground`, `GKTeamBadge`, `GKStudioMark`. Treated as evidence of the old world, not as constraints the redesign must preserve (see DESIGN.md decision: redesign, not refinement).
- No custom typography currently bundled (system default font only, no `fontFamily`/`google_fonts` dependency). No custom icon set (166 stock Material `Icons.*` glyphs).
- Undecided: whether a custom font requires a new pub dependency (e.g. `google_fonts`) or bundled font assets — to be resolved during the redesign build, not a product-level constraint.

## Brand Commitments

- Studio brand "GameDay Studios" — name and logo (`assets/images/gd_studios_logo.jpeg`, `assets/images/game_day_studios_welcome.jpg`) stay visible as the studio identity. Confirmed binding.
- All school, conference, and bowl/championship names are invented (see Positioning) — this is now a binding constraint, not an open question: future content (new teams, rivalries, awards, flavor text) must not introduce real NCAA institution, conference, or bowl names. Team colors may still approximate real-world schools' colors; only names/branding were the licensing concern.
- Note: renaming broke forward-compatibility with any save files created before 2026-07-31 that reference the old real school names as data keys (team records, rosters, etc.) — pre-existing saves from that era will not resolve correctly against the new names. Given the app was still in early testing (Season 1 saves only, per the Dashboard screenshot reviewed during this work), this was treated as acceptable; revisit if real user saves exist.

## Evidence on Hand

- `assets/images/gd_studios_logo.jpeg` — real studio logo asset.
- `assets/images/game_day_studios_welcome.jpg` — real studio welcome/splash asset.
- No other real screenshots, marketing copy, or press material on hand.

## Product Principles

1. **Chase "one more."** Every screen should pull the player toward the next game/season, not just look good in isolation — this is the user's explicit definition of success.
2. **The universe is real, even though it's fictional.** Never let generated teams/players read as placeholder or fake; the illusion of a real college football world must hold.
3. **One identity, every platform.** No per-OS reskinning — the game looks and feels the same on phone, desktop, and web, by explicit user decision.
4. **Monetization stays outside the fantasy.** Ads and purchase flows must be clearly separated from game/broadcast content so they don't puncture the dynasty illusion.
5. **Depth survives a redesign.** The management-sim depth (rosters, contracts, recruiting, standings) is the product; visual work must clarify that depth, not simplify it away.

## Accessibility & Inclusion

No product-specific requirement established yet.
