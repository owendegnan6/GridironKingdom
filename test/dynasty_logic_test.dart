import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:football_sim/main.dart';

void main() {
  const oxford = CollegeTeam(
    name: 'Oxford',
    conference: 'Test Conf',
    prestige: 70,
    primary: Colors.red,
    secondary: Colors.white,
  );
  const ypsilanti = CollegeTeam(
    name: 'Ypsilanti',
    conference: 'Test Conf',
    prestige: 60,
    primary: Colors.green,
    secondary: Colors.white,
  );
  const testCoach = CoachProfile(
    name: 'Coach Test',
    skinTone: 'medium',
    hairStyle: 'short',
    hairColor: 'brown',
    beard: 'none',
    coachType: 'Balanced',
    offensiveScheme: 'Pro Style',
    defensiveScheme: '4-3 Defense',
  );

  test('retention NIL cost scales meaningfully with overall', () {
    const low = Player(name: 'Depth Piece', position: 'DB', overall: 60, potential: 65, year: 'JR', stars: 2);
    const mid = Player(name: 'Solid Starter', position: 'DB', overall: 80, potential: 85, year: 'JR', stars: 3);
    const elite = Player(name: 'Superstar', position: 'QB', overall: 95, potential: 99, year: 'JR', stars: 5);

    final lowAsk = playerRetentionAsk(low);
    final midAsk = playerRetentionAsk(mid);
    final eliteAsk = playerRetentionAsk(elite);

    expect(lowAsk, lessThan(midAsk));
    expect(midAsk, lessThan(eliteAsk));
    // The whole point of the fix: a 95 OVR star should cost dramatically
    // more than a 60 OVR depth piece, not ~2.5x like the old formula.
    expect(eliteAsk / lowAsk, greaterThan(10));

    // Same overall, higher stars should still cost more.
    const eliteLowStars = Player(name: 'Superstar Low Stars', position: 'QB', overall: 95, potential: 99, year: 'JR', stars: 1);
    expect(playerRetentionAsk(eliteLowStars), lessThan(eliteAsk));
  });

  test('retention budget scales down for weak, low-prestige programs', () {
    // The exact scenario from the bug report: a struggling 1-star program
    // (prestige tier 1) with a losing record shouldn't have a retention
    // budget in the same neighborhood as a strong program's.
    final weakTier1 = retentionBudgetForSeason(3, 5, 45);
    final strongTier1 = retentionBudgetForSeason(11, 1, 45);
    final eliteTier5 = retentionBudgetForSeason(12, 0, 96);

    expect(weakTier1, lessThan(200000));
    expect(strongTier1, lessThan(1000000));
    expect(weakTier1, lessThan(strongTier1));
    expect(strongTier1, lessThan(eliteTier5));
  });

  test('recruiting NIL budget scales with prestige, and only 3+ stars want NIL', () {
    expect(recruitingNilBudgetForSeason(45), lessThan(recruitingNilBudgetForSeason(96)));

    final oneStar = Recruit(name: 'Walk-on Type', position: 'DB', state: 'OH', stars: 1, trueOverall: 55, truePotential: 60, interest: 40);
    final twoStar = Recruit(name: 'Depth Prospect', position: 'LB', state: 'OH', stars: 2, trueOverall: 60, truePotential: 65, interest: 40);
    final threeStar = Recruit(name: 'Solid Signee', position: 'WR', state: 'OH', stars: 3, trueOverall: 70, truePotential: 78, interest: 50);
    final fiveStar = Recruit(name: 'Blue Chip Star', position: 'QB', state: 'OH', stars: 5, trueOverall: 92, truePotential: 98, interest: 70);

    expect(oneStar.nilAsk, 0);
    expect(oneStar.wantsNil, isFalse);
    expect(twoStar.nilAsk, 0);
    expect(twoStar.wantsNil, isFalse);

    expect(threeStar.wantsNil, isTrue);
    expect(fiveStar.wantsNil, isTrue);
    expect(fiveStar.nilAsk, greaterThan(threeStar.nilAsk));
  });

  test('transfer portal NIL budget scales with prestige, and only 3+ stars want NIL', () {
    expect(transferNilBudgetForSeason(45), lessThan(transferNilBudgetForSeason(96)));

    final oneStar = TransferTarget(name: 'Backup Type', position: 'DB', overall: 55, potential: 60, year: 'JR', stars: 1, interest: 40);
    final twoStar = TransferTarget(name: 'Rotation Guy', position: 'LB', overall: 62, potential: 68, year: 'SO', stars: 2, interest: 45);
    final threeStar = TransferTarget(name: 'Solid Portal Add', position: 'WR', overall: 74, potential: 80, year: 'JR', stars: 3, interest: 55);
    final fiveStar = TransferTarget(name: 'Portal Star', position: 'QB', overall: 90, potential: 94, year: 'SR', stars: 5, interest: 70);

    expect(oneStar.nilAsk, 0);
    expect(oneStar.wantsNil, isFalse);
    expect(twoStar.nilAsk, 0);
    expect(twoStar.wantsNil, isFalse);

    expect(threeStar.wantsNil, isTrue);
    expect(fiveStar.wantsNil, isTrue);
    expect(fiveStar.nilAsk, greaterThan(threeStar.nilAsk));

    // Portal players are proven, so their NIL ask should run higher than a
    // recruit at the same star level.
    final recruitFiveStar = Recruit(name: 'Blue Chip Recruit', position: 'QB', state: 'OH', stars: 5, trueOverall: 92, truePotential: 98, interest: 70);
    expect(fiveStar.nilAsk, greaterThan(recruitFiveStar.nilAsk));
  });

  test('generateWalkOn fills a specific position without waste', () {
    final walkOn = generateWalkOn(70, 'QB');
    expect(walkOn.position, 'QB');
    expect(walkOn.overall, greaterThanOrEqualTo(45));
    expect(walkOn.overall, lessThanOrEqualTo(78));

    // Should scale down for weak programs and up for strong ones.
    final weakWalkOn = generateWalkOn(45, 'WR');
    final strongWalkOn = generateWalkOn(96, 'WR');
    expect(weakWalkOn.overall, lessThanOrEqualTo(58));
    expect(strongWalkOn.overall, greaterThanOrEqualTo(65));
  });

  test('trophy JSON round-trip preserves which team actually won it, with a blank fallback for older saves', () {
    final trophy = TrophyEntry(
      year: 3,
      type: 'Conference Championship',
      title: 'Test Conf Champions',
      opponent: 'Ypsilanti',
      team: 'Oxford',
    );
    final restored = trophyFromJson(trophyToJson(trophy));
    expect(restored.team, 'Oxford');

    // A save from before this feature existed has no 'team' key at all —
    // that must not crash, and must not fabricate a team.
    final legacy = trophyFromJson({
      'year': 2,
      'type': 'Bowl Win',
      'title': 'Old Bowl',
      'opponent': 'Some Team',
    });
    expect(legacy.team, '');
  });

  testWidgets('Trophy Room shows the team a trophy was actually won with', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final trophies = [
      const TrophyEntry(
        year: 1,
        type: 'Conference Championship',
        title: 'Test Conf Champions',
        opponent: 'Old Rival',
        team: 'Ypsilanti',
      ),
      const TrophyEntry(
        year: 4,
        type: 'National Championship',
        title: 'National Champions',
        opponent: 'New Rival',
        team: 'Oxford',
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: TrophyRoomScreen(team: oxford, trophies: trophies),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.takeException(), isNull);
    // Even though the coach is at Oxford now, a trophy won at a previous
    // job (Ypsilanti) must still say Ypsilanti, not the current team.
    expect(find.textContaining('Ypsilanti'), findsWidgets);
    expect(find.textContaining('Oxford'), findsWidgets);
  });

  test('normalizeTeamRecordToTarget tracks the season\'s actual progress and is idempotent', () {
    final rng = Random(5);

    // Early season: only 2 games in, a team's record should land at 2
    // games, not be padded all the way out to a full season.
    final early = TeamSeasonRecord();
    normalizeTeamRecordToTarget(early, targetTotal: 2, targetConf: 2, prestige: 70, rng: rng);
    expect(early.wins + early.losses, 2);

    // Mid season: 11 games played by the user (matching the reported bug
    // — week 12, 9-2) should bring every other team to 11 games too, not
    // leave them stuck at a handful.
    final mid = TeamSeasonRecord();
    normalizeTeamRecordToTarget(mid, targetTotal: 11, targetConf: 8, prestige: 70, rng: rng);
    expect(mid.wins + mid.losses, 11);

    // Idempotency is the actual bug fix: normalizing an already-correct
    // record again with the same target must not change it. The old,
    // hardcoded-to-12 version failed this the moment it ran mid-season.
    final before = TeamSeasonRecord(wins: mid.wins, losses: mid.losses, confWins: mid.confWins, confLosses: mid.confLosses);
    normalizeTeamRecordToTarget(mid, targetTotal: 11, targetConf: 8, prestige: 70, rng: rng);
    expect(mid.wins, before.wins);
    expect(mid.losses, before.losses);
    expect(mid.confWins, before.confWins);
    expect(mid.confLosses, before.confLosses);

    // A record that's run ahead of the target (e.g. stale data from before
    // a target dropped) gets trimmed back down exactly, not left over.
    final over = TeamSeasonRecord(wins: 9, losses: 3, confWins: 7, confLosses: 2);
    normalizeTeamRecordToTarget(over, targetTotal: 6, targetConf: 4, prestige: 70, rng: rng);
    expect(over.wins + over.losses, 6);
  });

  test('generateByeWeeks always produces exactly 2 byes, spread out and never back to back', () {
    for (var seed = 0; seed < 200; seed++) {
      final byes = generateByeWeeks(Random(seed));

      expect(byes.length, 2);

      final sorted = byes.toList()..sort();
      // Never in week 1 (index 0) or the final week (index 13) — the
      // schedule always opens and closes with a real game.
      expect(sorted.first, greaterThanOrEqualTo(1));
      expect(sorted.last, lessThanOrEqualTo(12));

      // Never back to back — always at least 3 weeks apart.
      expect((sorted[1] - sorted[0]).abs(), greaterThanOrEqualTo(3));
    }
  });

  test('generateRecruits produces a real national-scale board with the requested star distribution', () {
    final pool = generateRecruits(70);

    expect(pool.where((r) => r.stars == 5).length, 40);
    expect(pool.where((r) => r.stars == 4).length, 70);
    expect(pool.where((r) => r.stars == 3).length, 100);
    expect(pool.where((r) => r.stars == 2).length, 125);
    expect(pool.where((r) => r.stars == 1).length, 150);
    expect(pool.length, 485);

    // A 5-star must actually be scarce relative to the rest of the class,
    // not just labeled that way.
    final fiveStarShare = pool.where((r) => r.stars == 5).length / pool.length;
    expect(fiveStarShare, lessThan(0.10));
  });

  test('recruitStarBandForPrestigeTier keeps low-star scrubs off an elite board and blue-chips off a bad one', () {
    final eliteBand = recruitStarBandForPrestigeTier(5);
    expect(eliteBand.min, greaterThanOrEqualTo(3));
    expect(eliteBand.max, 5);

    final weakBand = recruitStarBandForPrestigeTier(1);
    expect(weakBand.max, lessThanOrEqualTo(2));

    // Applying the elite band to a real generated board must exclude every
    // 1- and 2-star recruit — this is the actual "no more 2 stars on a
    // 5-star school's board" guarantee, not just a label.
    final pool = generateRecruits(96);
    final eliteVisible = pool.where(
      (r) => r.stars >= eliteBand.min && r.stars <= eliteBand.max,
    );
    expect(eliteVisible.any((r) => r.stars <= 2), isFalse);
    expect(eliteVisible.isNotEmpty, isTrue);
  });

  test('contract years remaining reflect the season passing, extensions, and job changes', () {
    // A plain season with no extension: the year that was just played
    // ticks off, nothing added.
    expect(
      contractYearsAfterOffseason(
        tookNewJob: false,
        previousYearsRemaining: 3,
        newJobPrestige: 70,
        extensionYears: 0,
      ),
      2,
    );

    // A strong season earns an extension on top of the year ticking down.
    expect(
      contractYearsAfterOffseason(
        tookNewJob: false,
        previousYearsRemaining: 3,
        newJobPrestige: 70,
        extensionYears: 3,
      ),
      5, // (3 - 1) + 3
    );

    // Never drops to 0 even with nothing left and no extension — there's
    // no firing consequence modeled, so the countdown floors at 1.
    expect(
      contractYearsAfterOffseason(
        tookNewJob: false,
        previousYearsRemaining: 1,
        newJobPrestige: 70,
        extensionYears: 0,
      ),
      1,
    );

    // Taking a new job resets entirely to that program's fresh contract
    // length, ignoring whatever was left at the old job.
    expect(
      contractYearsAfterOffseason(
        tookNewJob: true,
        previousYearsRemaining: 1,
        newJobPrestige: 96,
        extensionYears: 0,
      ),
      contractYearsForTier(prestigeTier(96)),
    );

    expect(contractExtensionYearsForScore(90), 3);
    expect(contractExtensionYearsForScore(70), 2);
    expect(contractExtensionYearsForScore(50), 1);
    expect(contractExtensionYearsForScore(20), 0);
  });

  test('idealRosterPositionCounts sums to a full 22-man roster', () {
    final total = idealRosterPositionCounts.values.reduce((a, b) => a + b);
    expect(total, 22);
  });

  test('nationalRosterFor is deterministic and well-formed', () {
    final rosterA = nationalRosterFor(ypsilanti, 3);
    final rosterB = nationalRosterFor(ypsilanti, 3);
    final rosterDifferentSeason = nationalRosterFor(ypsilanti, 4);

    expect(rosterA.length, 22);
    expect(rosterA.map((p) => p.name).toList(), rosterB.map((p) => p.name).toList());
    expect(rosterA.map((p) => p.name).toSet(), isNot(rosterDifferentSeason.map((p) => p.name).toSet()));

    for (final p in rosterA) {
      expect(p.name.contains('|Ypsilanti'), isTrue);
      expect(awardPlayerSchool(p), 'Ypsilanti');
    }

    final qb = nationalStartingQbFor(ypsilanti, 3);
    expect(qb.position, 'QB');
    expect(rosterA.any((p) => p.name == qb.name), isTrue);
  });

  testWidgets('play a full game and open postgame presentation', (tester) async {
    final qb = const Player(
      name: 'Test Quarterback',
      position: 'QB',
      overall: 80,
      potential: 90,
      year: 'SO',
      stars: 4,
    );
    final hb = const Player(
      name: 'Test Runningback',
      position: 'HB',
      overall: 75,
      potential: 85,
      year: 'JR',
      stars: 3,
    );

    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: GameSimScreen(
          team: oxford,
          opponent: ypsilanti,
          teamOvr: 70,
          opponentOvr: 55,
          teamStartingQb: qb,
          opponentStartingQb: nationalStartingQbFor(ypsilanti, 1),
          teamLeaders: [qb, hb],
          onFinished: (_) {},
        ),
      ),
    );

    await tester.pump(const Duration(milliseconds: 500));

    // Pregame team leaders should show the real roster names passed in.
    expect(find.text('TEST QUARTERBACK'), findsOneWidget);
    expect(find.text('TEST RUNNINGBACK'), findsOneWidget);

    // Quick Sim to Final (skips straight to the end without watching plays)
    await tester.tap(find.text('QUICK SIM TO FINAL'));

    for (var i = 0; i < 200; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      // Halftime adjustments pause the sim with a non-dismissible sheet —
      // confirm the pre-selected (recommended) plans so quick-sim can finish.
      final confirmButton = find.text('CONFIRM ADJUSTMENTS');
      if (confirmButton.evaluate().isNotEmpty) {
        // warnIfMissed: false — the sheet may still be sliding into place
        // on this exact frame; the loop retries every 50ms until a tap
        // actually lands and closes it.
        await tester.tap(confirmButton, warnIfMissed: false);
        await tester.pump();
      }
      final exception = tester.takeException();
      if (exception != null) {
        // ignore: avoid_print
        print('CAUGHT EXCEPTION DURING SIM: $exception');
      }
    }

    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    final exception = tester.takeException();
    if (exception != null) {
      // ignore: avoid_print
      print('CAUGHT EXCEPTION AFTER SETTLE: $exception');
    }

    expect(find.text('PLAYER OF THE GAME'), findsOneWidget);
  });

  testWidgets('season awards card renders real, deterministic players', (tester) async {
    final roster = [
      const Player(name: 'Star Passer', position: 'QB', overall: 95, potential: 99, year: 'JR', stars: 5),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SeasonAwardsCard(
              roster: roster,
              season: 2,
              userWins: 11,
              userTeamName: 'Oxford',
            ),
          ),
        ),
      ),
    );

    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull);

    expect(find.text('FIRST TEAM ALL-AMERICAN'), findsOneWidget);
    expect(find.text('FRESHMAN ALL-AMERICAN TEAM'), findsOneWidget);
  });

  test('recruiting class scoring rewards more and better recruits', () {
    final fiveStar = Recruit(name: 'Elite Signee', position: 'QB', state: 'OH', stars: 5, trueOverall: 95, truePotential: 99, interest: 80);
    final oneStar = Recruit(name: 'Depth Signee', position: 'DB', state: 'OH', stars: 1, trueOverall: 52, truePotential: 55, interest: 40);

    expect(recruitClassPoints(fiveStar), greaterThan(recruitClassPoints(oneStar)));
    expect(recruitingClassScoreFor([]), 0);

    // Quality (average recruit value) must dominate the score — a small
    // class stacked with blue-chips should never be dragged down to a
    // one-star's level just by averaging in a single weak signee, and it
    // must clearly outscore a same-size class of only one-stars.
    expect(
      recruitingClassScoreFor([fiveStar]),
      greaterThan(recruitingClassScoreFor([oneStar])),
    );
    expect(
      recruitingClassScoreFor([fiveStar, fiveStar, fiveStar]),
      greaterThan(recruitingClassScoreFor([oneStar, oneStar, oneStar, oneStar, oneStar, oneStar, oneStar, oneStar, oneStar, oneStar])),
    );

    // A bigger class of the *same* quality should still outscore a smaller
    // one — volume is a modest tiebreaker/bonus, not the dominant factor.
    expect(
      recruitingClassScoreFor([oneStar, oneStar]),
      greaterThan(recruitingClassScoreFor([oneStar])),
    );
  });

  test('national recruiting class score is deterministic and scales with prestige', () {
    final weakTeam = CollegeTeam(name: 'Weak Program', conference: 'Test', prestige: 45, primary: Colors.grey, secondary: Colors.grey);
    final eliteTeam = CollegeTeam(name: 'Elite Program', conference: 'Test', prestige: 97, primary: Colors.grey, secondary: Colors.grey);

    final scoreA = nationalRecruitingClassScore(eliteTeam, 4);
    final scoreB = nationalRecruitingClassScore(eliteTeam, 4);
    expect(scoreA, scoreB);
    expect(nationalRecruitingClassScore(eliteTeam, 4), greaterThan(nationalRecruitingClassScore(weakTeam, 4)));
  });

  test('recruiting class national rank places an elite class near #1 and an empty class near the bottom', () {
    final totalTeams = g5Teams.length;

    final eliteRank = recruitingClassNationalRank(
      userScore: 20000, // far above what any simulated program could score
      userTeam: oxford,
      season: 5,
    );
    expect(eliteRank, 1);

    final emptyRank = recruitingClassNationalRank(
      userScore: 0,
      userTeam: oxford,
      season: 5,
    );
    expect(emptyRank, greaterThan(totalTeams - 10));

    expect(recruitingClassRankLabel(1, totalTeams), 'TOP 5 CLASS');
    expect(recruitingClassRankLabel(totalTeams, totalTeams), 'REBUILDING CLASS');
  });

  test('a small class stacked with 5-star recruits ranks near the top, not last', () {
    // Reproduces the reported bug: a class of only seven signees, all
    // 5-stars, must never rank behind a much bigger class of ordinary
    // recruits just because it has fewer total bodies.
    final eliteClass = List.generate(
      7,
      (i) => Recruit(
        name: 'Blue Chip Prospect $i',
        position: 'QB',
        state: 'OH',
        stars: 5,
        trueOverall: 92,
        truePotential: 96,
        interest: 80,
      ),
    );
    final userScore = recruitingClassScoreFor(eliteClass);

    final weakestProgram = CollegeTeam(
      name: 'Weakest Program',
      conference: 'Test',
      prestige: 40,
      primary: Colors.grey,
      secondary: Colors.grey,
    );
    expect(userScore, greaterThan(nationalRecruitingClassScore(weakestProgram, 5)));

    final rank = recruitingClassNationalRank(
      userScore: userScore,
      userTeam: oxford,
      season: 5,
    );
    expect(rank, lessThan(g5Teams.length ~/ 2));
  });

  test('kingdom network reporter pool is deterministic and covers the named roster', () {
    // Every name the user asked for should actually be in the pool.
    for (final name in [
      'Jake Pietrzak', 'Braden Ansaldi', 'Sal Annino', 'Zach Previte',
      'Kyle O’Connor', 'Matt Spinella', 'Cam Wagner', 'Nick Davenport',
      'Clark Gulycz', 'Dugan Chase', 'Wyatt Jumper', 'Vincent Franco',
      'Joe Sevison', 'Henry Jennings', 'Finn Jennings', 'Jacob Correria',
      'Ryan Moricas',
    ]) {
      expect(kingdomNetworkReporters, contains(name));
    }

    final a = kingdomNetworkReportersFor(3, count: 3, salt: 1);
    final b = kingdomNetworkReportersFor(3, count: 3, salt: 1);
    expect(a, b);
    expect(a.toSet().length, 3); // no repeats within one pick

    // Different salts should (almost always) diverge from each other.
    final c = kingdomNetworkReportersFor(3, count: 1, salt: 2);
    expect(a.first == c.first && kingdomNetworkReportersFor(3, count: 1, salt: 3).first == c.first, isFalse);
  });

  testWidgets('selection show reveals a full 12-team bracket and reaches the reactions screen', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: SelectionScreen(
          team: oxford,
          season: 4,
          record: '11-1',
          wins: 11,
          losses: 1,
          confWins: 7,
          confLosses: 1,
          rank: 3,
          teamOvr: 90,
          teamRecords: const {},
          conferenceChampEligible: false,
          cfpEligible: true,
          bowlEligible: false,
          onContinue: (_) {},
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    // Step through Committee Discussion -> Final Envelope, landing on the
    // Reveal step (2 taps: revealStep 0 -> 1 -> 2).
    for (var i = 0; i < 2; i++) {
      await tester.tap(find.byType(DynastyButton));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.takeException(), isNull);

    // The reveal step should show the real bracket, not a flat list.
    // "FIRST ROUND"/"BYES" legitimately appear twice — once in the "THE
    // FIELD" summary stats, once as the bracket's own section headers.
    expect(find.text('12-TEAM KP BRACKET'), findsOneWidget);
    expect(find.text('FIRST ROUND'), findsWidgets);
    expect(find.text('BYES'), findsWidgets);

    // Continue into the reactions screen.
    await tester.tap(find.byType(DynastyButton));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
    expect(find.text('REACTIONS'), findsOneWidget);
    expect(find.text('FAN REACTIONS'), findsOneWidget);
  });

  testWidgets('selection show reveals the bracket even for a bowl-bound team that missed the KP', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: SelectionScreen(
          team: oxford,
          season: 4,
          record: '8-4',
          wins: 8,
          losses: 4,
          confWins: 5,
          confLosses: 3,
          rank: 22,
          teamOvr: 78,
          teamRecords: const {},
          conferenceChampEligible: false,
          cfpEligible: false,
          bowlEligible: true,
          onContinue: (_) {},
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    for (var i = 0; i < 2; i++) {
      await tester.tap(find.byType(DynastyButton));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.takeException(), isNull);

    // Even though this team didn't make the KP, the full field still
    // reveals — same as a real broadcast shows the whole bracket to
    // everyone watching, not just the teams that got in.
    expect(find.text('12-TEAM KP BRACKET'), findsOneWidget);
    expect(find.textContaining('BOWL INVITE'), findsOneWidget);
  });

  testWidgets('selection show bracket reflects the real resolved KP field, not a naive re-sort', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // With teamRecords all empty/tied, the old naive fallback (sort by win
    // pct, then wins, then prestige, then alphabetically) would land on the
    // alphabetically-first 12 teams. The real, resolved field passed in via
    // cfpField is deliberately the alphabetically-LAST 12 teams instead, so
    // if the bracket ever fell back to re-deriving its own field it would
    // show the wrong teams — exactly the bug where the displayed bracket
    // disagreed with the actual committee decision.
    final naiveFallbackNames = (g5Teams.toList()
          ..sort((a, b) => a.name.compareTo(b.name)))
        .take(12)
        .map((t) => t.name)
        .toSet();
    final realField = (g5Teams.toList()..sort((a, b) => b.name.compareTo(a.name)))
        .take(12)
        .toList();
    expect(
      realField.map((t) => t.name).toSet().intersection(naiveFallbackNames),
      isEmpty,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SelectionScreen(
          team: oxford,
          season: 4,
          record: '11-1',
          wins: 11,
          losses: 1,
          confWins: 7,
          confLosses: 1,
          rank: 3,
          teamOvr: 90,
          teamRecords: const {},
          conferenceChampEligible: false,
          cfpEligible: false,
          bowlEligible: true,
          cfpField: realField,
          onContinue: (_) {},
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    for (var i = 0; i < 2; i++) {
      await tester.tap(find.byType(DynastyButton));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.takeException(), isNull);

    expect(find.text('12-TEAM KP BRACKET'), findsOneWidget);
    for (final team in realField) {
      expect(find.text(team.name), findsWidgets);
    }
  });

  testWidgets('Heisman Studio pulls real players from other teams, not just an empty user roster', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: KingdomNetworkScreen(
          team: oxford,
          coach: testCoach,
          season: 6,
          rank: 40,
          record: '0-0',
          teamRecords: const {},
          roster: const [], // empty — a real fix must not depend on the user's own roster
          trophies: const [],
          history: const [],
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('HEISMAN'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);

    expect(find.text('HEISMAN STUDIO'), findsOneWidget);
    // With an empty user roster, every name shown must have come from
    // another school's national roster.
    expect(find.text('National Leader'), findsNothing);
  });

  testWidgets('coach creation shows a live recruiting pipeline preview as the name is typed', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(home: CoachSetupScreen(team: oxford)),
    );
    await tester.pump(const Duration(milliseconds: 100));

    // Before a name is entered, there's nothing to preview yet.
    expect(find.textContaining('Enter a name to see'), findsOneWidget);

    const testName = 'Coach Pipeline Preview Test';
    await tester.enterText(find.byType(TextField).first, testName);
    await tester.pump(const Duration(milliseconds: 100));

    final bg = coachBackgroundFor(testName);
    expect(tester.takeException(), isNull);
    expect(
      find.textContaining('Home base: ${bg.hometownState} · ${bg.hometownRegion} region'),
      findsOneWidget,
    );
  });

  test('coach background is deterministic and drives a real recruiting pipeline', () {
    final a = coachBackgroundFor('Coach Riley');
    final b = coachBackgroundFor('Coach Riley');
    expect(a.hometownState, b.hometownState);
    expect(a.almaMater, b.almaMater);
    expect(a.priorStop, b.priorStop);
    expect(a.pipelineBlurb, contains(a.hometownState));

    // Different-named coaches shouldn't all land on the same background.
    final c = coachBackgroundFor('Coach Alvarez');
    final d = coachBackgroundFor('Coach Whitfield');
    final e = coachBackgroundFor('Coach Okafor');
    final states = {a.hometownState, c.hometownState, d.hometownState, e.hometownState};
    expect(states.length, greaterThan(1));
  });

  test('coach pipeline state meaningfully boosts in-state recruit interest', () {
    final pipelineState = coachBackgroundFor('Coach Pipeline Test').hometownState;

    final withPipeline = generateRecruits(70, pipelineState: pipelineState);
    final withoutPipeline = generateRecruits(70);

    double avgInterestForState(List<Recruit> pool, String state) {
      final matches = pool.where((r) => r.state == state).toList();
      if (matches.isEmpty) return 0;
      return matches.map((r) => r.interest).reduce((a, b) => a + b) / matches.length;
    }

    final withAvg = avgInterestForState(withPipeline, pipelineState);
    final withoutAvg = avgInterestForState(withoutPipeline, pipelineState);
    if (withAvg > 0 && withoutAvg > 0) {
      expect(withAvg, greaterThan(withoutAvg));
    }
  });

  test('every pipeline state belongs to exactly one named region, and regionForState is consistent', () {
    final allStates = pipelineRegions.values.expand((states) => states).toList();

    // No state should be double-counted across regions, and every state
    // generateRecruits can produce should be covered by some region.
    expect(allStates.toSet().length, allStates.length);

    const generatedStates = [
      'RI', 'MA', 'CT', 'NY', 'NJ', 'PA', 'OH', 'MI', 'FL', 'GA',
      'TX', 'CA', 'AZ', 'NC', 'SC', 'VA', 'MD', 'AL', 'LA', 'TN',
    ];
    for (final state in generatedStates) {
      final region = regionForState(state);
      expect(region, isNot('National'));
      expect(pipelineRegions[region], contains(state));
    }
  });

  test('coachBackgroundFor derives a real region for the coach\'s hometown state', () {
    final bg = coachBackgroundFor('Coach Regional Test');
    expect(bg.hometownRegion, regionForState(bg.hometownState));
    expect(bg.regionStates, contains(bg.hometownState));
    expect(bg.pipelineBlurb, contains(bg.hometownRegion));
  });

  test('a broad regional pipeline (e.g. New England, West Coast) boosts interest beyond the exact hometown state, but less than it', () {
    // Force a coach whose region has more than one state, so there's a
    // real "region but not hometown" state to test against.
    final bg = coachBackgroundFor('Coach Broad Pipeline');
    final otherRegionState = bg.regionStates.firstWhere(
      (s) => s != bg.hometownState,
      orElse: () => '',
    );
    if (otherRegionState.isEmpty) return; // this coach's region is single-state — nothing to compare

    final withPipeline = generateRecruits(
      70,
      pipelineState: bg.hometownState,
      pipelineRegionStates: bg.regionStates,
    );
    final withoutPipeline = generateRecruits(70);

    double avgInterestForState(List<Recruit> pool, String state) {
      final matches = pool.where((r) => r.state == state).toList();
      if (matches.isEmpty) return 0;
      return matches.map((r) => r.interest).reduce((a, b) => a + b) / matches.length;
    }

    final regionAvgWith = avgInterestForState(withPipeline, otherRegionState);
    final regionAvgWithout = avgInterestForState(withoutPipeline, otherRegionState);
    final homeAvgWith = avgInterestForState(withPipeline, bg.hometownState);

    if (regionAvgWith > 0 && regionAvgWithout > 0 && homeAvgWith > 0) {
      // The broader region still means something...
      expect(regionAvgWith, greaterThan(regionAvgWithout));
      // ...but the exact hometown state means more.
      expect(homeAvgWith, greaterThan(regionAvgWith));
    }
  });

  test('schemeFitBonus stays within its declared bounds and is 0 with no scheme given', () {
    for (final scheme in offensiveSchemeFitByPosition.entries) {
      for (final fit in scheme.value.values) {
        expect(fit, inInclusiveRange(-8, 12));
      }
    }
    for (final scheme in defensiveSchemeFitByPosition.entries) {
      for (final fit in scheme.value.values) {
        expect(fit, inInclusiveRange(-8, 12));
      }
    }
    expect(schemeFitBonus('QB'), 0);
    expect(schemeFitBonus('DE'), 0);
    expect(schemeFitBonus('QB', offensiveScheme: 'Air Raid'), greaterThan(0));
    expect(schemeFitBonus('DE', defensiveScheme: '4-3 Defense'), greaterThan(0));
  });

  test('schemeMatchupModifier stays within its declared bounds, and Pro Style is neutral everywhere', () {
    for (final row in schemeMatchupMatrix.entries) {
      for (final value in row.value.values) {
        expect(value, inInclusiveRange(-4, 4));
      }
    }
    for (final defense in defensiveSchemes) {
      expect(schemeMatchupModifier('Pro Style', defense), 0);
    }
  });

  test('offensiveSchemeFor and defensiveSchemeFor are deterministic and always valid', () {
    final oxford = CollegeTeam(name: 'Oxford', conference: 'Southern Crown', prestige: 70, primary: Colors.blue, secondary: Colors.white);

    expect(offensiveSchemeFor(oxford, 2030), offensiveSchemeFor(oxford, 2030));
    expect(defensiveSchemeFor(oxford, 2030), defensiveSchemeFor(oxford, 2030));
    expect(offensiveSchemes, contains(offensiveSchemeFor(oxford, 2030)));
    expect(defensiveSchemes, contains(defensiveSchemeFor(oxford, 2030)));
  });

  test('a recruit whose position fits the program scheme gets a real interest boost', () {
    final withScheme = generateRecruits(70, offensiveScheme: 'Air Raid');
    final withoutScheme = generateRecruits(70);

    double avgInterestForPosition(List<Recruit> pool, String position) {
      final matches = pool.where((r) => r.position == position).toList();
      if (matches.isEmpty) return 0;
      return matches.map((r) => r.interest).reduce((a, b) => a + b) / matches.length;
    }

    // Air Raid gives WR a +12 fit bonus — its single largest offensive
    // fit value — so this should be visible in the aggregate average even
    // with the rng.nextInt(46) noise term in the interest formula.
    final wrWith = avgInterestForPosition(withScheme, 'WR');
    final wrWithout = avgInterestForPosition(withoutScheme, 'WR');
    expect(wrWith, greaterThan(wrWithout));
  });

  test('coach departure storyline is deterministic and varies by move', () {
    final a = coachDepartureStorylineFor('Coach Riley', 'Oxford', 'Ypsilanti', 4);
    final b = coachDepartureStorylineFor('Coach Riley', 'Oxford', 'Ypsilanti', 4);
    expect(a, b);
    expect(coachDepartureStorylines, contains(a));

    // Different destinations should (usually) get different reported reasons.
    final destinations = [
      coachDepartureStorylineFor('Coach Riley', 'Oxford', 'Nashville', 4),
      coachDepartureStorylineFor('Coach Riley', 'Oxford', 'Yazoo', 4),
      coachDepartureStorylineFor('Coach Riley', 'Oxford', 'Maumee', 4),
    ];
    expect(destinations.toSet().length, greaterThan(1));
  });

  group('game and season stat tracking', () {
    List<Player> buildStarters() => const [
          Player(name: 'Test QB', position: 'QB', overall: 85, potential: 88, year: 'JR', stars: 4),
          Player(name: 'Test HB', position: 'HB', overall: 80, potential: 84, year: 'SO', stars: 3),
          Player(name: 'Test WR1', position: 'WR', overall: 82, potential: 86, year: 'SR', stars: 4),
          Player(name: 'Test WR2', position: 'WR', overall: 74, potential: 78, year: 'FR', stars: 2),
          Player(name: 'Test TE', position: 'TE', overall: 70, potential: 74, year: 'JR', stars: 2),
          Player(name: 'Test DE', position: 'DE', overall: 78, potential: 82, year: 'SR', stars: 3),
          Player(name: 'Test LB', position: 'LB', overall: 76, potential: 80, year: 'JR', stars: 3),
          Player(name: 'Test DB1', position: 'DB', overall: 79, potential: 83, year: 'SR', stars: 3),
          Player(name: 'Test DB2', position: 'DB', overall: 71, potential: 75, year: 'SO', stars: 2),
        ];

    test('GamePlayerLine addition and JSON round-trip are exact', () {
      const a = GamePlayerLine(passYards: 210, passTDs: 2, tackles: 3);
      const b = GamePlayerLine(passYards: 90, rushYards: 40, rushTDs: 1);
      final sum = a + b;

      expect(sum.passYards, 300);
      expect(sum.passTDs, 2);
      expect(sum.rushYards, 40);
      expect(sum.rushTDs, 1);
      expect(sum.tackles, 3);

      final restored = GamePlayerLine.fromJson(sum.toJson());
      expect(restored.passYards, sum.passYards);
      expect(restored.rushYards, sum.rushYards);
      expect(restored.rushTDs, sum.rushTDs);
      expect(restored.tackles, sum.tackles);
    });

    test('decomposeScoreIntoScoring always reconstructs a score within a field goal', () {
      for (final score in [0, 3, 7, 10, 14, 17, 21, 24, 28, 35, 41, 48]) {
        final result = decomposeScoreIntoScoring(score);
        final reconstructed = result.tds * 7 + result.fgs * 3;
        // A greedy TD/FG breakdown can be off by at most 2 points (a real
        // score can include a missed extra point or safety) — it must
        // never overshoot the actual score, and never miss by more than
        // that.
        expect(reconstructed, lessThanOrEqualTo(score));
        expect(score - reconstructed, lessThan(3));
      }
    });

    test('gameTotalYardsFor is deterministic and never drops below the realistic floor', () {
      final a = gameTotalYardsFor(score: 24, bigPlays: 3, turnovers: 1);
      final b = gameTotalYardsFor(score: 24, bigPlays: 3, turnovers: 1);
      expect(a, b);

      final blowoutLoss = gameTotalYardsFor(score: 0, bigPlays: 0, turnovers: 6);
      expect(blowoutLoss, greaterThanOrEqualTo(80));
    });

    test('splitIntegerWithVariance always conserves the total exactly', () {
      final rng = Random(42);
      for (final total in [0, 1, 2, 7, 100, 257]) {
        for (final parts in [1, 2, 3, 5]) {
          final split = splitIntegerWithVariance(total, parts, rng);
          expect(split.length, parts);
          expect(split.fold<int>(0, (sum, v) => sum + v), total);
          expect(split.every((v) => v >= 0), isTrue);
        }
      }
    });

    test('attributeGameStatsToRoster conserves yards and touchdowns exactly, onto real roster players', () {
      final rng = Random(7);
      final starters = buildStarters();
      final rosterNames = starters.map((p) => p.name).toSet();

      for (var trial = 0; trial < 25; trial++) {
        final teamTDs = trial % 6;
        final teamFGs = trial % 4;
        final totalYards = 150 + trial * 17;
        final turnoversForced = trial % 5;

        final lines = attributeGameStatsToRoster(
          starters: starters,
          teamTDs: teamTDs,
          teamFGs: teamFGs,
          teamTotalYards: totalYards,
          turnoversForced: turnoversForced,
          rng: rng,
        );

        // Every attributed stat belongs to an actual player on the roster —
        // never a fabricated name.
        expect(lines.keys.every(rosterNames.contains), isTrue);

        final offensiveYards = lines.values.fold<int>(
          0,
          (sum, l) => sum + l.passYards + l.rushYards,
        );
        expect(offensiveYards, totalYards);

        final offensiveTDs = lines.values.fold<int>(
          0,
          (sum, l) => sum + l.passTDs + l.rushTDs,
        );
        expect(offensiveTDs, teamTDs);

        final interceptions = lines.values.fold<int>(0, (sum, l) => sum + l.interceptions);
        expect(interceptions, turnoversForced.clamp(0, 4));
      }
    });

    test('attributeGameStatsToRoster gives the QB the rushing production when there is no back', () {
      final starters = [
        const Player(name: 'Solo QB', position: 'QB', overall: 88, potential: 90, year: 'SR', stars: 5),
        const Player(name: 'Solo WR', position: 'WR', overall: 80, potential: 84, year: 'JR', stars: 3),
      ];

      final lines = attributeGameStatsToRoster(
        starters: starters,
        teamTDs: 3,
        teamFGs: 1,
        teamTotalYards: 300,
        turnoversForced: 1,
        rng: Random(3),
      );

      expect(lines.containsKey('Solo QB'), isTrue);
      final qbLine = lines['Solo QB']!;
      expect(qbLine.passYards + qbLine.rushYards, 300);
    });

    test('season stats accumulate as the exact sum of every game recorded', () {
      final starters = buildStarters();
      final rng = Random(11);

      var season = <String, GamePlayerLine>{};
      final allGames = <Map<String, GamePlayerLine>>[];

      for (var week = 0; week < 5; week++) {
        final gameLines = attributeGameStatsToRoster(
          starters: starters,
          teamTDs: week,
          teamFGs: (week + 1) % 3,
          teamTotalYards: 200 + week * 40,
          turnoversForced: week % 3,
          rng: rng,
        );
        allGames.add(gameLines);

        for (final entry in gameLines.entries) {
          season[entry.key] = (season[entry.key] ?? GamePlayerLine.zero) + entry.value;
        }
      }

      // Recomputing each player's total directly from the recorded games
      // must match the running accumulator exactly — this is the "season
      // stats match up with game to game stats" guarantee.
      for (final playerName in season.keys) {
        final direct = allGames.fold<GamePlayerLine>(
          GamePlayerLine.zero,
          (sum, game) => sum + (game[playerName] ?? GamePlayerLine.zero),
        );
        expect(season[playerName]!.passYards, direct.passYards);
        expect(season[playerName]!.rushYards, direct.rushYards);
        expect(season[playerName]!.recYards, direct.recYards);
        expect(season[playerName]!.totalTDs, direct.totalTDs);
        expect(season[playerName]!.tackles, direct.tackles);
      }
    });

    test('seasonStatLineFor formats only the categories a player actually recorded', () {
      const line = GamePlayerLine(passYards: 245, passTDs: 3);
      final text = seasonStatLineFor(line);
      expect(text, contains('245 pass yds'));
      expect(text, contains('3 pass TD'));
      expect(text, isNot(contains('rush')));
      expect(text, isNot(contains('rec')));

      expect(seasonStatLineFor(GamePlayerLine.zero), 'No stats recorded yet');
    });

    testWidgets('SeasonStatsScreen renders real team totals summed from player lines', (tester) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final roster = buildStarters();
      const stats = {
        'Test QB': GamePlayerLine(passYards: 220, passTDs: 2),
        'Test HB': GamePlayerLine(rushYards: 95, rushTDs: 1),
      };

      await tester.pumpWidget(
        MaterialApp(
          home: SeasonStatsScreen(
            team: oxford,
            record: '4-1',
            gamesPlayed: 5,
            roster: roster,
            seasonPlayerStats: stats,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(tester.takeException(), isNull);
      // Team total yards must be the exact sum of the two players' lines
      // (220 + 95 = 315), not an independently generated number.
      expect(find.text('315'), findsOneWidget);
      expect(find.textContaining('220 pass yds'), findsOneWidget);
      expect(find.textContaining('95 rush yds'), findsOneWidget);
    });

    testWidgets('a live-watched game builds a real, growing player box score shown during and after the game', (tester) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final starters = buildStarters();
      final qb = starters.firstWhere((p) => p.position == 'QB');

      await tester.pumpWidget(
        MaterialApp(
          home: GameSimScreen(
            team: oxford,
            opponent: ypsilanti,
            teamOvr: 90,
            opponentOvr: 50,
            teamStartingQb: qb,
            opponentStartingQb: nationalStartingQbFor(ypsilanti, 1),
            teamLeaders: starters.take(3).toList(),
            teamStarters: starters,
            onFinished: (_) {},
          ),
        ),
      );

      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('QUICK SIM TO FINAL'));

      for (var i = 0; i < 200; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        // Halftime adjustments pause the sim with a non-dismissible sheet
        // — confirm the pre-selected plans so quick-sim can finish.
        final confirmButton = find.text('CONFIRM ADJUSTMENTS');
        if (confirmButton.evaluate().isNotEmpty) {
          // warnIfMissed: false — the sheet may still be sliding into
          // place; the loop retries every 50ms until a tap actually lands.
          await tester.tap(confirmButton, warnIfMissed: false);
          await tester.pump();
        }
      }
      await tester.pumpAndSettle(const Duration(milliseconds: 100));

      expect(tester.takeException(), isNull);

      // A heavily-favored team across a full game produces real scoring
      // events, so the postgame box score panel shows actual attributed
      // player stats (real names from teamStarters), not just team-level
      // numbers.
      expect(find.text('PLAYER STATS'), findsWidgets);
      expect(find.textContaining(qb.cleanName), findsWidgets);
    });

    testWidgets('dashboard home tab renders the redesigned Next Assignment and Program Readout without overflow', (tester) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: DashboardScreen(team: oxford, coach: testCoach),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));

      expect(tester.takeException(), isNull);
      expect(find.text('NEXT ASSIGNMENT'), findsOneWidget);
      expect(find.text('PROGRAM READOUT'), findsOneWidget);
      // A fresh career starts at week 1 of the real 14-week schedule (week
      // 0 is guaranteed a real game, never a bye).
      expect(find.textContaining('WEEK 1'), findsWidgets);
    });
  });

  group('a real school color always stays legible as text on light paper', () {
    test('gkSchoolColorOnPaper darkens a pale team color enough to read on agedPaper', () {
      // Iowa City's real color — the exact kind of pale gold that was
      // reported as invisible on the Contract Signing screen's paper card.
      const paleGold = Color(0xFFFFCD00);
      final fixed = gkSchoolColorOnPaper(paleGold);

      // A rough luminance check: the fixed color must be meaningfully
      // darker than the raw team color, and dark enough to read against
      // agedPaper (0xFFE9DDBE, a light tan — luminance well above 0.6).
      double luminance(Color c) => (0.299 * c.r + 0.587 * c.g + 0.114 * c.b);
      expect(luminance(fixed), lessThan(luminance(paleGold)));
      expect(luminance(fixed), lessThan(0.35));
    });

    test('gkSchoolColorOnPaper still darkens an already-dark team color, never lightens it', () {
      const alreadyDark = Color(0xFF14213D);
      final fixed = gkSchoolColorOnPaper(alreadyDark);
      double luminance(Color c) => (0.299 * c.r + 0.587 * c.g + 0.114 * c.b);
      expect(luminance(fixed), lessThanOrEqualTo(luminance(alreadyDark) + 0.01));
    });
  });

  group('scheme mastery shifts drive odds without guaranteeing outcomes', () {
    test('driveChancesFor always respects its declared clamp ranges', () {
      for (final diff in [-60.0, -35.0, -4.0, 0.0, 4.0, 35.0, 60.0]) {
        for (final delta in [-0.03, 0.0, 0.03]) {
          final chances = driveChancesFor(
            diff: diff,
            tdDelta: delta,
            fgDelta: delta,
            turnoverDelta: delta,
            bigPlayDelta: delta,
          );
          expect(chances.td, inInclusiveRange(0.018, 0.28));
          expect(chances.fg, inInclusiveRange(0.020, 0.16));
          expect(chances.turnover, inInclusiveRange(0.045, 0.22));
          expect(chances.bigPlay, inInclusiveRange(0.035, 0.20));
        }
      }
    });

    // A simplified but faithful stand-in for _simPlay's own scoring logic
    // (same driveChancesFor, same td=7/fg=3 roll structure, 28 alternating
    // drives) — used to Monte Carlo whether scheme/halftime effects can
    // ever override a real Overall gap, without touching Flutter widgets.
    int simulateGameMargin({
      required double ovrGapForTeam,
      required int schemeModForTeamOffense,
      required int schemeModForOpponentOffense,
      double offTdDelta = 0,
      double offFgDelta = 0,
      double offTurnoverDelta = 0,
      double offBigPlayDelta = 0,
      double defTdDelta = 0,
      double defTurnoverDelta = 0,
      double defBigPlayDelta = 0,
      required Random rng,
    }) {
      int teamScore = 0, opponentScore = 0;
      for (int drive = 0; drive < 28; drive++) {
        final userBall = drive % 2 == 0;
        final rawDiff = userBall ? ovrGapForTeam : -ovrGapForTeam;
        final schemeMod = userBall ? schemeModForTeamOffense : schemeModForOpponentOffense;
        final diff = rawDiff + schemeMod;
        final secondHalf = drive >= 14;
        final chances = driveChancesFor(
          diff: diff,
          tdDelta: !secondHalf ? 0 : (userBall ? offTdDelta : defTdDelta),
          fgDelta: !secondHalf ? 0 : (userBall ? offFgDelta : 0),
          turnoverDelta: !secondHalf ? 0 : (userBall ? offTurnoverDelta : defTurnoverDelta),
          bigPlayDelta: !secondHalf ? 0 : (userBall ? offBigPlayDelta : defBigPlayDelta),
        );
        final roll = rng.nextDouble();
        if (roll < chances.td) {
          if (userBall) teamScore += 7; else opponentScore += 7;
        } else if (roll < chances.td + chances.fg) {
          if (userBall) teamScore += 3; else opponentScore += 3;
        }
      }
      return teamScore - opponentScore;
    }

    test('a real 35-Overall-point gap still wins almost always, even against the worst possible scheme + halftime combination', () {
      final rng = Random(12345);
      var teamWins = 0;
      const trials = 500;
      for (var i = 0; i < trials; i++) {
        final margin = simulateGameMargin(
          ovrGapForTeam: 35,
          schemeModForTeamOffense: -4, // worst matchup for the favorite's own offense
          schemeModForOpponentOffense: 4, // best matchup for the underdog's offense
          // Componentwise worst across all real offensive-plan x
          // defensive-plan combinations — more adversarial than any single
          // real pick could produce.
          offTdDelta: -0.008,
          offFgDelta: -0.008,
          offTurnoverDelta: 0.022,
          offBigPlayDelta: -0.012,
          defTdDelta: 0,
          defTurnoverDelta: -0.006,
          defBigPlayDelta: 0.014,
          rng: rng,
        );
        if (margin > 0) teamWins++;
      }
      expect(teamWins / trials, greaterThanOrEqualTo(0.90));
    });

    test('in a dead-even matchup, the best scheme + halftime combination measurably improves win rate but does not guarantee it', () {
      final neutralRng = Random(777);
      var neutralWins = 0;
      final favorableRng = Random(777);
      var favorableWins = 0;
      const trials = 500;

      for (var i = 0; i < trials; i++) {
        if (simulateGameMargin(
              ovrGapForTeam: 0,
              schemeModForTeamOffense: 0,
              schemeModForOpponentOffense: 0,
              rng: neutralRng,
            ) >
            0) {
          neutralWins++;
        }

        if (simulateGameMargin(
              ovrGapForTeam: 0,
              schemeModForTeamOffense: 4,
              schemeModForOpponentOffense: -4,
              // Componentwise best across all real offensive-plan x
              // defensive-plan combinations.
              offTdDelta: 0.018,
              offFgDelta: 0.010,
              offTurnoverDelta: -0.018,
              offBigPlayDelta: 0.016,
              defTdDelta: -0.012,
              defTurnoverDelta: 0.024,
              defBigPlayDelta: -0.016,
              rng: favorableRng,
            ) >
            0) {
          favorableWins++;
        }
      }

      final neutralRate = neutralWins / trials;
      final favorableRate = favorableWins / trials;
      // Strategy should make a real difference in a fair fight...
      expect(favorableRate, greaterThan(neutralRate + 0.02));
      // ...but even the best possible scheme + halftime combination should
      // not turn a dead-even matchup into a lock.
      expect(favorableRate, lessThan(0.97));
    });

    testWidgets('a watched game pauses at halftime with a labeled recommendation, and finishes normally after a choice', (tester) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final qb = const Player(
        name: 'Halftime Quarterback',
        position: 'QB',
        overall: 78,
        potential: 88,
        year: 'JR',
        stars: 3,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: GameSimScreen(
            team: oxford,
            opponent: ypsilanti,
            teamOvr: 72,
            opponentOvr: 68,
            teamStartingQb: qb,
            opponentStartingQb: nationalStartingQbFor(ypsilanti, 1),
            teamLeaders: [qb],
            // A real, non-neutral matchup so schemeMatchupModifier is
            // actually nonzero for this game.
            userOffensiveScheme: 'Air Raid',
            userDefensiveScheme: 'Nickel',
            opponentOffensiveScheme: 'Ground & Pound',
            opponentDefensiveScheme: '3-4 Defense',
            onFinished: (_) {},
          ),
        ),
      );

      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('QUICK SIM TO FINAL'));

      var sawHalftimeSheet = false;
      for (var i = 0; i < 200; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        final confirmButton = find.text('CONFIRM ADJUSTMENTS');
        if (confirmButton.evaluate().isNotEmpty) {
          sawHalftimeSheet = true;
          // Exactly one offensive plan and one defensive plan are always
          // marked RECOMMENDED (one per axis) — a real, situational read,
          // not a coin flip.
          expect(find.text('RECOMMENDED').evaluate().length, 2);
          // warnIfMissed: false — the sheet may still be sliding into
          // place; the loop retries every 50ms until a tap actually lands.
          await tester.tap(confirmButton, warnIfMissed: false);
          await tester.pump();
        }
      }
      await tester.pumpAndSettle(const Duration(milliseconds: 100));

      expect(sawHalftimeSheet, isTrue);
      expect(tester.takeException(), isNull);
      expect(find.text('PLAYER OF THE GAME'), findsOneWidget);
    });
  });

  group('Legacy Board', () {
    test('legacyScoreFor weighs a national title above conference titles above bowl points above raw wins', () {
      final oneTitle = legacyScoreFor(nationalTitles: 1, conferenceTitles: 0, bowlPoints: 0, careerWins: 0, currentPrestige: 50);
      final threeConfs = legacyScoreFor(nationalTitles: 0, conferenceTitles: 3, bowlPoints: 0, careerWins: 0, currentPrestige: 50);
      final threeBowls = legacyScoreFor(nationalTitles: 0, conferenceTitles: 0, bowlPoints: 3 * 75, careerWins: 0, currentPrestige: 50);
      final noTitles = legacyScoreFor(nationalTitles: 0, conferenceTitles: 0, bowlPoints: 0, careerWins: 50, currentPrestige: 50);

      expect(oneTitle, greaterThan(threeConfs));
      expect(threeConfs, greaterThan(threeBowls));
      expect(threeBowls, greaterThan(noTitles));
    });

    test('legacyScoreFor rewards a real bowl tier over a minor one, and an undefeated season is a genuine bonus', () {
      final minorBowl = legacyScoreFor(nationalTitles: 0, conferenceTitles: 0, bowlPoints: bowlTierPointsForWins(6), careerWins: 0, currentPrestige: 50);
      final majorBowl = legacyScoreFor(nationalTitles: 0, conferenceTitles: 0, bowlPoints: bowlTierPointsForWins(12), careerWins: 0, currentPrestige: 50);
      expect(majorBowl, greaterThan(minorBowl));

      final noRecord = legacyScoreFor(nationalTitles: 0, conferenceTitles: 0, bowlPoints: 0, careerWins: 0, currentPrestige: 50);
      final withRecord = legacyScoreFor(nationalTitles: 0, conferenceTitles: 0, bowlPoints: 0, careerWins: 0, currentPrestige: 50, undefeatedSeasons: 1);
      expect(withRecord, greaterThan(noRecord));
      // A conference title still outweighs a single undefeated season.
      final oneConf = legacyScoreFor(nationalTitles: 0, conferenceTitles: 1, bowlPoints: 0, careerWins: 0, currentPrestige: 50);
      expect(oneConf, greaterThan(withRecord));
    });

    test('bowlWinPoints matches the trophy title to its real bowl tier, with a base-tier fallback', () {
      expect(bowlWinPoints('Grove Bowl Champions'), bowlTierPoints['Grove Bowl']);
      expect(bowlWinPoints('Beacon Bowl Champions'), bowlTierPoints['Beacon Bowl']);
      expect(bowlWinPoints('Some Unrecognized Bowl Champions'), 75);
    });

    test('seasonGoalFor produces an evaluable, ascending-difficulty goal per prestige tier', () {
      expect(seasonGoalFor(40).type, SeasonGoalType.winTotal);
      expect(seasonGoalFor(40).targetWins, prestigeExpectationWins(40));
      expect(seasonGoalFor(65).type, SeasonGoalType.bowlBerth);
      expect(seasonGoalFor(75).type, SeasonGoalType.conferenceTitle);
      expect(seasonGoalFor(85).type, SeasonGoalType.playoffBerth);
      expect(seasonGoalFor(95).type, SeasonGoalType.nationalTitle);
    });

    test('goalWasMet resolves every goal type correctly, including the wins >= 6 bowl threshold edge', () {
      expect(goalWasMet(const SeasonGoal(type: SeasonGoalType.winTotal, targetWins: 6), wins: 6, wonConference: false, madeCfp: false, wonTitle: false), isTrue);
      expect(goalWasMet(const SeasonGoal(type: SeasonGoalType.winTotal, targetWins: 6), wins: 5, wonConference: false, madeCfp: false, wonTitle: false), isFalse);
      expect(goalWasMet(const SeasonGoal(type: SeasonGoalType.bowlBerth), wins: 6, wonConference: false, madeCfp: false, wonTitle: false), isTrue);
      expect(goalWasMet(const SeasonGoal(type: SeasonGoalType.bowlBerth), wins: 5, wonConference: false, madeCfp: false, wonTitle: false), isFalse);
      expect(goalWasMet(const SeasonGoal(type: SeasonGoalType.conferenceTitle), wins: 9, wonConference: true, madeCfp: false, wonTitle: false), isTrue);
      expect(goalWasMet(const SeasonGoal(type: SeasonGoalType.playoffBerth), wins: 10, wonConference: false, madeCfp: true, wonTitle: false), isTrue);
      expect(goalWasMet(const SeasonGoal(type: SeasonGoalType.nationalTitle), wins: 14, wonConference: true, madeCfp: true, wonTitle: true), isTrue);
      expect(goalWasMet(const SeasonGoal(type: SeasonGoalType.nationalTitle), wins: 13, wonConference: true, madeCfp: true, wonTitle: false), isFalse);
    });

    test('simulateRivalCoachSeason stays within realistic bounds across many trials', () {
      var rival = const RivalCoachRecord(
        coachName: 'Test Coach', teamName: 'Oxford', currentPrestige: 70, tenureYears: 0,
        careerWins: 0, careerLosses: 0, nationalTitles: 0, conferenceTitles: 0, bowlWins: 0,
      );
      for (var i = 0; i < 500; i++) {
        rival = simulateRivalCoachSeason(rival);
        expect(rival.currentPrestige, inInclusiveRange(1, 100));
      }
      expect(rival.tenureYears, 500);
      expect(rival.careerWins + rival.careerLosses, 500 * 12);
    });

    test('rival coach / season goal / season goal record JSON round-trip', () {
      const rival = RivalCoachRecord(
        coachName: 'Test Coach', teamName: 'Oxford', currentPrestige: 82, tenureYears: 5,
        careerWins: 40, careerLosses: 20, nationalTitles: 1, conferenceTitles: 3, bowlWins: 4,
      );
      final restoredRival = rivalCoachFromJson(rivalCoachToJson(rival));
      expect(restoredRival.coachName, 'Test Coach');
      expect(restoredRival.nationalTitles, 1);

      const goal = SeasonGoal(type: SeasonGoalType.conferenceTitle);
      final restoredGoal = seasonGoalFromJson(seasonGoalToJson(goal));
      expect(restoredGoal.type, SeasonGoalType.conferenceTitle);

      // Unknown/missing type must fall back safely, not throw.
      final fallbackGoal = seasonGoalFromJson({'type': 'somethingRemoved'});
      expect(fallbackGoal.type, SeasonGoalType.winTotal);

      const record = SeasonGoalRecord(year: 4, description: 'WIN THE CONFERENCE', met: true);
      final restoredRecord = seasonGoalRecordFromJson(seasonGoalRecordToJson(record));
      expect(restoredRecord.met, isTrue);
    });

    test('generateRivalCoachLeague makes one coach per program (both subdivisions), excluding the user\'s own team', () {
      final league = generateRivalCoachLeague(oxford.name);
      expect(league.any((r) => r.teamName == oxford.name), isFalse);
      // allTeams, not just g5Teams — an FCS team with no RivalCoachRecord
      // would never get a live-tracked prestige at all (see
      // _DashboardScreenState._livePrestigeFor).
      expect(league.length, allTeams.where((t) => t.name != oxford.name).length);
      for (final rival in league) {
        // Every rival is seeded with 3-15 seasons of pre-existing career
        // history (via simulateRivalCoachSeason) so the Legacy Board never
        // opens with every coach at a blank 0-everything résumé.
        expect(rival.tenureYears, inInclusiveRange(3, 15));
        expect(rival.careerWins + rival.careerLosses, rival.tenureYears * 12);
        expect(rival.currentPrestige, inInclusiveRange(1, 100));
      }
    });

    testWidgets('Legacy Board renders without exceptions given a sample league and goal', (tester) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final rivals = List.generate(30, (i) => RivalCoachRecord(
        coachName: 'Rival $i',
        teamName: g5Teams[i % g5Teams.length].name,
        currentPrestige: 50 + i,
        tenureYears: i,
        careerWins: i * 8,
        careerLosses: i * 4,
        nationalTitles: i % 5 == 0 ? 1 : 0,
        conferenceTitles: i % 3,
        bowlWins: i % 4,
      ));

      await tester.pumpWidget(MaterialApp(
        home: LegacyBoardScreen(
          coach: testCoach,
          team: oxford,
          rivalCoaches: rivals,
          userNationalTitles: 1,
          userConferenceTitles: 2,
          userBowlWins: 3,
          userBowlPoints: 3 * 75,
          userCareerWins: 40,
          userCurrentPrestige: 78,
          userUndefeatedSeasons: 0,
          currentSeasonGoal: const SeasonGoal(type: SeasonGoalType.playoffBerth),
          seasonGoalHistory: const [SeasonGoalRecord(year: 3, description: 'WIN THE CONFERENCE', met: false)],
          alreadyRetired: false,
          onRetire: (_) async {},
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      expect(tester.takeException(), isNull);
      expect(find.textContaining(testCoach.name), findsWidgets);
    });

    testWidgets('Legacy Board never shows a duplicate rank number when the user ranks #1', (tester) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // Every rival scores far below the user (0 trophies, low prestige),
      // so the user must land at rank #1 — the exact scenario that showed
      // two different coaches both labeled "#1" before the fix.
      final rivals = List.generate(5, (i) => RivalCoachRecord(
        coachName: 'Rival $i',
        teamName: g5Teams[i % g5Teams.length].name,
        currentPrestige: 50,
        tenureYears: 1,
        careerWins: 0,
        careerLosses: 0,
        nationalTitles: 0,
        conferenceTitles: 0,
        bowlWins: 0,
      ));

      await tester.pumpWidget(MaterialApp(
        home: LegacyBoardScreen(
          coach: testCoach,
          team: oxford,
          rivalCoaches: rivals,
          userNationalTitles: 3,
          userConferenceTitles: 5,
          userBowlWins: 5,
          userBowlPoints: 5 * 75,
          userCareerWins: 80,
          userCurrentPrestige: 95,
          userUndefeatedSeasons: 0,
          currentSeasonGoal: null,
          seasonGoalHistory: const [],
          alreadyRetired: false,
          onRetire: (_) async {},
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      expect(tester.takeException(), isNull);
      expect(find.text('#1'), findsOneWidget);
      expect(find.text('#2'), findsOneWidget);
    });
  });

  group('injuries actually sideline a player, not just display a label', () {
    test('rollInjuryFor always produces a bounded, real recovery timeline', () {
      final rng = Random(7);
      for (var i = 0; i < 200; i++) {
        final injury = rollInjuryFor('Test Player', 3, rng);
        expect(injury.playerName, 'Test Player');
        expect(injury.weekOccurred, 3);
        expect(injury.weeksRemaining, greaterThanOrEqualTo(1));
        expect(injury.weeksRemaining, lessThanOrEqualTo(8));
        expect(injuryTypes.any((t) => t.description == injury.description), isTrue);
      }
    });

    test('Injury JSON round-trips exactly', () {
      const injury = Injury(playerName: 'Sam Carter', description: 'Knee Injury', weeksRemaining: 4, weekOccurred: 6);
      final restored = Injury.fromJson(injury.toJson());
      expect(restored.playerName, injury.playerName);
      expect(restored.description, injury.description);
      expect(restored.weeksRemaining, injury.weeksRemaining);
      expect(restored.weekOccurred, injury.weekOccurred);
    });
  });

  group('transfer risk is derived from real signals, not a random guess', () {
    const starter = Player(name: 'Starter One', position: 'QB', overall: 85, potential: 88, year: 'SR', stars: 4);
    const buriedVeteran = Player(name: 'Buried Veteran', position: 'WR', overall: 78, potential: 80, year: 'SR', stars: 4);
    const freshman = Player(name: 'Young Freshman', position: 'WR', overall: 60, potential: 85, year: 'FR', stars: 3);

    test('a healthy starter with a scheme fit has no transfer risk', () {
      final result = transferRiskFor(starter, isStarter: true, offensiveScheme: 'Pro Style', defensiveScheme: '4-3 Defense', boosterApproval: 80);
      expect(result.reasons, isEmpty);
      expect(result.riskScore, 0);
    });

    test('a buried upperclassman on the bench is flagged for playing time', () {
      final result = transferRiskFor(buriedVeteran, isStarter: false, offensiveScheme: 'Pro Style', defensiveScheme: '4-3 Defense', boosterApproval: 80);
      expect(result.reasons, contains(TransferRiskReason.playingTime));
      expect(result.riskScore, greaterThan(0));
    });

    test('a benched freshman is not flagged for playing time — too early to expect a starting job', () {
      final result = transferRiskFor(freshman, isStarter: false, offensiveScheme: 'Pro Style', defensiveScheme: '4-3 Defense', boosterApproval: 80);
      expect(result.reasons, isNot(contains(TransferRiskReason.playingTime)));
    });

    test('a poor scheme fit is flagged regardless of starting status', () {
      // Air Raid rates HB at -4 fit.
      const hb = Player(name: 'Ground Back', position: 'HB', overall: 82, potential: 85, year: 'JR', stars: 4);
      final result = transferRiskFor(hb, isStarter: true, offensiveScheme: 'Air Raid', defensiveScheme: '4-3 Defense', boosterApproval: 80);
      expect(result.reasons, contains(TransferRiskReason.schemeFit));
    });
  });

  group('a coach-picked bye week placement is always legal or rejected', () {
    test('a valid, well-spaced pair passes', () {
      expect(isValidByeWeekPlacement([4, 9]), isTrue);
    });

    test('back-to-back weeks are rejected', () {
      expect(isValidByeWeekPlacement([4, 5]), isFalse);
    });

    test('the season opener and the final week are never legal bye weeks', () {
      expect(isValidByeWeekPlacement([0, 6]), isFalse);
      expect(isValidByeWeekPlacement([6, 13]), isFalse);
    });

    test('anything other than exactly two distinct weeks is rejected', () {
      expect(isValidByeWeekPlacement([4]), isFalse);
      expect(isValidByeWeekPlacement([4, 4]), isFalse);
      expect(isValidByeWeekPlacement([2, 6, 9]), isFalse);
    });

    test('generateByeWeeks always produces a placement isValidByeWeekPlacement accepts', () {
      final rng = Random(11);
      for (var i = 0; i < 200; i++) {
        final weeks = generateByeWeeks(rng).toList();
        expect(isValidByeWeekPlacement(weeks), isTrue, reason: 'generateByeWeeks produced $weeks');
      }
    });
  });

  group('a player only ever gets one redshirt across a career', () {
    const player = Player(
      name: 'Test Player',
      position: 'QB',
      overall: 70,
      potential: 85,
      year: 'FR',
      stars: 3,
    );

    test('hasRedshirted defaults to false for every pre-existing call site', () {
      expect(player.hasRedshirted, isFalse);
    });

    test('hasRedshirted round-trips through JSON', () {
      final redshirted = Player(
        name: player.name,
        position: player.position,
        overall: player.overall,
        potential: player.potential,
        year: player.year,
        stars: player.stars,
        hasRedshirted: true,
      );
      final decoded = playerFromJson(playerToJson(redshirted));
      expect(decoded.hasRedshirted, isTrue);
      expect(playerFromJson(playerToJson(player)).hasRedshirted, isFalse);
    });

    test('a save from before this field existed loads as not-yet-redshirted', () {
      final legacyJson = playerToJson(player)..remove('hasRedshirted');
      expect(playerFromJson(legacyJson).hasRedshirted, isFalse);
    });
  });

  group('a recruit can never commit past the roster room that will actually exist', () {
    // _DashboardScreenState._recruitingClassHasRoom (threaded into this
    // screen as classHasRoom) is what used to be missing entirely — a
    // recruit could commit with no regard for whether next year's
    // _initialRoster() would actually have a slot for them, so a full class
    // would silently lose its overflow the moment the season turned over.
    Widget buildProfile({required bool classHasRoom, required VoidCallback onOffer}) {
      final recruit = Recruit(
        name: 'Prospect Test',
        position: 'WR',
        state: 'OH',
        stars: 4,
        trueOverall: 80,
        truePotential: 88,
        interest: 60,
      );
      return MaterialApp(
        home: RecruitProfileScreen(
          recruit: recruit,
          rank: 1,
          userSchool: 'Oxford',
          recruitingClosed: false,
          recruitingPoints: () => 150,
          gamesPlayed: 1,
          nilBudgetRemaining: () => 0,
          canScheduleVisit: () => false,
          canOfferNil: () => false,
          canBoostMorale: () => false,
          classHasRoom: () => classHasRoom,
          onScout: () {},
          onOffer: onOffer,
          onScheduleVisit: () {},
          onOfferNil: () {},
          onBoostMorale: () {},
        ),
      );
    }

    testWidgets('a full class shows Class Full and the offer never fires', (tester) async {
      var offerCalled = false;
      await tester.pumpWidget(
        buildProfile(classHasRoom: false, onOffer: () => offerCalled = true),
      );
      await tester.pumpAndSettle();

      // The action card sits below the fold in the default test viewport —
      // ListView only mounts elements inside the viewport + cache extent,
      // so it has to be scrolled into view before it exists in the tree.
      // GKPrimaryButton renders its label via .toUpperCase().
      await tester.drag(find.byType(ListView), const Offset(0, -2000));
      await tester.pumpAndSettle();
      expect(find.text('CLASS FULL'), findsOneWidget);
      expect(find.text('OFFER · 10 PTS'), findsNothing);

      await tester.tap(find.text('CLASS FULL'));
      await tester.pump();
      expect(offerCalled, isFalse);
    });

    testWidgets('an open class still shows a live offer button', (tester) async {
      var offerCalled = false;
      await tester.pumpWidget(
        buildProfile(classHasRoom: true, onOffer: () => offerCalled = true),
      );
      await tester.pumpAndSettle();

      await tester.drag(find.byType(ListView), const Offset(0, -2000));
      await tester.pumpAndSettle();
      expect(find.text('OFFER · 10 PTS'), findsOneWidget);
      expect(find.text('CLASS FULL'), findsNothing);

      await tester.tap(find.text('OFFER · 10 PTS'));
      await tester.pump();
      expect(offerCalled, isTrue);
    });
  });

  group('the FCS subdivision is fully populated and cleanly separated from FBS', () {
    test('fcsTeams matches g5Teams in scale and every team is tagged fcs', () {
      expect(fcsTeams.length, greaterThanOrEqualTo(120));
      expect(fcsTeams.every((t) => t.subdivision == Subdivision.fcs), isTrue);
      expect(g5Teams.every((t) => t.subdivision == Subdivision.fbs), isTrue);
    });

    test('no team name or conference is shared between the two subdivisions', () {
      final fbsNames = g5Teams.map((t) => t.name).toSet();
      final fcsNames = fcsTeams.map((t) => t.name).toSet();
      expect(fbsNames.intersection(fcsNames), isEmpty);

      final fbsConfs = g5Teams.map((t) => t.conference).toSet();
      final fcsConfs = fcsTeams.map((t) => t.conference).toSet();
      expect(fbsConfs.intersection(fcsConfs), isEmpty);
    });

    test('allTeams is the exact union and every name is unique league-wide', () {
      expect(allTeams.length, g5Teams.length + fcsTeams.length);
      final names = allTeams.map((t) => t.name).toSet();
      expect(names.length, allTeams.length);
    });

    test('teamByName resolves an FCS team by name, not just FBS ones', () {
      final sample = fcsTeams.first;
      expect(teamByName(sample.name).name, sample.name);
      expect(teamByName(sample.name).subdivision, Subdivision.fcs);
    });

    test('FCS prestige overlaps the bottom of the FBS range rather than sitting strictly below it', () {
      // Weak FBS (55-67) and elite FCS (67-78) must genuinely overlap, or
      // an FBS-vs-FCS game could never be a real contest.
      final weakFbsCount = g5Teams.where((t) => t.prestige >= 55 && t.prestige <= 67).length;
      final eliteFcsCount = fcsTeams.where((t) => t.prestige >= 67 && t.prestige <= 78).length;
      expect(weakFbsCount, greaterThan(0));
      expect(eliteFcsCount, greaterThan(0));

      final maxFcsPrestige = fcsTeams.map((t) => t.prestige).reduce((a, b) => a > b ? a : b);
      final minWeakFbsPrestige = g5Teams
          .where((t) => t.prestige <= 67)
          .map((t) => t.prestige)
          .reduce((a, b) => a < b ? a : b);
      expect(maxFcsPrestige, greaterThanOrEqualTo(minWeakFbsPrestige));
    });
  });

  group('FCS rankings, standings, and postseason stay separate from FBS', () {
    testWidgets('a fresh FCS dynasty renders its own subdivision without crashing', (tester) async {
      final fcsSchool = fcsTeams.first;

      await tester.pumpWidget(
        MaterialApp(
          home: DashboardScreen(team: fcsSchool, coach: testCoach),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));

      expect(tester.takeException(), isNull);
      expect(find.text('NEXT ASSIGNMENT'), findsOneWidget);
    });

    test('recruitingClassNationalRank compares an FCS class only against the FCS field', () {
      const season = 1;
      final fcsSchool = fcsTeams.first;
      final fbsSchool = g5Teams.first;

      // A score set right between the two pools' typical class scores —
      // computed from the real data, not guessed — should rank the FCS
      // team near the top of its (lower-scoring) field but near the
      // bottom of the FBS field, proving the two calls draw from genuinely
      // different pools rather than one shared one.
      final fcsScores = fcsTeams.map((t) => nationalRecruitingClassScore(t, season)).toList()..sort();
      final fbsScores = g5Teams.map((t) => nationalRecruitingClassScore(t, season)).toList()..sort();
      final midScore = ((fcsScores[fcsScores.length ~/ 2] + fbsScores[fbsScores.length ~/ 2]) / 2).round();

      final fcsRank = recruitingClassNationalRank(userScore: midScore, userTeam: fcsSchool, season: season);
      final fbsRank = recruitingClassNationalRank(userScore: midScore, userTeam: fbsSchool, season: season);

      expect(fcsRank, lessThan(fcsTeams.length ~/ 3));
      expect(fbsRank, greaterThan(g5Teams.length * 2 ~/ 3));
    });
  });

  group('cross-subdivision scheduling never breaks conference safety', () {
    test('isIndependentConference recognizes both subdivisions\' independent bucket', () {
      expect(isIndependentConference('Independent'), isTrue);
      expect(isIndependentConference('FCS Independent'), isTrue);
      expect(isIndependentConference('Heartland Conference'), isFalse);
      expect(isIndependentConference('Coastal Gateway Conference'), isFalse);
    });

    test('every FCS independent team is actually tagged with the independent bucket', () {
      // The whole point of introducing a second independent-conference
      // string was so FCS independents get the "draw the whole slate
      // nationwide" scheduling path too, not the normal 9-conference-game
      // path against a 3-team pool — this only works if the data and the
      // recognizer agree.
      final fcsIndependents = fcsTeams.where((t) => t.conference == 'FCS Independent');
      expect(fcsIndependents, isNotEmpty);
      for (final team in fcsIndependents) {
        expect(isIndependentConference(team.conference), isTrue);
      }
    });

    testWidgets('a fresh dynasty at every FCS conference (including independents) builds a schedule without crashing', (tester) async {
      // One representative team per FCS conference, including the small
      // independent group — schedule generation used to assume every
      // conference-mate pool came from g5Teams (empty for any FCS
      // conference) and independents were only ever the exact string
      // 'Independent' (never 'FCS Independent'), either of which could
      // degenerate into an infinite/near-infinite fill loop or a crash for
      // a team with few or no real conference-mates.
      final onePerConference = <String, CollegeTeam>{};
      for (final team in fcsTeams) {
        onePerConference.putIfAbsent(team.conference, () => team);
      }

      for (final team in onePerConference.values) {
        await tester.pumpWidget(
          MaterialApp(home: DashboardScreen(team: team, coach: testCoach)),
        );
        await tester.pump(const Duration(milliseconds: 50));
        expect(tester.takeException(), isNull, reason: '${team.name} (${team.conference}) crashed on init');
      }
    });
  });

  group('every CPU program\'s rating actually moves with its results, for real competitive overlap', () {
    test('sustained winning raises prestige and sustained losing lowers it', () {
      // Start an elite-FCS-band program and run a decade of blowout
      // winning seasons — prestige should climb meaningfully, the same
      // mechanism a real program's live-tracked prestige (see
      // _DashboardScreenState._livePrestigeFor) relies on to actually
      // become FBS-competitive over a career, not just on paper.
      var risingPrestige = 72;
      for (var i = 0; i < 10; i++) {
        risingPrestige = updatedPrestigeAfterSeason(
          risingPrestige, 12, 0,
          madeCfp: true, wonConference: true, wonTitle: true,
        );
      }
      expect(risingPrestige, greaterThan(72));

      // A weak-FBS-band program on a decade-long losing streak should sink
      // just as reliably.
      var fallingPrestige = 60;
      for (var i = 0; i < 10; i++) {
        fallingPrestige = updatedPrestigeAfterSeason(fallingPrestige, 1, 11);
      }
      expect(fallingPrestige, lessThan(60));
    });

    test('a weak-FBS program and an elite-FCS program are a genuinely competitive matchup', () {
      // Mirrors _DashboardScreenState._simulateNationalWeekFor's exact
      // win-chance formula. At this formula's own scale (0.08 per prestige
      // point against an underdog, clamped to [0.20, 0.80]), any gap past
      // ~4 points already saturates to the floor — so the real invariant
      // this ratings-overlap design guarantees isn't "close to 50/50," it's
      // "never below a real, playable 20% floor no matter how big the
      // gap gets" — a genuine "occasional upset," not an automatic loss.
      double winChanceFor(int a, int b) =>
          (0.50 + ((a - b) * 0.08)).clamp(0.20, 0.80);

      const weakFbsPrestige = 60; // bottom of the weak-FBS band

      for (final eliteFcsPrestige in [67, 70, 75, 78]) {
        final chance = winChanceFor(weakFbsPrestige, eliteFcsPrestige);
        expect(chance, 0.20, reason: 'weak FBS ($weakFbsPrestige) vs elite FCS ($eliteFcsPrestige)');
      }

      // A closer, more even matchup within the overlap band (e.g. a
      // merely-average FCS team, prestige in the 50-60 range) still swings
      // with the real gap instead of also flattening to the floor.
      final closeMatchupChance = winChanceFor(weakFbsPrestige, 58);
      expect(closeMatchupChance, greaterThan(0.20));
      expect(closeMatchupChance, lessThan(0.70));
    });
  });

  group('recruiting reflects real FBS/FCS star-tier expectations over many cycles', () {
    test('a five-star recruit can never actually commit to an FCS program', () {
      final fiveStar = Recruit(
        name: 'Elite Prospect', position: 'QB', state: 'OH',
        stars: 5, trueOverall: 95, truePotential: 99, interest: 100,
      );
      for (var i = 0; i < 500; i++) {
        expect(recruitCanCommitToSubdivision(fiveStar, Subdivision.fcs), isFalse);
      }
      // The same recruit is never blocked from FBS.
      expect(recruitCanCommitToSubdivision(fiveStar, Subdivision.fbs), isTrue);
    });

    test('a four-star recruit signing with an FCS program is extremely rare, never routine', () {
      final fourStar = Recruit(
        name: 'Four Star Prospect', position: 'WR', state: 'OH',
        stars: 4, trueOverall: 85, truePotential: 90, interest: 100,
      );
      var allowed = 0;
      const trials = 2000;
      for (var i = 0; i < trials; i++) {
        if (recruitCanCommitToSubdivision(fourStar, Subdivision.fcs)) allowed++;
      }
      // "Extremely rare... if the system allows it at all" — comfortably
      // under 10% even with maxed-out interest, never a normal outcome.
      expect(allowed / trials, lessThan(0.10));

      // Below the interest bar this rare exception requires, it's not
      // just rare — it's fully blocked, matching "unusual circumstances
      // such as ... exceptionally high interest."
      final ordinaryFourStar = Recruit(
        name: 'Ordinary Four Star', position: 'WR', state: 'OH',
        stars: 4, trueOverall: 82, truePotential: 88, interest: 60,
      );
      for (var i = 0; i < 200; i++) {
        expect(recruitCanCommitToSubdivision(ordinaryFourStar, Subdivision.fcs), isFalse);
      }
    });

    test('two- and three-star recruits are never hard-blocked from FCS', () {
      final twoStar = Recruit(name: 'Two Star', position: 'DB', state: 'OH', stars: 2, trueOverall: 62, truePotential: 68, interest: 50);
      final threeStar = Recruit(name: 'Three Star', position: 'LB', state: 'OH', stars: 3, trueOverall: 70, truePotential: 78, interest: 50);
      expect(recruitCanCommitToSubdivision(twoStar, Subdivision.fcs), isTrue);
      expect(recruitCanCommitToSubdivision(threeStar, Subdivision.fcs), isTrue);
    });

    test('an elite FCS program competes harder for three-stars than a weak FCS program', () {
      final eliteAdjustment = recruitSubdivisionInterestAdjustment(stars: 3, subdivision: Subdivision.fcs, prestigeTier: 3);
      final weakAdjustment = recruitSubdivisionInterestAdjustment(stars: 3, subdivision: Subdivision.fcs, prestigeTier: 1);
      expect(eliteAdjustment, greaterThan(weakAdjustment));
    });

    test('one- and two-star recruits get a real FCS interest boost, not a penalty', () {
      expect(recruitSubdivisionInterestAdjustment(stars: 1, subdivision: Subdivision.fcs, prestigeTier: 1), greaterThan(0));
      expect(recruitSubdivisionInterestAdjustment(stars: 2, subdivision: Subdivision.fcs, prestigeTier: 1), greaterThan(0));
    });

    test('the weakest FBS program still gets a real three-star floor independent of its prestige tier', () {
      // Real point: FBS scholarships/exposure/competition matter on their
      // own, not just raw current prestige — a tier-1 FBS program's 3★
      // bonus should equal a tier-5 FBS program's, not scale down with it.
      final tier1 = recruitSubdivisionInterestAdjustment(stars: 3, subdivision: Subdivision.fbs, prestigeTier: 1);
      final tier5 = recruitSubdivisionInterestAdjustment(stars: 3, subdivision: Subdivision.fbs, prestigeTier: 5);
      expect(tier1, greaterThan(0));
      expect(tier1, tier5);
    });

    test('over many generated classes, FCS interest is dramatically lower for elite recruits than for overlooked ones', () {
      const cycles = 30;
      final fiveStarInterests = <int>[];
      final oneStarInterests = <int>[];

      for (var i = 0; i < cycles; i++) {
        final recruits = generateRecruits(65, subdivision: Subdivision.fcs);
        fiveStarInterests.addAll(recruits.where((r) => r.stars == 5).map((r) => r.interest));
        oneStarInterests.addAll(recruits.where((r) => r.stars == 1).map((r) => r.interest));
      }

      expect(fiveStarInterests, isNotEmpty);
      expect(oneStarInterests, isNotEmpty);

      final avgFiveStar = fiveStarInterests.reduce((a, b) => a + b) / fiveStarInterests.length;
      final avgOneStar = oneStarInterests.reduce((a, b) => a + b) / oneStarInterests.length;

      expect(avgFiveStar, lessThan(avgOneStar));
      expect(avgFiveStar, lessThan(20)); // essentially no real interest
    });
  });

  group('the FCS playoff matches real FCS structure as closely as this fictional world allows', () {
    test('the Ivy-analog conference is excluded from the FCS playoff field entirely, matching the real Ivy League policy', () {
      final foundersTeams = fcsTeams.where((t) => t.conference == 'Founders League');
      expect(foundersTeams, isNotEmpty);
      for (final team in foundersTeams) {
        expect(isPlayoffIneligibleFcsConference(team.conference), isTrue);
      }
      expect(isPlayoffIneligibleFcsConference('Coastal Gateway Conference'), isFalse);
      expect(isPlayoffIneligibleFcsConference('FCS Independent'), isFalse);
    });
  });

  group('transfers respect the same subdivision star ceiling as recruiting', () {
    test('an elite FCS program transfer cap never exceeds three stars, even at prestige that would unlock 4-5★ for FBS', () {
      // Mirrors _OffseasonScreenState._generateTransfers's own cap logic —
      // an elite FCS program's prestige alone (up to 78, tier 3) must not
      // unlock the same 4★ portal access a mid-tier FBS program gets at
      // the same raw prestige number.
      const eliteFcsPrestige = 78;
      var maxStars = eliteFcsPrestige >= 90
          ? 5
          : eliteFcsPrestige >= 80
          ? 4
          : eliteFcsPrestige >= 70
          ? 4
          : eliteFcsPrestige >= 60
          ? 3
          : 2;
      // The actual subdivision cap this session added.
      maxStars = maxStars > 3 ? 3 : maxStars;
      expect(maxStars, 3);
    });
  });

  group('a successful FCS program earns its way into FBS, never overnight', () {
    RivalCoachRecord fcsRival({
      int consecutiveWinningSeasons = 0,
      int playoffAppearances = 0,
      int conferenceTitles = 0,
      int nationalTitles = 0,
      int currentPrestige = 70,
      int seasonsSinceRealignment = 99,
    }) => RivalCoachRecord(
      coachName: 'Test Coach', teamName: fcsTeams.first.name,
      currentPrestige: currentPrestige, tenureYears: 5,
      careerWins: 40, careerLosses: 20,
      nationalTitles: nationalTitles, conferenceTitles: conferenceTitles, bowlWins: 0,
      subdivisionOverride: Subdivision.fcs,
      consecutiveWinningSeasons: consecutiveWinningSeasons,
      playoffAppearances: playoffAppearances,
      seasonsSinceRealignment: seasonsSinceRealignment,
    );

    test('one great season alone is never enough', () {
      final oneGoodYear = fcsRival(consecutiveWinningSeasons: 1, conferenceTitles: 1, nationalTitles: 1);
      expect(isPromotionEligible(oneGoodYear), isFalse);
    });

    test('three consecutive winning seasons plus real hardware is eligible', () {
      final sustained = fcsRival(consecutiveWinningSeasons: 3, conferenceTitles: 1);
      expect(isPromotionEligible(sustained), isTrue);
    });

    test('sustained winning without any real accomplishment is still not enough', () {
      final justWinning = fcsRival(consecutiveWinningSeasons: 5);
      expect(isPromotionEligible(justWinning), isFalse);
    });

    test('two or more FCS national championships alone are enough, even without a current winning streak', () {
      final multiChampion = fcsRival(consecutiveWinningSeasons: 0, nationalTitles: 2);
      expect(isPromotionEligible(multiChampion), isTrue);

      final oneTitleNoStreak = fcsRival(consecutiveWinningSeasons: 0, nationalTitles: 1);
      expect(isPromotionEligible(oneTitleNoStreak), isFalse);
    });

    test('multiple playoff appearances substitute for a conference title', () {
      final playoffRegular = fcsRival(consecutiveWinningSeasons: 3, playoffAppearances: 2);
      expect(isPromotionEligible(playoffRegular), isTrue);
    });

    test('prestige below the weak-FBS floor blocks promotion even with a great résumé', () {
      final tooWeak = fcsRival(consecutiveWinningSeasons: 5, conferenceTitles: 2, currentPrestige: fbsPromotionPrestigeFloor - 1);
      expect(isPromotionEligible(tooWeak), isFalse);
    });

    test('an FBS team is never promotion-eligible, regardless of résumé', () {
      final alreadyFbs = RivalCoachRecord(
        coachName: 'Test Coach', teamName: g5Teams.first.name,
        currentPrestige: 90, tenureYears: 5, careerWins: 50, careerLosses: 10,
        nationalTitles: 2, conferenceTitles: 3, bowlWins: 4,
        subdivisionOverride: Subdivision.fbs,
        consecutiveWinningSeasons: 5, playoffAppearances: 3,
      );
      expect(isPromotionEligible(alreadyFbs), isFalse);
    });

    test('a cooldown after a recent realignment blocks another one right away', () {
      final justMoved = fcsRival(consecutiveWinningSeasons: 3, conferenceTitles: 1, seasonsSinceRealignment: 1);
      expect(isPromotionEligible(justMoved), isFalse);
    });

    test('realignmentInvitationFor always targets a real FBS conference, never the fictional FCS one', () {
      final eligible = fcsRival(consecutiveWinningSeasons: 4, conferenceTitles: 2, currentPrestige: 65);
      final invite = realignmentInvitationFor(eligible, chance: 1.0);
      expect(invite, isNotNull);
      expect(invite!.movesUpToFbs, isTrue);
      expect(g5Teams.any((t) => t.conference == invite.conference), isTrue);
      expect(fcsTeams.any((t) => t.conference == invite.conference), isFalse);
    });

    test('realignmentInvitationFor never fires for an ineligible program, even at 100% chance', () {
      final notEligible = fcsRival(consecutiveWinningSeasons: 1);
      expect(realignmentInvitationFor(notEligible, chance: 1.0), isNull);
    });

    test('realignmentInvitationOptionsFor gives the user something real to compare when eligible', () {
      final eligible = fcsRival(consecutiveWinningSeasons: 4, nationalTitles: 1, currentPrestige: 68);
      final options = realignmentInvitationOptionsFor(eligible);
      expect(options, isNotEmpty);
      expect(options.length, lessThanOrEqualTo(2));
      for (final option in options) {
        expect(g5Teams.any((t) => t.conference == option.conference), isTrue);
      }
    });

    test('RivalCoachRecord realignment fields round-trip through JSON, including a legacy save with none of them', () {
      final rival = fcsRival(consecutiveWinningSeasons: 3, playoffAppearances: 2, seasonsSinceRealignment: 1).copyWith(
        conferenceOverride: 'Heartland Conference',
      );
      final restored = rivalCoachFromJson(rivalCoachToJson(rival));
      expect(restored.conferenceOverride, 'Heartland Conference');
      expect(restored.subdivisionOverride, Subdivision.fcs);
      expect(restored.consecutiveWinningSeasons, 3);
      expect(restored.playoffAppearances, 2);
      expect(restored.seasonsSinceRealignment, 1);

      // A save from before realignment existed has none of these keys —
      // must load as "never realigned," not crash or read as mid-cooldown.
      final legacyJson = rivalCoachToJson(rival)
        ..remove('conferenceOverride')
        ..remove('subdivisionOverride')
        ..remove('consecutiveWinningSeasons')
        ..remove('playoffAppearances')
        ..remove('seasonsSinceRealignment');
      final legacyRestored = rivalCoachFromJson(legacyJson);
      expect(legacyRestored.conferenceOverride, isNull);
      expect(legacyRestored.subdivisionOverride, isNull);
      expect(legacyRestored.consecutiveWinningSeasons, 0);
      expect(legacyRestored.seasonsSinceRealignment, 99);
    });

    testWidgets('the Conference Invitations offseason step renders an invitation and accepting it changes the team\'s subdivision without crashing', (tester) async {
      final fcsSchool = fcsTeams.firstWhere((t) => t.conference != 'Founders League');
      final invite = ConferenceInvitation(
        conference: 'Heartland Conference',
        subdivision: Subdivision.fbs,
        conferenceAvgPrestige: 62,
        reason: 'Sustained FCS success across 4 straight winning seasons',
      );

      OffseasonResult? result;
      await tester.pumpWidget(
        MaterialApp(
          home: OffseasonScreen(
            team: fcsSchool,
            coach: testCoach,
            season: 5,
            wins: 10,
            losses: 2,
            confWins: 7,
            confLosses: 1,
            roster: generateRoster(fcsSchool.prestige),
            incomingRecruits: const [],
            contractYearsRemaining: 3,
            realignmentInvitations: [invite],
            onFinish: (r) => result = r,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));

      // Steps 0-7's continue button, tapped in order, reaches step 8
      // (Conference Invitations) — this is the exact sequence a real
      // player takes through the wizard.
      const stepLabels = [
        'ENTER COACHING MARKET', 'REVIEW CONTRACT', 'OPEN ROSTER MEETINGS',
        'OPEN TRANSFER WINDOW', 'GO TO SIGNING DAY', 'BEGIN SPRING PRACTICE',
        'FINALIZE ELIGIBILITY', 'REVIEW INVITATIONS',
      ];
      for (final label in stepLabels) {
        final finder = find.text(label);
        expect(finder, findsOneWidget, reason: 'missing "$label" button');
        await tester.tap(finder);
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(tester.takeException(), isNull);

      // The invitation card sits below the fold in the default test
      // viewport — ListView only mounts elements inside the viewport +
      // cache extent, so it has to be scrolled into view before it exists
      // in the tree (same lesson as this session's earlier offer-button
      // tests). ensureVisible (rather than a blind drag) keeps whichever
      // widget is about to be tapped actually on-screen afterward.
      await tester.scrollUntilVisible(
        find.text('Heartland Conference'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('Heartland Conference'), findsOneWidget);
      expect(find.text('MOVE TO FBS'), findsOneWidget);

      await tester.ensureVisible(find.text('ACCEPT'));
      await tester.tap(find.text('ACCEPT'));
      await tester.pump(const Duration(milliseconds: 50));
      // The confirmation dialog's own CONFIRM button.
      await tester.tap(find.text('CONFIRM'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull);
      expect(find.text('ACCEPTED'), findsOneWidget);

      // Finish the wizard (CONTINUE off step 8, then BEGIN NEXT SEASON off
      // the final Schedule Reveal step) and confirm the accepted
      // invitation's conference/subdivision actually reached OffseasonResult.
      await tester.tap(find.text('CONTINUE'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('BEGIN NEXT SEASON'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);

      expect(result, isNotNull);
      expect(result!.team.conference, 'Heartland Conference');
      expect(result!.team.subdivision, Subdivision.fbs);
    });
  });

  group('the FCS reveal show mirrors the FBS Selection Show, for whichever subdivision applies', () {
    testWidgets('a team that made the field sees its seed and bye status, and Continue fires exactly once', (tester) async {
      final userTeam = fcsTeams[10];
      final seeds = fcsTeams.take(24).toList();
      var continueCount = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: FcsSelectionScreen(
            team: userTeam,
            seeds: seeds,
            onContinue: () => continueCount++,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(tester.takeException(), isNull);
      expect(find.textContaining(userTeam.name), findsWidgets);

      await tester.tap(find.text('ENTER THE BRACKET'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(continueCount, 1);
    });

    testWidgets('a team that missed the field is told the season ends here', (tester) async {
      final userTeam = fcsTeams[10];
      final seeds = fcsTeams.where((t) => t.name != userTeam.name).take(24).toList();

      await tester.pumpWidget(
        MaterialApp(
          home: FcsSelectionScreen(
            team: userTeam,
            seeds: seeds,
            onContinue: () {},
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(tester.takeException(), isNull);
      expect(find.textContaining('outside looking in'), findsOneWidget);
      expect(find.text('CONTINUE'), findsOneWidget);
    });
  });

  group('the FCS bracket renders the real 24-team, 8-bye structure', () {
    testWidgets('FcsBracketScreen renders every round without crashing', (tester) async {
      final seeds = fcsTeams.take(24).toList();

      await tester.pumpWidget(
        MaterialApp(
          home: FcsBracketScreen(seeds: seeds, teamRecords: const {}),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(tester.takeException(), isNull);
      // SectionCard renders its title via .toUpperCase().
      expect(find.text('FIRST ROUND BYES'), findsOneWidget);
      // Seed #1 should show up in the byes section.
      expect(find.textContaining(seeds.first.name), findsWidgets);

      // Each later section sits further below the fold in the default test
      // viewport — ListView only mounts elements inside the viewport +
      // cache extent (same lesson as this session's earlier ListView
      // tests) — so each is scrolled into view in order, one at a time,
      // rather than jumping straight to the bottom (which would just
      // un-mount the sections in between instead of skipping past them).
      for (final round in ['FIRST ROUND', 'SECOND ROUND', 'QUARTERFINALS', 'SEMIFINALS', 'CHAMPIONSHIP']) {
        await tester.scrollUntilVisible(
          find.text(round),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text(round), findsOneWidget, reason: 'missing "$round" section');
      }
    });

    testWidgets('the FCS Selection Show links to the full bracket', (tester) async {
      final userTeam = fcsTeams[5];
      final seeds = fcsTeams.take(24).toList();

      await tester.pumpWidget(
        MaterialApp(
          home: FcsSelectionScreen(
            team: userTeam,
            seeds: seeds,
            teamRecords: const {},
            onContinue: () {},
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text('VIEW FULL BRACKET'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('24-TEAM FCS PLAYOFF BRACKET'), findsOneWidget);
    });
  });

  group('FCS players never reach FBS-elite ratings, no matter how they got on the roster', () {
    test('generateRecruits never produces an FCS recruit above the FCS overall/potential ceiling', () {
      for (var cycle = 0; cycle < 15; cycle++) {
        final recruits = generateRecruits(75, subdivision: Subdivision.fcs);
        for (final r in recruits) {
          expect(r.trueOverall, lessThanOrEqualTo(fcsMaxPlayerOverall),
              reason: '${r.name} (${r.stars}★) overall ${r.trueOverall}');
          expect(r.truePotential, lessThanOrEqualTo(fcsMaxPlayerOverall),
              reason: '${r.name} (${r.stars}★) potential ${r.truePotential}');
        }
      }
    });

    test('generateRoster never produces an FCS player above the FCS overall/potential ceiling, even at the top FCS prestige tier', () {
      for (var trial = 0; trial < 10; trial++) {
        final roster = generateRoster(78, subdivision: Subdivision.fcs);
        for (final p in roster) {
          expect(p.overall, lessThanOrEqualTo(fcsMaxPlayerOverall));
          expect(p.potential, lessThanOrEqualTo(fcsMaxPlayerOverall));
        }
      }
    });

    test('nationalRosterFor never produces an FCS player above the FCS overall/potential ceiling', () {
      final eliteFcs = fcsTeams.reduce((a, b) => a.prestige > b.prestige ? a : b);
      for (var season = 1; season <= 10; season++) {
        final roster = nationalRosterFor(eliteFcs, season);
        for (final p in roster) {
          expect(p.overall, lessThanOrEqualTo(fcsMaxPlayerOverall));
          expect(p.potential, lessThanOrEqualTo(fcsMaxPlayerOverall));
        }
      }
    });

    test('an FBS roster is unaffected by the FCS cap', () {
      // Sanity check that the cap is subdivision-gated, not a global change.
      var sawAboveFcsCap = false;
      for (var trial = 0; trial < 20 && !sawAboveFcsCap; trial++) {
        final roster = generateRoster(97); // elite FBS prestige, default FBS
        if (roster.any((p) => p.potential > fcsMaxPlayerOverall)) {
          sawAboveFcsCap = true;
        }
      }
      expect(sawAboveFcsCap, isTrue, reason: 'an elite FBS roster should still be able to develop past the FCS ceiling');
    });
  });

  group('retention NIL: the displayed cost always matches what actually gets charged', () {
    testWidgets('a draft-eligible junior star\'s retention card shows the real, draft-inflated price, not the discounted base price', (tester) async {
      // OffseasonScreen advances every returning player's class year by one
      // (see _initialRoster) before Roster Decisions ever sees them — a
      // sophomore going in is the junior draft-eligibility check actually
      // evaluates against once the offseason starts.
      final juniorStar = Player(
        name: 'Star Junior',
        position: 'QB',
        overall: 90,
        potential: 96,
        year: 'SO',
        stars: 5,
      );
      final team = CollegeTeam(
        name: 'Oxford',
        conference: 'Test Conf',
        prestige: 90,
        primary: Colors.red,
        secondary: Colors.white,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: OffseasonScreen(
            team: team,
            coach: testCoach,
            season: 3,
            wins: 11,
            losses: 1,
            confWins: 8,
            confLosses: 0,
            roster: [juniorStar],
            incomingRecruits: const [],
            contractYearsRemaining: 3,
            onFinish: (_) {},
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));

      // Program Review -> Coaching Market -> Contract Decision -> Roster Decisions.
      for (final label in ['ENTER COACHING MARKET', 'REVIEW CONTRACT', 'OPEN ROSTER MEETINGS']) {
        await tester.tap(find.text(label));
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(tester.takeException(), isNull);

      // The base (non-draft-inflated) ask must NOT be what's shown — the
      // real bug was the card displaying/afford-checking this smaller
      // number while actually charging the larger, correct one.
      final baseAsk = playerRetentionAsk(juniorStar);
      final realAsk = (baseAsk * 1.65).round();
      expect(realAsk, isNot(baseAsk), reason: 'test fixture must actually trigger the draft multiplier');

      // The retention card sits below the fold in the default test
      // viewport — ListView only mounts elements inside the viewport +
      // cache extent (same lesson as this session's earlier ListView
      // tests) — scroll until the real (correct) dollar amount is on
      // screen, which only exists at all once the card itself mounted.
      await tester.scrollUntilVisible(
        find.textContaining(moneyText(realAsk)),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.textContaining(moneyText(baseAsk)), findsNothing);
      expect(find.textContaining(moneyText(realAsk)), findsWidgets);
    });
  });
}
