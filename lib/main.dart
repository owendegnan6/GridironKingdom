import 'dart:math';
import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Legacy tokens repointed at the leather-ledger palette so every screen
// still written against them repaints without a per-call-site edit.
// kRed previously duplicated kGold's exact value (0xFFF5C451) — a bug, since
// every call site (hot seat, cut, outside-looking-in, no-bowl) is a warning
// state; it now resolves to the palette's actual alert color.
const kGold = GKColors.kingdomBrass;
const kRed = GKColors.stampRed;
const kDark = GKColors.ledgerBlack;
const kCardColor = GKColors.elevatedLeather;
const kBorder = GKColors.stitchLine;
const kGreen = GKColors.fieldGreen;

final Random rng = Random();
final Set<String> usedPlayerNames = {};


class PurchaseManager {
  static const String removeAdsProductId = 'remove_ads_299';
  
  static const String _removeAdsPreferenceKey = 'remove_ads_purchased_on_device';

  static final InAppPurchase _store = InAppPurchase.instance;
  static StreamSubscription<List<PurchaseDetails>>? _purchaseSubscription;

  static ProductDetails? removeAdsProduct;
  static bool adsRemoved = false;
  static bool storeAvailable = false;
  static bool purchasePending = false;

  static Future<void> initialize() async {
    final preferences = await SharedPreferences.getInstance();
    adsRemoved = preferences.getBool(_removeAdsPreferenceKey) ?? false;

    storeAvailable = await _store.isAvailable();

    _purchaseSubscription ??= _store.purchaseStream.listen(
      _handlePurchaseUpdates,
      onError: (Object error) {
        debugPrint('Purchase stream error: $error');
        purchasePending = false;
      },
    );

    if (!storeAvailable) {
      debugPrint('In-app purchases are not currently available.');
      return;
    }

    final response = await _store.queryProductDetails(
      <String>{removeAdsProductId},
    );

    if (response.error != null) {
      debugPrint('Product query failed: ${response.error}');
    }

    if (response.notFoundIDs.isNotEmpty) {
      debugPrint(
        'Remove-ads product was not found: ${response.notFoundIDs.join(', ')}',
      );
    }

    if (response.productDetails.isNotEmpty) {
      removeAdsProduct = response.productDetails.first;
    }
  }

  static Future<void> _handlePurchaseUpdates(
    List<PurchaseDetails> purchases,
  ) async {
    for (final purchase in purchases) {
      if (purchase.productID != removeAdsProductId) {
        if (purchase.pendingCompletePurchase) {
          await _store.completePurchase(purchase);
        }
        continue;
      }

      if (purchase.status == PurchaseStatus.pending) {
        purchasePending = true;
      } else if (purchase.status == PurchaseStatus.purchased ||
          purchase.status == PurchaseStatus.restored) {
        purchasePending = false;
        await _unlockRemoveAds();
      } else if (purchase.status == PurchaseStatus.error ||
          purchase.status == PurchaseStatus.canceled) {
        purchasePending = false;
        debugPrint('Remove-ads purchase did not complete: ${purchase.error}');
      }

      if (purchase.pendingCompletePurchase) {
        await _store.completePurchase(purchase);
      }
    }
  }

  static Future<void> _unlockRemoveAds() async {
    adsRemoved = true;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_removeAdsPreferenceKey, true);
    AdManager.disposeLoadedAd();
  }

  static Future<bool> buyRemoveAds() async {
    if (adsRemoved) return true;
    if (!storeAvailable || removeAdsProduct == null || purchasePending) {
      return false;
    }

    purchasePending = true;

    final purchaseParameter = PurchaseParam(
      productDetails: removeAdsProduct!,
    );

    final started = await _store.buyNonConsumable(
      purchaseParam: purchaseParameter,
    );

    if (!started) {
      purchasePending = false;
    }

    return started;
  }

  static Future<void> restorePurchases() async {
    if (!storeAvailable) return;
    await _store.restorePurchases();
  }

  static String get displayedPrice {
    return removeAdsProduct?.price ?? r'$2.99';
  }
}

class AdManager {
  // Google's published sample interstitial ad unit ID. It always serves a
  // real Google test ad regardless of AdMob account/app review status, so
  // debug builds (including on real devices) keep working while the live
  // ca-app-pub-2128657828917061 account is still pending approval.
  static const String _testInterstitialAdUnitId =
      'ca-app-pub-3940256099942544/4411468910';
  static const String _liveInterstitialAdUnitId =
      'ca-app-pub-2128657828917061/7007447381';

  static String get interstitialAdUnitId =>
      kDebugMode ? _testInterstitialAdUnitId : _liveInterstitialAdUnitId;

  static InterstitialAd? _interstitialAd;
  static bool _isLoading = false;

  static void loadAd() {
    if (PurchaseManager.adsRemoved || _isLoading || _interstitialAd != null) {
      return;
    }

    _isLoading = true;

    InterstitialAd.load(
      adUnitId: interstitialAdUnitId,
      request: const AdRequest(),
      adLoadCallback: InterstitialAdLoadCallback(
        onAdLoaded: (ad) {
          _isLoading = false;

          if (PurchaseManager.adsRemoved) {
            ad.dispose();
            return;
          }

          _interstitialAd = ad;
        },
        onAdFailedToLoad: (error) {
          _isLoading = false;
          _interstitialAd = null;
          debugPrint('Interstitial ad failed to load: $error');
        },
      ),
    );
  }

  static void disposeLoadedAd() {
    _interstitialAd?.dispose();
    _interstitialAd = null;
    _isLoading = false;
  }

  static Future<void> showAd(
    BuildContext context, {
    required VoidCallback onContinue,
  }) async {
    if (PurchaseManager.adsRemoved) {
      onContinue();
      return;
    }

    final ad = _interstitialAd;

    if (ad == null) {
      loadAd();
      onContinue();
      return;
    }

    _interstitialAd = null;

    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (shownAd) async {
        shownAd.dispose();
        loadAd();

        if (context.mounted) {
          await _showRemoveAdsOffer(context);
        }

        if (context.mounted) {
          onContinue();
        }
      },
      onAdFailedToShowFullScreenContent: (shownAd, error) {
        shownAd.dispose();
        debugPrint('Interstitial ad failed to show: $error');
        loadAd();

        if (context.mounted) {
          onContinue();
        }
      },
    );

    ad.show();
  }

  static Future<void> _showRemoveAdsOffer(BuildContext context) async {
    if (PurchaseManager.adsRemoved) return;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        bool working = false;

        return StatefulBuilder(
          builder: (context, setDialogState) {
            Future<void> purchase() async {
              setDialogState(() => working = true);

              final started = await PurchaseManager.buyRemoveAds();

              if (!context.mounted) return;

              if (!started) {
                setDialogState(() => working = false);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'The purchase is not ready yet. Make sure the remove-ads product is active in the App Store.',
                    ),
                  ),
                );
                return;
              }

              Navigator.of(context).pop();
            }

            return AlertDialog(
              backgroundColor: kCardColor,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(22),
              ),
              title: Text(
                'REMOVE ADS?',
                style: TextStyle(
                  color: kGold,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 2,
                ),
              ),
              content: Text(
                'Remove all interstitial ads from Gridiron Kingdom permanently for ${PurchaseManager.displayedPrice}.',
                style: const TextStyle(
                  color: GKColors.parchmentWhite,
                  fontWeight: FontWeight.bold,
                  height: 1.4,
                ),
              ),
              actions: [
                TextButton(
                  onPressed: working
                      ? null
                      : () => Navigator.of(dialogContext).pop(),
                  child: Text(
                    'NO THANKS',
                    style: TextStyle(
                      color: GKColors.fadedInk,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                ElevatedButton(
                  onPressed: working ? null : purchase,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kGold,
                    foregroundColor: GKColors.inkBlack,
                  ),
                  child: Text(
                    working
                        ? 'PLEASE WAIT'
                        : 'BUY ${PurchaseManager.displayedPrice}',
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}


int prestige100(num prestige) {
  return prestige.round().clamp(1, 100);
}

int prestigeTier(num prestige) {
  final p = prestige100(prestige);
  if (p >= 90) return 5;
  if (p >= 80) return 4;
  if (p >= 70) return 3;
  if (p >= 60) return 2;
  return 1;
}



bool isPowerFourConference(String conference) {
  return conference == 'Southern Crown Conference' ||
      conference == 'Heartland Conference' ||
      conference == 'Atlantic Coalition' ||
      conference == 'Frontier Conference';
}

bool earnsPowerFourAutoBid(CollegeTeam team, bool wonConferenceChampionship) {
  return wonConferenceChampionship && isPowerFourConference(team.conference);
}

String prestigeStars(num prestige) => '★' * prestigeTier(prestige);

String prestigeLabel(num prestige) {
  final p = prestige100(prestige);
  if (p >= 90) return 'Elite';
  if (p >= 80) return 'Power';
  if (p >= 70) return 'Rising';
  if (p >= 60) return 'Developing';
  return 'Rebuild';
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await PurchaseManager.initialize();
  await MobileAds.instance.initialize();

  if (!PurchaseManager.adsRemoved) {
    AdManager.loadAd();
  }

  runApp(const RoadToPlayoffsApp());
}


// Careers used to be saved to a JSON file in the OS temp directory, which
// iOS/Android are free to purge at any time (it's meant for disposable
// cache files, not save data) — that's why progress could silently vanish.
// Saves now live in SharedPreferences, which both platforms back with
// durable, app-scoped storage. _legacyTempSaveFilePath is kept only so
// loadCareerSaves can pull forward anything still sitting in the old
// location the first time it runs post-update.
String get _legacyTempSaveFilePath => '${Directory.systemTemp.path}/football_sim_careers.json';
const String _careerSavesPrefsKey = 'football_sim_career_saves_v1';

CollegeTeam teamByName(String name) {
  return g5Teams.firstWhere(
    (team) => team.name == name,
    orElse: () => g5Teams.first,
  );
}

Map<String, dynamic> playerToJson(Player p) => {
  'name': p.name,
  'position': p.position,
  'overall': p.overall,
  'potential': p.potential,
  'year': p.year,
  'stars': p.stars,
};

Player playerFromJson(Map<String, dynamic> json) => Player(
  name: json['name'] ?? 'Player',
  position: json['position'] ?? 'QB',
  overall: json['overall'] ?? 60,
  potential: json['potential'] ?? 70,
  year: json['year'] ?? 'FR',
  stars: json['stars'] ?? 1,
);

Map<String, dynamic> coachToJson(CoachProfile c) => {
  'name': c.name,
  'skinTone': c.skinTone,
  'hairStyle': c.hairStyle,
  'hairColor': c.hairColor,
  'beard': c.beard,
  'glasses': c.glasses,
  'coachType': c.coachType,
  'offensiveScheme': c.offensiveScheme,
  'defensiveScheme': c.defensiveScheme,
};

CoachProfile coachFromJson(Map<String, dynamic> json) => CoachProfile(
  name: json['name'] ?? 'Coach',
  skinTone: json['skinTone'] ?? 'Tan',
  hairStyle: json['hairStyle'] ?? 'Curly',
  hairColor: json['hairColor'] ?? 'Brown',
  beard: json['beard'] ?? 'None',
  glasses: json['glasses'] ?? false,
  coachType: json['coachType'] ?? 'Offensive Mind',
  offensiveScheme: json['offensiveScheme'] ?? 'Air Raid',
  defensiveScheme: json['defensiveScheme'] ?? '4-3 Defense',
);

Map<String, dynamic> trophyToJson(TrophyEntry t) => {
  'year': t.year,
  'type': t.type,
  'title': t.title,
  'opponent': t.opponent,
};

TrophyEntry trophyFromJson(Map<String, dynamic> json) => TrophyEntry(
  year: json['year'] ?? 1,
  type: json['type'] ?? 'Trophy',
  title: json['title'] ?? 'Trophy',
  opponent: json['opponent'] ?? 'Opponent',
);

Map<String, dynamic> historyToJson(NationalTitleHistoryEntry h) => {
  'year': h.year,
  'winner': h.winner,
  'loser': h.loser,
  'score': h.score,
};

NationalTitleHistoryEntry historyFromJson(Map<String, dynamic> json) => NationalTitleHistoryEntry(
  year: json['year'] ?? 1,
  winner: json['winner'] ?? 'Winner',
  loser: json['loser'] ?? 'Loser',
  score: json['score'] ?? '0-0',
);

Future<List<Map<String, dynamic>>> loadCareerSaves() async {
  try {
    final preferences = await SharedPreferences.getInstance();
    var raw = preferences.getString(_careerSavesPrefsKey);

    if (raw == null) {
      // One-time migration from the old temp-directory save file, so a
      // career already in progress isn't stranded by the storage change.
      final legacyFile = File(_legacyTempSaveFilePath);
      if (await legacyFile.exists()) {
        raw = await legacyFile.readAsString();
        await preferences.setString(_careerSavesPrefsKey, raw);
      }
    }

    if (raw == null) return [];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return [];
    return decoded.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  } catch (_) {
    return [];
  }
}

Future<void> writeCareerSaves(List<Map<String, dynamic>> saves) async {
  final preferences = await SharedPreferences.getInstance();
  await preferences.setString(_careerSavesPrefsKey, jsonEncode(saves));
}


String careerKeyFromCoachName(String coachName) {
  final clean = coachName
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^_|_$'), '');

  return clean.isEmpty ? 'coach' : 'coach_$clean';
}

String careerKeyFromSave(Map<String, dynamic> save) {
  final existing = '${save['careerKey'] ?? ''}';
  if (existing.isNotEmpty && existing != 'null') return existing;

  final coachMap = Map<String, dynamic>.from(save['coach'] ?? {});
  return careerKeyFromCoachName('${coachMap['name'] ?? 'Coach'}');
}

Future<void> upsertCareerSave(Map<String, dynamic> save) async {
  final saves = await loadCareerSaves();
  final key = careerKeyFromSave(save);

  save['careerKey'] = key;
  save['id'] = key;

  // This is the important part:
  // remove every older autosave for this coach career, then write the newest one.
  final cleaned = saves.where((s) => careerKeyFromSave(s) != key).toList();
  cleaned.add(save);

  await writeCareerSaves(cleaned);
}


String rankedDisplayName(CollegeTeam team, int rank) {
  if (rank > 0 && rank <= 25) {
    return '#$rank ${team.displayName}';
  }
  return team.displayName;
}

class CollegeTeam {
  final String name;
  final String conference;
  final int prestige;
  final Color primary;
  final Color secondary;
  /// A single emoji hinting at the school's identity (its real mascot).
  /// A visual assist alongside the team name, not a replacement for the
  /// authored monogram badge (GKTeamBadge) used as the actual icon system.
  final String emoji;
  /// The school's real mascot/nickname (e.g. "Buckeyes", "Crimson Tide"),
  /// paired with `name` for display as "Columbus Buckeyes".
  final String mascot;

  const CollegeTeam({
    required this.name,
    required this.conference,
    required this.prestige,
    required this.primary,
    required this.secondary,
    this.emoji = '🏈',
    this.mascot = 'Program',
  });

  bool get isStarterSchool => prestige == 1;
}


class TeamSeasonRecord {
  int wins;
  int losses;
  int confWins;
  int confLosses;

  TeamSeasonRecord({
    this.wins = 0,
    this.losses = 0,
    this.confWins = 0,
    this.confLosses = 0,
  });

  int get gamesPlayed => wins + losses;
  double get winPct => gamesPlayed == 0 ? 0 : wins / gamesPlayed;
  String get overallText => '$wins-$losses';
  String get confText => '$confWins-$confLosses';

  void reset() {
    wins = 0;
    losses = 0;
    confWins = 0;
    confLosses = 0;
  }
}


class TrophyEntry {
  final int year;
  final String type;
  final String title;
  final String opponent;

  const TrophyEntry({
    required this.year,
    required this.type,
    required this.title,
    required this.opponent,
  });
}

class NationalTitleHistoryEntry {
  final int year;
  final String winner;
  final String loser;
  final String score;

  const NationalTitleHistoryEntry({
    required this.year,
    required this.winner,
    required this.loser,
    required this.score,
  });
}

// Every school in this game is an invented identity (see PRODUCT.md/
// DESIGN.md) — no real NCAA institution names, so there is no fixed
// official-name lookup to maintain. Long-form display names are generated
// from the same simple, structural rules real school naming follows.
String universityDisplayName(String internalName) {
  if (internalName.contains('University') ||
      internalName.contains('College') ||
      internalName.contains('Institute') ||
      internalName.contains('Academy')) {
    return internalName;
  }
  if (internalName.endsWith(' State')) {
    return '$internalName University';
  }
  return 'University of $internalName';
}

extension CollegeTeamPhase8Identity on CollegeTeam {
  String get displayName => universityDisplayName(name);
  String get fullName => '$name $mascot';
  String get broadcastInitials => displayName
      .split(RegExp(r'\s+'))
      .where((word) => word.isNotEmpty && !{'of', 'the', 'at'}.contains(word.toLowerCase()))
      .take(4)
      .map((word) => word[0].toUpperCase())
      .join();
}


class CoachProfile {
  final String name;
  final String skinTone;
  final String hairStyle;
  final String hairColor;
  final String beard;
  final bool glasses;
  final String coachType;
  final String offensiveScheme;
  final String defensiveScheme;

  const CoachProfile({
    required this.name,
    required this.skinTone,
    required this.hairStyle,
    required this.hairColor,
    required this.beard,
    this.glasses = false,
    required this.coachType,
    required this.offensiveScheme,
    required this.defensiveScheme,
  });
}


int rosterBaseForPrestige(num prestige) {
  final p = prestige100(prestige);
  if (p >= 95) return 88;
  if (p >= 90) return 84;
  if (p >= 80) return 77;
  if (p >= 70) return 69;
  if (p >= 60) return 62;
  return 54;
}

int playerOverallForTeam(num prestige, {bool starter = false, bool freshman = false}) {
  final p = prestige100(prestige);
  int minOvr;
  int maxOvr;

  if (p >= 95) {
    minOvr = starter ? 84 : 75;
    maxOvr = starter ? 94 : 88;
  } else if (p >= 90) {
    minOvr = starter ? 80 : 72;
    maxOvr = starter ? 91 : 85;
  } else if (p >= 80) {
    minOvr = starter ? 73 : 66;
    maxOvr = starter ? 85 : 78;
  } else if (p >= 70) {
    minOvr = starter ? 66 : 60;
    maxOvr = starter ? 78 : 72;
  } else if (p >= 60) {
    minOvr = starter ? 59 : 54;
    maxOvr = starter ? 70 : 66;
  } else {
    minOvr = starter ? 51 : 45;
    maxOvr = starter ? 64 : 59;
  }

  if (freshman) {
    maxOvr = maxOvr.clamp(45, 78);
    minOvr = (minOvr - 4).clamp(40, maxOvr);
  }

  return minOvr + rng.nextInt(max(1, maxOvr - minOvr + 1));
}

int teamOverallFromPrestige(num prestige) {
  final base = rosterBaseForPrestige(prestige);
  return (base + rng.nextInt(5) - 2).clamp(45, 94);
}


int realisticTeamOverall(num prestige) {
  final p = prestige100(prestige);
  if (p >= 95) return 92 + rng.nextInt(4); // 92-95
  if (p >= 90) return 87 + rng.nextInt(5); // 87-91
  if (p >= 80) return 78 + rng.nextInt(7); // 78-84
  if (p >= 70) return 68 + rng.nextInt(8); // 68-75
  if (p >= 60) return 59 + rng.nextInt(8); // 59-66
  return 50 + rng.nextInt(9);              // 50-58
}

int clampTeamOverallToPrestige(num overall, num prestige) {
  final p = prestige100(prestige);
  if (p >= 95) return overall.round().clamp(88, 96);
  if (p >= 90) return overall.round().clamp(84, 92);
  if (p >= 80) return overall.round().clamp(75, 86);
  if (p >= 70) return overall.round().clamp(65, 78);
  if (p >= 60) return overall.round().clamp(56, 68);
  return overall.round().clamp(48, 60);
}



class Player {
  final String name;
  final String position;
  final int overall;
  final int potential;
  final String year;
  final int stars;

  const Player({
    required this.name,
    required this.position,
    required this.overall,
    required this.potential,
    required this.year,
    required this.stars,
  });

  int get devRoom => potential - overall;
}

/// Compatibility helpers used by awards, mock drafts, roster displays,
/// and the offseason. These are derived rather than persisted, so existing
/// career saves remain compatible with this version.
extension PlayerDynastyDetails on Player {
  int get _stablePlayerSeed {
    var hash = 17;
    for (final unit in name.codeUnits) {
      hash = ((hash * 31) + unit) & 0x7fffffff;
    }
    return hash;
  }

  String get cleanName {
    final separator = name.indexOf('|');
    return separator == -1 ? name : name.substring(0, separator);
  }

  String get awardTeamName {
    final separator = name.indexOf('|');
    if (separator == -1 || separator == name.length - 1) {
      return 'Your Team';
    }
    return name.substring(separator + 1);
  }

  int get teamWins {
    final base = 5 + (_stablePlayerSeed % 8);
    final qualityBoost = overall >= 88
        ? 2
        : overall >= 78
            ? 1
            : 0;
    return (base + qualityBoost).clamp(0, 15);
  }

  int get passYards {
    if (position != 'QB') return 0;
    return 1900 + (_stablePlayerSeed % 2100) + max(0, overall - 70) * 18;
  }

  int get rushYards {
    if (position != 'HB' && position != 'RB' && position != 'QB') {
      return 0;
    }

    final base = position == 'QB' ? 180 : 650;
    final range = position == 'QB' ? 620 : 1150;
    return base + (_stablePlayerSeed % range) + max(0, overall - 65) * 8;
  }

  int get recYards {
    if (position != 'WR' && position != 'TE' && position != 'HB') {
      return 0;
    }

    final base = position == 'HB' ? 120 : 500;
    final range = position == 'HB' ? 480 : 1250;
    return base + (_stablePlayerSeed % range) + max(0, overall - 65) * 7;
  }

  int get touchdowns {
    final production = switch (position) {
      'QB' => passYards ~/ 420,
      'HB' || 'RB' => rushYards ~/ 180,
      'WR' || 'TE' => recYards ~/ 190,
      _ => 1 + (_stablePlayerSeed % 4),
    };
    return production.clamp(1, 45);
  }

  int get sacks {
    if (position != 'DE' && position != 'DL' && position != 'LB') {
      return 0;
    }
    return 2 + (_stablePlayerSeed % 12) + max(0, overall - 75) ~/ 4;
  }

  int get interceptions {
    if (position != 'DB' &&
        position != 'CB' &&
        position != 'S' &&
        position != 'LB') {
      return 0;
    }
    return _stablePlayerSeed % 7;
  }

  double get ppg {
    final scoring = switch (position) {
      'QB' => touchdowns * 1.45,
      'HB' || 'RB' => touchdowns * 1.25,
      'WR' || 'TE' => touchdowns * 1.15,
      _ => (sacks * .35) + (interceptions * .75),
    };
    return double.parse(scoring.toStringAsFixed(1));
  }
}

int awardOverall(Player player) {
  final classAdjustment = switch (player.year) {
    'SR' => 2,
    'JR' => 1,
    'FR' => -1,
    _ => 0,
  };

  return (player.overall + classAdjustment).clamp(40, 99);
}

class Recruit {
  final String name;
  final String position;
  final String state;
  final int stars;
  final int trueOverall;
  final int truePotential;
  final int interest;
  int scouts;
  bool offered;
  String? committedSchool;
  int? decisionWindow;
  bool commitmentPopupShown = false;

  Recruit({
    required this.name,
    required this.position,
    required this.state,
    required this.stars,
    required this.trueOverall,
    required this.truePotential,
    required this.interest,
    this.scouts = 0,
    this.offered = false,
    this.committedSchool,
    this.decisionWindow,
    this.commitmentPopupShown = false,
  });

  String get scoutText {
    if (scouts == 0) return 'OVR ??? • POT ???';
    if (scouts == 1) {
      return 'OVR ${trueOverall - 10}-${trueOverall + 10} • POT ${truePotential - 10}-${truePotential + 8}';
    }
    if (scouts == 2) {
      return 'OVR ${trueOverall - 4}-${trueOverall + 4} • POT ${truePotential - 5}-${truePotential + 4}';
    }
    return 'OVR $trueOverall • POT $truePotential';
  }

  String get tag {
    if (scouts < 3) return '';

    final expected = switch (stars) {
      5 => 88,
      4 => 78,
      3 => 68,
      2 => 58,
      _ => 48,
    };

    if (trueOverall >= expected + 7 || truePotential >= trueOverall + 16) {
      return 'GEM';
    }

    if (trueOverall <= expected - 5 || truePotential <= trueOverall + 3) {
      return 'BUST';
    }

    return 'NORMAL';
  }

  int get expectedOverall {
    return switch (stars) {
      1 => 50,
      2 => 60,
      3 => 70,
      4 => 80,
      _ => 88,
    };
  }

  int get hiddenDelta {
    final raw = name.hashCode.abs() % 100;
    if (raw < 9) return 9 + (raw % 9);
    if (raw < 21) return -5 - (raw % 8);
    return (raw % 9) - 4;
  }

  int get displayedOverall => cappedFreshmanOverall(expectedOverall + hiddenDelta);

  int get estimatedOverall {
    final miss = ((name.hashCode ~/ 11).abs() % 13) - 6;
    final adjusted = miss == 0 ? 4 : miss;
    return cappedFreshmanOverall(expectedOverall + adjusted);
  }

  int get fakeCardOverall {
    final miss = ((name.hashCode ~/ 17).abs() % 17) - 8;
    final adjusted = miss == 0 ? 6 : miss;
    return cappedFreshmanOverall(expectedOverall + adjusted);
  }

  bool get isGem => hiddenDelta >= 9;
  bool get isBust => hiddenDelta <= -5;
  String get gemLabel => isGem ? 'GEM' : isBust ? 'BUST' : '';

  String get cardOverallText {
    if (scouts <= 0) return '$fakeCardOverall?';
    if (scouts == 1) return '~$estimatedOverall';
    if (scouts == 2) return '${(displayedOverall - 5).clamp(40, 94)}-${(displayedOverall + 5).clamp(40, 94)}';
    return '$displayedOverall';
  }

  String get potentialText {
    if (scouts <= 0) return 'POT ?';
    if (scouts == 1) return 'POT ~';
    if (scouts == 2) return 'POT ${(truePotential - 6).clamp(40, 94)}-${(truePotential + 4).clamp(40, 94)}';
    return 'POT $truePotential';
  }

  String get scoutingReport {
    if (scouts <= 0) return '${stars}★ recruit • Initial grade: $fakeCardOverall?';
    if (scouts == 1) return 'Estimate: ~$estimatedOverall OVR';
    if (scouts == 2) return 'Range: ${(displayedOverall - 5).clamp(40, 94)}-${(displayedOverall + 5).clamp(40, 94)} OVR • $potentialText';
    return 'Exact: $displayedOverall OVR • $truePotential POT';
  }

}


extension RecruitFootballDetails on Recruit {
  int get detailSeed => name.hashCode.abs();

  String get heightText {
    final base = switch (position) {
      'QB' => 74,
      'HB' => 70,
      'WR' => 73,
      'TE' => 76,
      'DE' => 76,
      'LB' => 74,
      'DB' => 71,
      _ => 73,
    };
    final inches = base + (detailSeed % 5) - 2;
    return "${inches ~/ 12}'${inches % 12}\"";
  }

  int get weight {
    final base = switch (position) {
      'QB' => 215,
      'HB' => 205,
      'WR' => 195,
      'TE' => 245,
      'DE' => 255,
      'LB' => 230,
      'DB' => 190,
      _ => 210,
    };
    return base + (detailSeed % 31) - 15;
  }

  double get forty {
    final base = switch (position) {
      'HB' => 4.48,
      'WR' => 4.46,
      'DB' => 4.50,
      'QB' => 4.78,
      'LB' => 4.68,
      'TE' => 4.72,
      'DE' => 4.76,
      _ => 4.70,
    };
    return double.parse((base + ((detailSeed % 21) - 10) / 100).toStringAsFixed(2));
  }

  int get bench => 225 + (detailSeed % 15);
  int get squat => 405 + (detailSeed % 26) * 5;
  int get vertical => 28 + (detailSeed % 13);

  int get passYards => position == 'QB' ? 1800 + (detailSeed % 2200) : 0;
  int get rushYards => position == 'HB' || position == 'QB' ? 500 + (detailSeed % 1700) : 0;
  int get recYards => position == 'WR' || position == 'TE' ? 450 + (detailSeed % 1600) : 0;
  int get tackles => position == 'DE' || position == 'LB' || position == 'DB' ? 35 + (detailSeed % 75) : 0;
  int get sacks => position == 'DE' || position == 'LB' ? 3 + (detailSeed % 15) : 0;
  int get interceptions => position == 'DB' || position == 'LB' ? detailSeed % 7 : 0;

  String get archetype {
    return switch (position) {
      'QB' => detailSeed % 2 == 0 ? 'Pocket Passer' : 'Dual Threat',
      'HB' => detailSeed % 2 == 0 ? 'Power Back' : 'Speed Back',
      'WR' => detailSeed % 2 == 0 ? 'Deep Threat' : 'Route Runner',
      'TE' => detailSeed % 2 == 0 ? 'Receiving TE' : 'Blocking TE',
      'DE' => detailSeed % 2 == 0 ? 'Edge Rusher' : 'Run Stopper',
      'LB' => detailSeed % 2 == 0 ? 'Field General' : 'Blitzer',
      'DB' => detailSeed % 2 == 0 ? 'Lockdown Corner' : 'Ball Hawk',
      _ => 'Athlete',
    };
  }

    int get starOverallFloor {
    return switch (stars) {
      1 => 45,
      2 => 56,
      3 => 66,
      4 => 76,
      _ => 86,
    };
  }

  int get nextStarOverallFloor {
    return switch (stars) {
      1 => 56,
      2 => 66,
      3 => 76,
      4 => 86,
      _ => 100,
    };
  }

  int get expectedOverall {
    return switch (stars) {
      1 => 50,
      2 => 60,
      3 => 70,
      4 => 80,
      _ => 90,
    };
  }

  int get hiddenDelta {
    final raw = name.hashCode.abs() % 100;
    if (raw < 9) return 9 + (raw % 9); // gem: +9 to +17
    if (raw < 21) return -5 - (raw % 8); // bust: -5 to -12
    return ((raw % 9) - 4); // normal: -4 to +4
  }

  int get displayedOverall => cappedFreshmanOverall(expectedOverall + hiddenDelta);


  bool get isGem => hiddenDelta >= 9;

  bool get isBust => hiddenDelta <= -5;

  String get gemLabel => isGem ? 'GEM' : isBust ? 'BUST' : '';

  String get shortFit {
    if (committedSchool != null) return committedSchool!;
    if (stars >= 5) return 'Prestige';
    if (truePotential >= trueOverall + 16) return 'Development';
    if (interest >= 75) return 'Strong Fit';
    return 'Open';
  }

String get personality {
    if (stars >= 5) return 'Wants Prestige + Playing Time';
    if (truePotential >= trueOverall + 16) return 'Wants Development';
    if (interest >= 75) return 'Program Fit';
    return 'Wants Early Offers';
  }
}


class NameGenerator {
  static const List<String> firstNames = [
    'Aaron',
    'Abel',
    'Abraham',
    'Adam',
    'Adrian',
    'Aiden',
    'Alan',
    'Albert',
    'Alec',
    'Alejandro',
    'Alex',
    'Alexander',
    'Alfred',
    'Andre',
    'Andrew',
    'Angel',
    'Anthony',
    'Antonio',
    'Archer',
    'Arthur',
    'Asher',
    'Ashton',
    'August',
    'Austin',
    'Axel',
    'Beau',
    'Beckett',
    'Benjamin',
    'Bennett',
    'Blake',
    'Brady',
    'Brandon',
    'Brayden',
    'Brendan',
    'Brian',
    'Brock',
    'Brody',
    'Brooks',
    'Bryce',
    'Caleb',
    'Callum',
    'Camden',
    'Cameron',
    'Carlos',
    'Carson',
    'Carter',
    'Casey',
    'Cayden',
    'Charles',
    'Chase',
    'Christian',
    'Christopher',
    'Cody',
    'Cole',
    'Colin',
    'Colton',
    'Connor',
    'Cooper',
    'Corbin',
    'Cristian',
    'Cruz',
    'Cyrus',
    'Dakota',
    'Dalton',
    'Damian',
    'Daniel',
    'Dante',
    'Darius',
    'David',
    'Dawson',
    'Dean',
    'Declan',
    'Derek',
    'Devin',
    'Diego',
    'Dominic',
    'Donovan',
    'Drew',
    'Dylan',
    'Easton',
    'Eddie',
    'Edward',
    'Eli',
    'Elijah',
    'Elliot',
    'Emerson',
    'Emmett',
    'Enzo',
    'Eric',
    'Ethan',
    'Evan',
    'Everett',
    'Ezekiel',
    'Ezra',
    'Felix',
    'Fernando',
    'Finn',
    'Finley',
    'Francisco',
    'Frank',
    'Gabriel',
    'Gage',
    'Garrett',
    'Gavin',
    'George',
    'Giovanni',
    'Grant',
    'Grayson',
    'Gregory',
    'Griffin',
    'Harley',
    'Harrison',
    'Hayden',
    'Henry',
    'Holden',
    'Hudson',
    'Hugo',
    'Hunter',
    'Ian',
    'Isaac',
    'Isaiah',
    'Ivan',
    'Jack',
    'Jackson',
    'Jacob',
    'Jaden',
    'Jalen',
    'James',
    'Jared',
    'Jason',
    'Javier',
    'Jaxon',
    'Jay',
    'Jayce',
    'Jayden',
    'Jaylen',
    'Jeremy',
    'Jesse',
    'Jesus',
    'Jett',
    'Joel',
    'John',
    'Jonah',
    'Jonathan',
    'Jordan',
    'Jose',
    'Joseph',
    'Joshua',
    'Josiah',
    'Juan',
    'Jude',
    'Julian',
    'Justin',
    'Kai',
    'Kaleb',
    'Kameron',
    'Karter',
    'Kayden',
    'Keegan',
    'Kellan',
    'Kendrick',
    'Kevin',
    'Kian',
    'Kingston',
    'Knox',
    'Kobe',
    'Kyle',
    'Landon',
    'Lane',
    'Leo',
    'Leon',
    'Leonardo',
    'Levi',
    'Liam',
    'Lincoln',
    'Logan',
    'Luca',
    'Lucas',
    'Luis',
    'Luke',
    'Maddox',
    'Malachi',
    'Malik',
    'Marco',
    'Marcus',
    'Mario',
    'Marshall',
    'Martin',
    'Mason',
    'Mateo',
    'Matthew',
    'Maverick',
    'Max',
    'Maxwell',
    'Mekhi',
    'Micah',
    'Michael',
    'Miles',
    'Milo',
    'Mitchell',
    'Nathan',
    'Nathaniel',
    'Nico',
    'Nicholas',
    'Noah',
    'Nolan',
    'Oliver',
    'Omar',
    'Orion',
    'Oscar',
    'Owen',
    'Parker',
    'Patrick',
    'Paxton',
    'Pedro',
    'Phoenix',
    'Porter',
    'Preston',
    'Quentin',
    'Quincy',
    'Rafael',
    'Reed',
    'Reid',
    'Remington',
    'Rhett',
    'Ricardo',
    'River',
    'Robert',
    'Roman',
    'Ronan',
    'Rowan',
    'Ruben',
    'Ryan',
    'Ryder',
    'Samuel',
    'Santiago',
    'Sawyer',
    'Sebastian',
    'Seth',
    'Shane',
    'Silas',
    'Simon',
    'Spencer',
    'Steven',
    'Tanner',
    'Tate',
    'Theo',
    'Theodore',
    'Thomas',
    'Timothy',
    'Deshawn',
    'Marquis',
    'Jamal',
    'Terrell',
    'Devonte',
    'Malachi',
    'Emiliano',
    'Mateo',
    'Rafael',
    'Salvador',
    'Kai',
    'Minh',
    'Maddox',
    'Sawyer',
    'Weston',
    'Siaosi',
    'Manoa',
    'Peni',
    'Sione',
    'Tavita',
    'Amosa',
    'Fetu',
    'Elan',
    'Quincy',
    'Sterling',
  ];

  static const List<String> lastNames = [
    'Adams',
    'Alexander',
    'Allen',
    'Alvarez',
    'Anderson',
    'Andrews',
    'Armstrong',
    'Arnold',
    'Atkins',
    'Austin',
    'Bailey',
    'Baker',
    'Banks',
    'Barber',
    'Barker',
    'Barnes',
    'Barnett',
    'Barrett',
    'Bates',
    'Bell',
    'Bennett',
    'Benson',
    'Berry',
    'Bishop',
    'Black',
    'Blair',
    'Blake',
    'Boone',
    'Bowen',
    'Boyd',
    'Bradley',
    'Brady',
    'Brewer',
    'Brooks',
    'Brown',
    'Bryant',
    'Buchanan',
    'Burke',
    'Burns',
    'Burton',
    'Butler',
    'Byrd',
    'Campbell',
    'Cannon',
    'Carlson',
    'Carpenter',
    'Carr',
    'Carroll',
    'Carter',
    'Casey',
    'Castillo',
    'Chambers',
    'Chapman',
    'Clark',
    'Clay',
    'Clements',
    'Cobb',
    'Cole',
    'Coleman',
    'Collins',
    'Cook',
    'Cooper',
    'Cox',
    'Crawford',
    'Cruz',
    'Cunningham',
    'Curry',
    'Dalton',
    'Daniels',
    'Davidson',
    'Davis',
    'Dawson',
    'Dean',
    'Diaz',
    'Dixon',
    'Douglas',
    'Doyle',
    'Duncan',
    'Dunn',
    'Edwards',
    'Elliott',
    'Ellis',
    'Evans',
    'Farmer',
    'Ferguson',
    'Fields',
    'Fisher',
    'Fleming',
    'Fletcher',
    'Flores',
    'Ford',
    'Foster',
    'Fowler',
    'Fox',
    'Franklin',
    'Freeman',
    'French',
    'Fuller',
    'Garcia',
    'Gardner',
    'Garrett',
    'George',
    'Gibson',
    'Gilbert',
    'Gill',
    'Gordon',
    'Graham',
    'Grant',
    'Graves',
    'Gray',
    'Green',
    'Greene',
    'Griffin',
    'Hall',
    'Hamilton',
    'Hammond',
    'Hampton',
    'Hansen',
    'Hardy',
    'Harper',
    'Harris',
    'Harrison',
    'Hart',
    'Harvey',
    'Hawkins',
    'Hayes',
    'Henderson',
    'Henry',
    'Hernandez',
    'Hicks',
    'Hill',
    'Hines',
    'Hoffman',
    'Holland',
    'Holmes',
    'Holt',
    'Hoover',
    'Howard',
    'Howell',
    'Hudson',
    'Hughes',
    'Hunt',
    'Hunter',
    'Jackson',
    'Jacobs',
    'James',
    'Jenkins',
    'Jennings',
    'Jensen',
    'Jimenez',
    'Johnson',
    'Johnston',
    'Jones',
    'Jordan',
    'Joseph',
    'Kelley',
    'Kelly',
    'Kennedy',
    'Kim',
    'King',
    'Knight',
    'Lane',
    'Lawson',
    'Lee',
    'Leonard',
    'Lewis',
    'Little',
    'Long',
    'Lopez',
    'Lowe',
    'Lucas',
    'Lynch',
    'Mack',
    'Mann',
    'Marshall',
    'Martin',
    'Martinez',
    'Mason',
    'Matthews',
    'Maxwell',
    'May',
    'McBride',
    'McCarthy',
    'McCoy',
    'McDaniel',
    'McDonald',
    'McKenzie',
    'Mendez',
    'Meyer',
    'Miles',
    'Miller',
    'Mills',
    'Mitchell',
    'Montgomery',
    'Moore',
    'Morales',
    'Morgan',
    'Morris',
    'Morrison',
    'Murphy',
    'Murray',
    'Myers',
    'Nelson',
    'Newman',
    'Newton',
    'Nichols',
    'Norman',
    'Norris',
    'Oliver',
    'Ortiz',
    'Owens',
    'Palmer',
    'Parker',
    'Patterson',
    'Payne',
    'Pearson',
    'Perry',
    'Peters',
    'Peterson',
    'Phillips',
    'Pierce',
    'Porter',
    'Powell',
    'Price',
    'Ramirez',
    'Reed',
    'Reeves',
    'Reynolds',
    'Rhodes',
    'Rice',
    'Richards',
    'Richardson',
    'Riley',
    'Rivera',
    'Roberts',
    'Robertson',
    'Robinson',
    'Rodgers',
    'Rodriguez',
    'Rogers',
    'Rose',
    'Ross',
    'Russell',
    'Ryan',
    'Sanders',
    'Santiago',
    'Schmidt',
    'Scott',
    'Shaw',
    'Shelton',
    'Fifita',
    'Fonoti',
    'Tuputupu',
    'Langi',
    'Havili',
    'Faleolo',
    'Sopoaga',
    'Nguyen',
    'Tran',
    'Delacroix',
    'Beaumont',
    'Okafor',
    'Adeyemi',
    'Osei',
    'Diallo',
    'Villanueva',
    'Marquez',
    'Cordero',
    'Solano',
  ];

  static String generate() {
    for (int i = 0; i < 100000; i++) {
      final first = firstNames[rng.nextInt(firstNames.length)];
      final last = lastNames[rng.nextInt(lastNames.length)];
      final name = '$first $last';

      if (usedPlayerNames.add(name)) {
        return name;
      }
    }

    throw StateError('No unused player names remain in this career.');
  }
}

const List<CollegeTeam> g5Teams = [
  CollegeTeam(name: 'Portage', emoji: '🦘', mascot: 'Zips', conference: 'Great Lakes Conference', prestige: 55, primary: Color(0xFF00285E), secondary: Color(0xFFFFC72C)),
  CollegeTeam(name: 'Ravenna State', emoji: '⚡', mascot: 'Golden Flashes', conference: 'Great Lakes Conference', prestige: 55, primary: Color(0xFF002664), secondary: Color(0xFFEAAA00)),
  CollegeTeam(name: 'Monroe', emoji: '🦅', mascot: 'Warhawks', conference: 'Sun Belt', prestige: 55, primary: Color(0xFF800029), secondary: Color(0xFFFFB81C)),
  CollegeTeam(name: 'Huntsville', emoji: '🐻', mascot: 'Bearkats', conference: 'Crossroads Conference', prestige: 55, primary: Color(0xFFFF6A00), secondary: Color(0xFF00205B)),
  CollegeTeam(name: 'Kennesaw', emoji: '🦉', mascot: 'Owls', conference: 'Crossroads Conference', prestige: 55, primary: Color(0xFFFFC629), secondary: Color(0xFF000000)),
  CollegeTeam(name: 'Biscayne', emoji: '🐆', mascot: 'Panthers', conference: 'Crossroads Conference', prestige: 55, primary: Color(0xFF081E3F), secondary: Color(0xFFB6862C)),
  CollegeTeam(name: 'El Paso', emoji: '⛏️', mascot: 'Miners', conference: 'Crossroads Conference', prestige: 55, primary: Color(0xFFFF8200), secondary: Color(0xFF041E42)),
  CollegeTeam(name: 'Amherst', emoji: '🎖️', mascot: 'Minutemen', conference: 'Independent', prestige: 55, primary: Color(0xFF971B2F), secondary: Color(0xFFFFFFFF)),
  CollegeTeam(name: 'Uptown', emoji: '🪙', mascot: '49ers', conference: 'Anchor Conference', prestige: 55, primary: Color(0xFF005035), secondary: Color(0xFFA49665)),
  CollegeTeam(name: 'Reno', emoji: '🐺', mascot: 'Wolf Pack', conference: 'Summit West Conference', prestige: 55, primary: Color(0xFF003366), secondary: Color(0xFF807F84)),
  CollegeTeam(name: 'Ashworth', emoji: '🦉', mascot: 'Owls', conference: 'Anchor Conference', prestige: 65, primary: Color(0xFF00205B), secondary: Color(0xFFC1C6C8)),
  CollegeTeam(name: 'Maumee', emoji: '🚀', mascot: 'Rockets', conference: 'Great Lakes Conference', prestige: 75, primary: Color(0xFF15397F), secondary: Color(0xFFFFD200)),
  CollegeTeam(name: 'Lynchburg', emoji: '🔥', mascot: 'Flames', conference: 'Crossroads Conference', prestige: 75, primary: Color(0xFF002D62), secondary: Color(0xFFC41230)),
  CollegeTeam(name: 'Bluff City', emoji: '🐯', mascot: 'Tigers', conference: 'Anchor Conference', prestige: 85, primary: Color(0xFF003087), secondary: Color(0xFF898D8D)),
  CollegeTeam(name: 'Crescent City', emoji: '🌊', mascot: 'Green Wave', conference: 'Anchor Conference', prestige: 85, primary: Color(0xFF006747), secondary: Color(0xFF418FDE)),
  CollegeTeam(name: 'Colorado Springs', emoji: '🦅', mascot: 'Falcons', conference: 'Summit West Conference', prestige: 75, primary: Color(0xFF003087), secondary: Color(0xFFA7A8AA)),
  CollegeTeam(name: 'Boone', emoji: '⛰️', mascot: 'Mountaineers', conference: 'Sun Belt', prestige: 75, primary: Color(0xFF000000), secondary: Color(0xFFFFCC00)),
  CollegeTeam(name: 'West Point', emoji: '⚔️', mascot: 'Black Knights', conference: 'Anchor Conference', prestige: 75, primary: Color(0xFF000000), secondary: Color(0xFFD4BF91)),
  CollegeTeam(name: 'Muncie', emoji: '🐦', mascot: 'Cardinals', conference: 'Great Lakes Conference', prestige: 65, primary: Color(0xFFBA0C2F), secondary: Color(0xFF000000)),
  CollegeTeam(name: 'Cedar Green', emoji: '🦅', mascot: 'Falcons', conference: 'Great Lakes Conference', prestige: 65, primary: Color(0xFFFF7300), secondary: Color(0xFF4F2C1D)),
  CollegeTeam(name: 'Niagara', emoji: '🐂', mascot: 'Bulls', conference: 'Great Lakes Conference', prestige: 65, primary: Color(0xFF005BBB), secondary: Color(0xFFFFFFFF)),
  CollegeTeam(name: 'Mount Pleasant', emoji: '🌲', mascot: 'Chippewas', conference: 'Great Lakes Conference', prestige: 65, primary: Color(0xFF6A0032), secondary: Color(0xFFFFC82E)),
  CollegeTeam(name: 'Conway', emoji: '🐓', mascot: 'Chanticleers', conference: 'Sun Belt', prestige: 75, primary: Color(0xFF006F71), secondary: Color(0xFFA27752)),
  CollegeTeam(name: 'Fort Collins', emoji: '🐏', mascot: 'Rams', conference: 'Summit West Conference', prestige: 75, primary: Color(0xFF1E4D2B), secondary: Color(0xFFC8C372)),
  CollegeTeam(name: 'Greenville', emoji: '🏴‍☠️', mascot: 'Pirates', conference: 'Anchor Conference', prestige: 75, primary: Color(0xFF592A8A), secondary: Color(0xFFFDC82F)),
  CollegeTeam(name: 'Ypsilanti', emoji: '🦅', mascot: 'Eagles', conference: 'Great Lakes Conference', prestige: 55, primary: Color(0xFF006633), secondary: Color(0xFFFFFFFF)),
  CollegeTeam(name: 'Fresno', emoji: '🐶', mascot: 'Bulldogs', conference: 'Summit West Conference', prestige: 75, primary: Color(0xFFDB0032), secondary: Color(0xFF002E6D)),
  CollegeTeam(name: 'Statesboro', emoji: '🦅', mascot: 'Eagles', conference: 'Sun Belt', prestige: 75, primary: Color(0xFF041E42), secondary: Color(0xFFFFFFFF)),
  CollegeTeam(name: 'Atlanta', emoji: '🐆', mascot: 'Panthers', conference: 'Sun Belt', prestige: 65, primary: Color(0xFF0039A6), secondary: Color(0xFFC60C30)),
  CollegeTeam(name: 'Honolulu', emoji: '🌈', mascot: 'Rainbow Warriors', conference: 'Summit West Conference', prestige: 65, primary: Color(0xFF024731), secondary: Color(0xFFC8C8C8)),
  CollegeTeam(name: 'Harrisonburg', emoji: '👑', mascot: 'Dukes', conference: 'Sun Belt', prestige: 85, primary: Color(0xFF450084), secondary: Color(0xFFCBB677)),
  CollegeTeam(name: 'Lafayette', emoji: '🌶️', mascot: 'Ragin\' Cajuns', conference: 'Sun Belt', prestige: 75, primary: Color(0xFFCE181E), secondary: Color(0xFF000000)),
  CollegeTeam(name: 'Ruston', emoji: '🐶', mascot: 'Bulldogs', conference: 'Crossroads Conference', prestige: 55, primary: Color(0xFF002F8B), secondary: Color(0xFFE31B23)),
  CollegeTeam(name: 'Huntington', emoji: '🐃', mascot: 'Thundering Herd', conference: 'Sun Belt', prestige: 55, primary: Color(0xFF00B140), secondary: Color(0xFF000000)),
  CollegeTeam(name: 'Oxford', emoji: '🦅', mascot: 'RedHawks', conference: 'Great Lakes Conference', prestige: 55, primary: Color(0xFFC41230), secondary: Color(0xFFFFFFFF)),
  CollegeTeam(name: 'Murfreesboro', emoji: '⚔️', mascot: 'Blue Raiders', conference: 'Crossroads Conference', prestige: 55, primary: Color(0xFF0066CC), secondary: Color(0xFFC0C0C0)),
  CollegeTeam(name: 'Annapolis', emoji: '⚓', mascot: 'Midshipmen', conference: 'Anchor Conference', prestige: 55, primary: Color(0xFF000080), secondary: Color(0xFFC5B783)),
  CollegeTeam(name: 'Albuquerque', emoji: '🐺', mascot: 'Lobos', conference: 'Summit West Conference', prestige: 55, primary: Color(0xFFBA0C2F), secondary: Color(0xFFA7A8AA)),
  CollegeTeam(name: 'Las Cruces', emoji: '🌾', mascot: 'Aggies', conference: 'Crossroads Conference', prestige: 55, primary: Color(0xFF861F41), secondary: Color(0xFFFFFFFF)),
  CollegeTeam(name: 'Denton', emoji: '🦅', mascot: 'Mean Green', conference: 'Anchor Conference', prestige: 65, primary: Color(0xFF00853E), secondary: Color(0xFF000000)),
  CollegeTeam(name: 'DeKalb', emoji: '🐺', mascot: 'Huskies', conference: 'Great Lakes Conference', prestige: 65, primary: Color(0xFFBA0C2F), secondary: Color(0xFF000000)),
  CollegeTeam(name: 'Athens', emoji: '🐈', mascot: 'Bobcats', conference: 'Great Lakes Conference', prestige: 75, primary: Color(0xFF00694E), secondary: Color(0xFFFFFFFF)),
  CollegeTeam(name: 'Norfolk', emoji: '👑', mascot: 'Monarchs', conference: 'Sun Belt', prestige: 65, primary: Color(0xFF003057), secondary: Color(0xFFA7A8AA)),
  CollegeTeam(name: 'San Diego', emoji: '🌊', mascot: 'Aztecs', conference: 'Summit West Conference', prestige: 85, primary: Color(0xFFA6192E), secondary: Color(0xFF000000)),
  CollegeTeam(name: 'San Jose', emoji: '🛡️', mascot: 'Spartans', conference: 'Summit West Conference', prestige: 65, primary: Color(0xFF0055A2), secondary: Color(0xFFE5A823)),
  CollegeTeam(name: 'Mobile', emoji: '🐆', mascot: 'Jaguars', conference: 'Sun Belt', prestige: 65, primary: Color(0xFF00205B), secondary: Color(0xFFBF0D3E)),
  CollegeTeam(name: 'Tampa', emoji: '🐂', mascot: 'Bulls', conference: 'Anchor Conference', prestige: 75, primary: Color(0xFF006747), secondary: Color(0xFFCFC493)),
  CollegeTeam(name: 'Hattiesburg', emoji: '🦅', mascot: 'Golden Eagles', conference: 'Sun Belt', prestige: 65, primary: Color(0xFF000000), secondary: Color(0xFFFFC72C)),
  CollegeTeam(name: 'Broad Street', emoji: '🦉', mascot: 'Owls', conference: 'Anchor Conference', prestige: 65, primary: Color(0xFF9D2235), secondary: Color(0xFFFFFFFF)),
  CollegeTeam(name: 'San Marcos', emoji: '🐈', mascot: 'Bobcats', conference: 'Sun Belt', prestige: 65, primary: Color(0xFF501214), secondary: Color(0xFFB3A369)),
  CollegeTeam(name: 'Pike County', emoji: '🛡️', mascot: 'Trojans', conference: 'Sun Belt', prestige: 75, primary: Color(0xFF8A2432), secondary: Color(0xFFC8C8C8)),
  CollegeTeam(name: 'Green Country', emoji: '🌀', mascot: 'Golden Hurricane', conference: 'Anchor Conference', prestige: 65, primary: Color(0xFF002D72), secondary: Color(0xFFC8102E)),
  CollegeTeam(name: 'Birmingham', emoji: '🔥', mascot: 'Blazers', conference: 'Anchor Conference', prestige: 75, primary: Color(0xFF1E6B52), secondary: Color(0xFFF2A900)),
  CollegeTeam(name: 'Storrs', emoji: '🐺', mascot: 'Huskies', conference: 'Independent', prestige: 65, primary: Color(0xFF000E2F), secondary: Color(0xFFFFFFFF)),
  CollegeTeam(name: 'Logan', emoji: '🌾', mascot: 'Aggies', conference: 'Summit West Conference', prestige: 75, primary: Color(0xFF00263A), secondary: Color(0xFF8A8D8F)),
  CollegeTeam(name: 'San Antonio', emoji: '🏃', mascot: 'Roadrunners', conference: 'Anchor Conference', prestige: 75, primary: Color(0xFF0C2340), secondary: Color(0xFFF15A22)),
  CollegeTeam(name: 'Warren County', emoji: '⛰️', mascot: 'Hilltoppers', conference: 'Crossroads Conference', prestige: 75, primary: Color(0xFFC60C30), secondary: Color(0xFFFFFFFF)),
  CollegeTeam(name: 'Kalamazoo', emoji: '🐴', mascot: 'Broncos', conference: 'Great Lakes Conference', prestige: 65, primary: Color(0xFF6C4023), secondary: Color(0xFFB5A167)),
  CollegeTeam(name: 'Laramie', emoji: '🤠', mascot: 'Cowboys', conference: 'Summit West Conference', prestige: 65, primary: Color(0xFF492F24), secondary: Color(0xFFFFD100)),
  CollegeTeam(name: 'Tuscaloosa', emoji: '🐘', mascot: 'Crimson Tide', conference: 'Southern Crown Conference', prestige: 95, primary: Color(0xFF9E1B32), secondary: Color(0xFFFFFFFF)),
  CollegeTeam(name: 'Athens-Clarke', emoji: '🐶', mascot: 'Bulldogs', conference: 'Southern Crown Conference', prestige: 95, primary: Color(0xFFBA0C2F), secondary: Color(0xFF000000)),
  CollegeTeam(name: 'Austin', emoji: '🤘', mascot: 'Longhorns', conference: 'Southern Crown Conference', prestige: 95, primary: Color(0xFFBF5700), secondary: Color(0xFFFFFFFF)),
  CollegeTeam(name: 'Norman', emoji: '🤠', mascot: 'Sooners', conference: 'Southern Crown Conference', prestige: 95, primary: Color(0xFF841617), secondary: Color(0xFFFFFFFF)),
  CollegeTeam(name: 'Baton Rouge', emoji: '🐯', mascot: 'Tigers', conference: 'Southern Crown Conference', prestige: 95, primary: Color(0xFF461D7C), secondary: Color(0xFFFDD023)),
  CollegeTeam(name: 'Gainesville', emoji: '🐊', mascot: 'Gators', conference: 'Southern Crown Conference', prestige: 95, primary: Color(0xFF0021A5), secondary: Color(0xFFFA4616)),
  CollegeTeam(name: 'Knoxville', emoji: '🍊', mascot: 'Volunteers', conference: 'Southern Crown Conference', prestige: 95, primary: Color(0xFFFF8200), secondary: Color(0xFFFFFFFF)),
  CollegeTeam(name: 'Chattahoochee', emoji: '🐯', mascot: 'Tigers', conference: 'Southern Crown Conference', prestige: 85, primary: Color(0xFF0C2340), secondary: Color(0xFFE87722)),
  CollegeTeam(name: 'Yazoo', emoji: '🦈', mascot: 'Rebels', conference: 'Southern Crown Conference', prestige: 85, primary: Color(0xFFCE1126), secondary: Color(0xFF14213D)),
  CollegeTeam(name: 'Columbia', emoji: '🐯', mascot: 'Tigers', conference: 'Southern Crown Conference', prestige: 85, primary: Color(0xFFF1B82D), secondary: Color(0xFF000000)),
  CollegeTeam(name: 'College Station', emoji: '🌾', mascot: 'Aggies', conference: 'Southern Crown Conference', prestige: 85, primary: Color(0xFF500000), secondary: Color(0xFFFFFFFF)),
  CollegeTeam(name: 'Palmetto', emoji: '🐓', mascot: 'Gamecocks', conference: 'Southern Crown Conference', prestige: 85, primary: Color(0xFF73000A), secondary: Color(0xFF000000)),
  CollegeTeam(name: 'Fayetteville', emoji: '🐗', mascot: 'Razorbacks', conference: 'Southern Crown Conference', prestige: 85, primary: Color(0xFF9D2235), secondary: Color(0xFFFFFFFF)),
  CollegeTeam(name: 'Starkville', emoji: '🐶', mascot: 'Bulldogs', conference: 'Southern Crown Conference', prestige: 75, primary: Color(0xFF660000), secondary: Color(0xFFFFFFFF)),
  CollegeTeam(name: 'Lexington', emoji: '🐈', mascot: 'Wildcats', conference: 'Southern Crown Conference', prestige: 75, primary: Color(0xFF0033A0), secondary: Color(0xFFFFFFFF)),
  CollegeTeam(name: 'Nashville', emoji: '⚓', mascot: 'Commodores', conference: 'Southern Crown Conference', prestige: 65, primary: Color(0xFF000000), secondary: Color(0xFFB3A369)),
  CollegeTeam(name: 'Columbus', emoji: '🌰', mascot: 'Buckeyes', conference: 'Heartland Conference', prestige: 95, primary: Color(0xFFBB0000), secondary: Color(0xFF666666)),
  CollegeTeam(name: 'Ann Arbor', emoji: '🐾', mascot: 'Wolverines', conference: 'Heartland Conference', prestige: 95, primary: Color(0xFF00274C), secondary: Color(0xFFFFCB05)),
  CollegeTeam(name: 'State College', emoji: '🦁', mascot: 'Nittany Lions', conference: 'Heartland Conference', prestige: 95, primary: Color(0xFF041E42), secondary: Color(0xFFFFFFFF)),
  CollegeTeam(name: 'Eugene', emoji: '🦆', mascot: 'Ducks', conference: 'Heartland Conference', prestige: 95, primary: Color(0xFF154733), secondary: Color(0xFFFEE123)),
  CollegeTeam(name: 'University Park', emoji: '🛡️', mascot: 'Trojans', conference: 'Heartland Conference', prestige: 95, primary: Color(0xFF990000), secondary: Color(0xFFFFCC00)),
  CollegeTeam(name: 'Seattle', emoji: '🐺', mascot: 'Huskies', conference: 'Heartland Conference', prestige: 85, primary: Color(0xFF4B2E83), secondary: Color(0xFFB7A57A)),
  CollegeTeam(name: 'Madison', emoji: '🦡', mascot: 'Badgers', conference: 'Heartland Conference', prestige: 85, primary: Color(0xFFC5050C), secondary: Color(0xFFFFFFFF)),
  CollegeTeam(name: 'Iowa City', emoji: '🦅', mascot: 'Hawkeyes', conference: 'Heartland Conference', prestige: 85, primary: Color(0xFFFFCD00), secondary: Color(0xFF000000)),
  CollegeTeam(name: 'Lincoln', emoji: '🌽', mascot: 'Cornhuskers', conference: 'Heartland Conference', prestige: 85, primary: Color(0xFFE41C38), secondary: Color(0xFFFFFFFF)),
  CollegeTeam(name: 'East Lansing', emoji: '🛡️', mascot: 'Spartans', conference: 'Heartland Conference', prestige: 85, primary: Color(0xFF18453B), secondary: Color(0xFFFFFFFF)),
  CollegeTeam(name: 'Westwood', emoji: '🐻', mascot: 'Bruins', conference: 'Heartland Conference', prestige: 85, primary: Color(0xFF2D68C4), secondary: Color(0xFFFFD100)),
  CollegeTeam(name: 'Minneapolis', emoji: '🐿️', mascot: 'Golden Gophers', conference: 'Heartland Conference', prestige: 75, primary: Color(0xFF7A0019), secondary: Color(0xFFFFCC33)),
  CollegeTeam(name: 'Champaign', emoji: '🔶', mascot: 'Fighting Illini', conference: 'Heartland Conference', prestige: 75, primary: Color(0xFF13294B), secondary: Color(0xFFFF5F05)),
  CollegeTeam(name: 'College Park', emoji: '🐢', mascot: 'Terrapins', conference: 'Heartland Conference', prestige: 75, primary: Color(0xFFE03A3E), secondary: Color(0xFFFFCD00)),
  CollegeTeam(name: 'New Brunswick', emoji: '⚔️', mascot: 'Scarlet Knights', conference: 'Heartland Conference', prestige: 65, primary: Color(0xFFCC0033), secondary: Color(0xFFFFFFFF)),
  CollegeTeam(name: 'Bloomington', emoji: '🌽', mascot: 'Hoosiers', conference: 'Heartland Conference', prestige: 75, primary: Color(0xFF990000), secondary: Color(0xFFFFFFFF)),
  CollegeTeam(name: 'West Lafayette', emoji: '🔨', mascot: 'Boilermakers', conference: 'Heartland Conference', prestige: 75, primary: Color(0xFFCEB888), secondary: Color(0xFF000000)),
  CollegeTeam(name: 'Evanston', emoji: '🐈', mascot: 'Wildcats', conference: 'Heartland Conference', prestige: 65, primary: Color(0xFF4E2A84), secondary: Color(0xFFFFFFFF)),
  CollegeTeam(name: 'Tallahassee', emoji: '🔥', mascot: 'Seminoles', conference: 'Atlantic Coalition', prestige: 95, primary: Color(0xFF782F40), secondary: Color(0xFFCEB888)),
  CollegeTeam(name: 'Blue Ridge', emoji: '🐯', mascot: 'Tigers', conference: 'Atlantic Coalition', prestige: 95, primary: Color(0xFFF56600), secondary: Color(0xFF522D80)),
  CollegeTeam(name: 'Coral Gables', emoji: '🌀', mascot: 'Hurricanes', conference: 'Atlantic Coalition', prestige: 95, primary: Color(0xFFF47321), secondary: Color(0xFF005030)),
  CollegeTeam(name: 'South Bend', emoji: '☘️', mascot: 'Fighting Irish', conference: 'Independent', prestige: 95, primary: Color(0xFF0C2340), secondary: Color(0xFFC99700)),
  CollegeTeam(name: 'Chapel Hill', emoji: '🌲', mascot: 'Tar Heels', conference: 'Atlantic Coalition', prestige: 85, primary: Color(0xFF7BAFD4), secondary: Color(0xFFFFFFFF)),
  CollegeTeam(name: 'Raleigh', emoji: '🐺', mascot: 'Wolfpack', conference: 'Atlantic Coalition', prestige: 85, primary: Color(0xFFF5C451), secondary: Color(0xFFFFFFFF)),
  CollegeTeam(name: 'Blacksburg', emoji: '🦃', mascot: 'Hokies', conference: 'Atlantic Coalition', prestige: 85, primary: Color(0xFF861F41), secondary: Color(0xFFE5751F)),
  CollegeTeam(name: 'Derby City', emoji: '🐦', mascot: 'Cardinals', conference: 'Atlantic Coalition', prestige: 85, primary: Color(0xFFAD0000), secondary: Color(0xFF000000)),
  CollegeTeam(name: 'Steel City', emoji: '🐆', mascot: 'Panthers', conference: 'Atlantic Coalition', prestige: 85, primary: Color(0xFF003594), secondary: Color(0xFFFFB81C)),
  CollegeTeam(name: 'Salt City', emoji: '🍊', mascot: 'Orange', conference: 'Atlantic Coalition', prestige: 75, primary: Color(0xFFF76900), secondary: Color(0xFF000E54)),
  CollegeTeam(name: 'Old Dominion', emoji: '⚔️', mascot: 'Cavaliers', conference: 'Atlantic Coalition', prestige: 75, primary: Color(0xFF232D4B), secondary: Color(0xFFE57200)),
  CollegeTeam(name: 'Durham', emoji: '😈', mascot: 'Blue Devils', conference: 'Atlantic Coalition', prestige: 75, primary: Color(0xFF00539B), secondary: Color(0xFFFFFFFF)),
  CollegeTeam(name: 'Twin City', emoji: '😈', mascot: 'Demon Deacons', conference: 'Atlantic Coalition', prestige: 75, primary: Color(0xFF000000), secondary: Color(0xFFCDA077)),
  CollegeTeam(name: 'Midtown', emoji: '🐝', mascot: 'Yellow Jackets', conference: 'Atlantic Coalition', prestige: 75, primary: Color(0xFFB3A369), secondary: Color(0xFF003057)),
  CollegeTeam(name: 'Chestnut Hill', emoji: '🦅', mascot: 'Eagles', conference: 'Atlantic Coalition', prestige: 75, primary: Color(0xFF8A100B), secondary: Color(0xFFB29D6C)),
  CollegeTeam(name: 'Park Cities', emoji: '🐴', mascot: 'Mustangs', conference: 'Atlantic Coalition', prestige: 85, primary: Color(0xFF0033A0), secondary: Color(0xFFC8102E)),
  CollegeTeam(name: 'Berkeley', emoji: '🐻', mascot: 'Golden Bears', conference: 'Atlantic Coalition', prestige: 75, primary: Color(0xFF003262), secondary: Color(0xFFFDB515)),
  CollegeTeam(name: 'Palo Alto', emoji: '🌲', mascot: 'Cardinal', conference: 'Atlantic Coalition', prestige: 75, primary: Color(0xFF8C1515), secondary: Color(0xFFFFFFFF)),
  CollegeTeam(name: 'Salt Lake City', emoji: '🐝', mascot: 'Utes', conference: 'Frontier Conference', prestige: 95, primary: Color(0xFFF5C451), secondary: Color(0xFFFFFFFF)),
  CollegeTeam(name: 'Manhattan', emoji: '🐈', mascot: 'Wildcats', conference: 'Frontier Conference', prestige: 85, primary: Color(0xFF512888), secondary: Color(0xFFFFFFFF)),
  CollegeTeam(name: 'Stillwater', emoji: '🤠', mascot: 'Cowboys', conference: 'Frontier Conference', prestige: 85, primary: Color(0xFFFF7300), secondary: Color(0xFF000000)),
  CollegeTeam(name: 'Fort Worth', emoji: '🐸', mascot: 'Horned Frogs', conference: 'Frontier Conference', prestige: 85, primary: Color(0xFF4D1979), secondary: Color(0xFFFFFFFF)),
  CollegeTeam(name: 'Waco', emoji: '🐻', mascot: 'Bears', conference: 'Frontier Conference', prestige: 85, primary: Color(0xFF154734), secondary: Color(0xFFFFB81C)),
  CollegeTeam(name: 'Ames', emoji: '🌪️', mascot: 'Cyclones', conference: 'Frontier Conference', prestige: 85, primary: Color(0xFFC8102E), secondary: Color(0xFFF1BE48)),
  CollegeTeam(name: 'Lawrence', emoji: '🐦', mascot: 'Jayhawks', conference: 'Frontier Conference', prestige: 75, primary: Color(0xFF0051BA), secondary: Color(0xFFE8000D)),
  CollegeTeam(name: 'Lubbock', emoji: '⚔️', mascot: 'Red Raiders', conference: 'Frontier Conference', prestige: 85, primary: Color(0xFFF5C451), secondary: Color(0xFF000000)),
  CollegeTeam(name: 'Morgantown', emoji: '⛰️', mascot: 'Mountaineers', conference: 'Frontier Conference', prestige: 85, primary: Color(0xFF002855), secondary: Color(0xFFEAAA00)),
  CollegeTeam(name: 'Queen City', emoji: '🐆', mascot: 'Bearcats', conference: 'Frontier Conference', prestige: 75, primary: Color(0xFFE00122), secondary: Color(0xFF000000)),
  CollegeTeam(name: 'Orlando', emoji: '⚔️', mascot: 'Knights', conference: 'Frontier Conference', prestige: 85, primary: Color(0xFF000000), secondary: Color(0xFFCFAE70)),
  CollegeTeam(name: 'Tucson', emoji: '🐈', mascot: 'Wildcats', conference: 'Frontier Conference', prestige: 75, primary: Color(0xFFAB0520), secondary: Color(0xFF0C234B)),
  CollegeTeam(name: 'Tempe', emoji: '🔥', mascot: 'Sun Devils', conference: 'Frontier Conference', prestige: 75, primary: Color(0xFF8C1D40), secondary: Color(0xFFFFB81C)),
  CollegeTeam(name: 'Boulder', emoji: '🐃', mascot: 'Buffaloes', conference: 'Frontier Conference', prestige: 85, primary: Color(0xFFCFB87C), secondary: Color(0xFF000000)),
  CollegeTeam(name: 'Provo', emoji: '🐆', mascot: 'Cougars', conference: 'Frontier Conference', prestige: 85, primary: Color(0xFF002E5D), secondary: Color(0xFFFFFFFF)),
  CollegeTeam(name: 'Houston', emoji: '🐆', mascot: 'Cougars', conference: 'Frontier Conference', prestige: 75, primary: Color(0xFFC8102E), secondary: Color(0xFFFFFFFF)),
  CollegeTeam(name: 'Boise', emoji: '🐴', mascot: 'Broncos', conference: 'Summit West Conference', prestige: 95, primary: Color(0xFF0033A0), secondary: Color(0xFFD64309)),
];

List<Player> generateRoster(int prestige) {
  final tier = prestigeTier(prestige);
  final positionCounts = <String, int>{
    'QB': 2,
    'HB': 3,
    'WR': 5,
    'TE': 2,
    'DE': 3,
    'LB': 4,
    'DB': 3,
  };

  final years = ['FR', 'SO', 'JR', 'SR'];
  final roster = <Player>[];

  final minOverall = switch (tier) {
    1 => 48,
    2 => 56,
    3 => 64,
    4 => 74,
    _ => 84,
  };

  final maxOverall = switch (tier) {
    1 => 60,
    2 => 68,
    3 => 78,
    4 => 88,
    _ => 94,
  };

  final minDev = switch (tier) {
    1 => 2,
    2 => 3,
    3 => 4,
    4 => 5,
    _ => 6,
  };

  final maxDev = switch (tier) {
    1 => 8,
    2 => 11,
    3 => 14,
    4 => 17,
    _ => 20,
  };

  for (final entry in positionCounts.entries) {
    for (int i = 0; i < entry.value; i++) {
      final overall = minOverall + rng.nextInt(maxOverall - minOverall + 1);
      final dev = minDev + rng.nextInt(maxDev - minDev + 1);
      final potential = (overall + dev).clamp(overall, 99);

      final stars = switch (overall) {
        >= 88 => 5,
        >= 78 => 4,
        >= 68 => 3,
        >= 58 => 2,
        _ => 1,
      };

      roster.add(
        Player(
          name: NameGenerator.generate(),
          position: entry.key,
          overall: overall,
          potential: potential,
          year: years[rng.nextInt(years.length)],
          stars: stars,
        ),
      );
    }
  }

  roster.sort((a, b) => awardOverall(b).compareTo(awardOverall(a)));
  return roster;
}

int weightedStarsForPrestige(int prestige) {
  final tier = prestigeTier(prestige);
  final roll = rng.nextInt(100);

  if (tier == 1) {
    if (roll < 55) return 1;
    return 2;
  }

  if (tier == 2) {
    if (roll < 30) return 1;
    if (roll < 85) return 2;
    return 3;
  }

  if (tier == 3) {
    if (roll < 15) return 2;
    if (roll < 80) return 3;
    return 4;
  }

  if (tier == 4) {
    if (roll < 20) return 3;
    if (roll < 75) return 4;
    return 5;
  }

  if (roll < 8) return 3;
  if (roll < 45) return 4;
  return 5;
}


int weightedRecruitStars(Random rng, int maxStars) {
  final roll = rng.nextDouble();

  if (maxStars <= 2) {
    return roll < .62 ? 1 : 2;
  }

  if (maxStars == 3) {
    if (roll < .43) return 1;
    if (roll < .78) return 2;
    return 3;
  }

  if (maxStars == 4) {
    if (roll < .34) return 1;
    if (roll < .62) return 2;
    if (roll < .86) return 3;
    return 4;
  }

  // Even when 5-stars are available, they should be rare.
  if (roll < .30) return 1;
  if (roll < .58) return 2;
  if (roll < .82) return 3;
  if (roll < .95) return 4;
  return 5;
}

List<Recruit> generateRecruits(int prestige) {
  final positions = ['QB', 'HB', 'WR', 'TE', 'DE', 'LB', 'DB'];
  final states = [
    'RI', 'MA', 'CT', 'NY', 'NJ', 'PA', 'OH', 'MI', 'FL', 'GA',
    'TX', 'CA', 'AZ', 'NC', 'SC', 'VA', 'MD', 'AL', 'LA', 'TN',
  ];
  final recruits = <Recruit>[];

  for (int i = 0; i < 40; i++) {
    final stars = weightedStarsForPrestige(prestige);

    final minOverall = switch (stars) {
      5 => 88,
      4 => 78,
      3 => 68,
      2 => 58,
      _ => 48,
    };

    final maxOverall = switch (stars) {
      5 => 99,
      4 => 87,
      3 => 77,
      2 => 67,
      _ => 57,
    };

    final potentialBoostMin = switch (prestigeTier(prestige)) {
      1 => 2,
      2 => 3,
      3 => 4,
      4 => 5,
      _ => 6,
    };

    final potentialBoostMax = switch (prestigeTier(prestige)) {
      1 => 10,
      2 => 13,
      3 => 16,
      4 => 19,
      _ => 22,
    };

    final overall = minOverall + rng.nextInt(maxOverall - minOverall + 1);
    final boost =
        potentialBoostMin + rng.nextInt(potentialBoostMax - potentialBoostMin + 1);
    final potential = (overall + boost).clamp(overall, 99);

    final interestBonus = switch (prestigeTier(prestige)) {
      1 => 0,
      2 => 6,
      3 => 12,
      4 => 18,
      _ => 25,
    };
    recruits.add(
      Recruit(
        name: NameGenerator.generate(),
        position: positions[rng.nextInt(positions.length)],
        state: states[rng.nextInt(states.length)],
        stars: stars,
        trueOverall: overall,
        truePotential: potential,
        interest: (25 + interestBonus + rng.nextInt(46)).clamp(1, 100),
      ),
    );
  }

  recruits.sort((a, b) {
    final starCompare = b.stars.compareTo(a.stars);
    if (starCompare != 0) return starCompare;
    return b.interest.compareTo(a.interest);
  });
  return recruits;
}


// ============================================================================
// GRIDIRON KINGDOM — PHASE 1 DESIGN SYSTEM
// Presentation-only components. Simulation, saves, AdMob, and purchases remain
// unchanged.
// ============================================================================

// ---------------------------------------------------------------------------
// THE KINGDOM'S LEDGER — direction contract
// THESIS: the app is a worn leather program ledger under desk-lamp light, not
//   a glowing tech dashboard. It refuses this codebase's own former look
//   (near-black ground + one flat gold glow) because that pairing is a
//   recognized AI-generated-interface default, not a chosen identity.
// OWN-WORLD: dark saddle-leather and oxblood ground, antique-brass stitching
//   and hardware as the single accent system, aged-kraft paper insets (never
//   the whole ground) for dense data — rosters, stat tables, standings. Sharp
//   architectural corners, not soft rounded-everything. Engraved Cinzel for
//   headlines/labels, Zilla Slab as the workhorse ledger-page body face.
// STORY: the coach's own leather-bound program ledger, filling in season by
//   season. Every screen is a page in that ledger, not a card in a feed.
// FIRST VIEWPORT: HomeScreen — the ledger's cover/title page, brass corner
//   hardware, embossed masthead, no card grid of icon+heading+text.
// FORM: assigned direction 5 of 7 (Stadium Signage) was rolled by
//   concept-seed.mjs; the user pinned the "Heritage leather archive"
//   challenger instead after seeing both fully committed. A user-pinned
//   choice overrides the roll, per the skill's own rule.
// FINISH: unreviewed and undocumented is unfinished; this build ends with
//   the finish review, the verdict, and DESIGN.md.
// ---------------------------------------------------------------------------

class GKColors {
  // The Kingdom's Ledger: dark tooled-leather ground, antique brass
  // hardware, aged-paper insets for data. Real material, not a glow.
  static const ledgerBlack = Color(0xFF150F0B);
  static const oxblood = Color(0xFF3A1E17);
  static const saddleLeather = Color(0xFF3D2A1B);
  static const elevatedLeather = Color(0xFF4A3323);
  static const stitchLine = Color(0xFF7A5B37);

  static const agedPaper = Color(0xFFE9DDBE);
  static const paperShadow = Color(0xFFCBB98F);
  static const inkBlack = Color(0xFF241A10);

  static const parchmentWhite = Color(0xFFF4E9D2);
  static const fadedInk = Color(0xFFBBA47D);

  static const kingdomBrass = Color(0xFFC08A3E);
  static const brightBrass = Color(0xFFDCAA5C);
  static const fieldGreen = Color(0xFF3F6B49);
  static const stampRed = Color(0xFFAE4530);
  static const wardenBlue = Color(0xFF3D6B8C);

  // Legacy aliases kept so the ~350 existing call sites across the app
  // repaint automatically instead of needing a mechanical per-screen edit.
  static const midnight = ledgerBlack;
  static const broadcastNavy = oxblood;
  static const panel = saddleLeather;
  static const elevatedPanel = elevatedLeather;
  static const warmWhite = parchmentWhite;
  static const mutedSilver = fadedInk;
  static const kingdomGold = kingdomBrass;
  static const crownBlue = wardenBlue;
  static const fieldTeal = fieldGreen;
  static const victoryGreen = fieldGreen;
  static const alertRed = stampRed;
  static const divider = stitchLine;
}

class GKSpace {
  static const double xxs = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 20;
  static const double xl = 24;
  static const double xxl = 32;
  static const double display = 40;
}

/// A worn ledger has sharp, cut corners, not rounded-rectangle-everything.
/// Four deliberate steps instead of the seventeen ad-hoc values the old
/// system had accumulated.
class GKRadius {
  static const double hairline = 2;
  static const double pill = 4;
  static const double small = 4;
  static const double card = 6;
  static const double featured = 8;
  static const double modal = 10;
}

class GKText {
  static TextStyle get display => GoogleFonts.cinzel(
        color: GKColors.parchmentWhite,
        fontSize: 34,
        fontWeight: FontWeight.w700,
        height: .98,
        letterSpacing: -.5,
      );

  static TextStyle get pageTitle => GoogleFonts.cinzel(
        color: GKColors.parchmentWhite,
        fontSize: 23,
        fontWeight: FontWeight.w600,
        letterSpacing: .4,
      );

  static TextStyle get sectionLabel => GoogleFonts.cinzel(
        color: GKColors.kingdomBrass,
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 2.2,
      );

  static TextStyle get cardTitle => GoogleFonts.zillaSlab(
        color: GKColors.parchmentWhite,
        fontSize: 17,
        fontWeight: FontWeight.w700,
      );

  static TextStyle get body => GoogleFonts.zillaSlab(
        color: GKColors.fadedInk,
        fontSize: 14,
        fontWeight: FontWeight.w400,
        height: 1.4,
      );

  static TextStyle get bodyStrong => GoogleFonts.zillaSlab(
        color: GKColors.parchmentWhite,
        fontSize: 14,
        fontWeight: FontWeight.w600,
        height: 1.35,
      );

  static TextStyle get statValue => GoogleFonts.zillaSlab(
        color: GKColors.parchmentWhite,
        fontSize: 20,
        fontWeight: FontWeight.w700,
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  static TextStyle get button => GoogleFonts.cinzel(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.8,
      );

  /// Ink-on-paper variant for text sitting on an [GKColors.agedPaper] inset
  /// rather than the dark leather ground.
  static TextStyle onPaper(TextStyle style) => style.copyWith(
        color: GKColors.inkBlack,
      );
}

Color gkReadableOn(Color background) {
  return ThemeData.estimateBrightnessForColor(background) == Brightness.dark
      ? GKColors.parchmentWhite
      : GKColors.inkBlack;
}

Color gkDarkenedSchoolColor(Color color, [double amount = .58]) {
  return Color.lerp(color, GKColors.ledgerBlack, amount) ?? color;
}

Color coachSkinColorFor(String skinTone) {
  return switch (skinTone) {
    'Fair' => Color(0xFFF5D4A8),
    'Light' => Color(0xFFF1C27D),
    'Tan' => Color(0xFFD6A06A),
    'Olive' => Color(0xFFC08552),
    'Brown' => Color(0xFFA86B32),
    'Deep' => Color(0xFF6B4423),
    'Dark' => Color(0xFF5C3317),
    _ => Color(0xFFD6A06A),
  };
}

Color coachHairColorFor(String hairColor) {
  return switch (hairColor) {
    'Black' => GKColors.inkBlack,
    'Dark Brown' => Color(0xFF3A2417),
    'Brown' => Color(0xFF4E2A14),
    'Auburn' => Color(0xFF7A3B2E),
    'Sandy' => Color(0xFFB8895A),
    'Blonde' => Color(0xFFE6C35C),
    'Red' => Color(0xFF9E2A2B),
    'Silver' => Color(0xFFC8C8C8),
    'Gray' => GKColors.fadedInk,
    _ => Color(0xFF4E2A14),
  };
}

/// Two-letter/three-letter monogram for a team badge, e.g. "Ohio Central" ->
/// "OC", "Ann Arbor" -> "AA", "Lonestar" -> "LON". Authored typographic mark,
/// standing in for a real per-school crest this codebase does not have.
String teamMonogram(String name) {
  final words = name
      .replaceAll(RegExp(r'[^A-Za-z ]'), '')
      .split(' ')
      .where((w) => w.isNotEmpty)
      .toList();
  if (words.length == 1) {
    final w = words.first;
    return w.length <= 4 ? w.toUpperCase() : w.substring(0, 3).toUpperCase();
  }
  if (words.every((w) => w == w.toUpperCase())) {
    return words.join('').toUpperCase().substring(
        0, words.join('').length > 4 ? 4 : words.join('').length);
  }
  return words.map((w) => w[0]).join().toUpperCase();
}

/// Deterministic tooled-leather grain: fine flecks under a lamplight
/// vignette, replacing the old flat gradient-plus-glow-circle background.
/// Authored texture, not decoration — this is the single most load-bearing
/// surface in the app for reading as "leather" rather than "dark UI."
class _LeatherGrainPainter extends CustomPainter {
  const _LeatherGrainPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final base = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          GKColors.saddleLeather,
          GKColors.oxblood,
          GKColors.ledgerBlack,
        ],
        stops: [0, .46, 1],
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, base);

    // Lamplight pool, upper-third, warm and soft-edged — one authored
    // moment of light, not a UI glow. Large radial falloff, low opacity.
    final lamp = Paint()
      ..shader = RadialGradient(
        center: const Alignment(0, -.72),
        radius: 1.1,
        colors: [
          GKColors.brightBrass.withOpacity(.10),
          Colors.transparent,
        ],
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, lamp);

    // Fine leather grain: a deterministic scatter of short, faint flecks.
    final rng = Random(7);
    final fleck = Paint()..strokeWidth = 1;
    const count = 420;
    for (var i = 0; i < count; i++) {
      final dx = rng.nextDouble() * size.width;
      final dy = rng.nextDouble() * size.height;
      final len = 1.5 + rng.nextDouble() * 2.5;
      final angle = rng.nextDouble() * pi;
      final dark = rng.nextBool();
      fleck.color = (dark ? GKColors.inkBlack : GKColors.brightBrass)
          .withOpacity(dark ? .10 : .05);
      canvas.drawLine(
        Offset(dx, dy),
        Offset(dx + cos(angle) * len, dy + sin(angle) * len),
        fleck,
      );
    }

    // Vignette toward the outer edge, like light falling off a bound page.
    final vignette = Paint()
      ..shader = RadialGradient(
        center: Alignment.center,
        radius: 1.0,
        colors: [Colors.transparent, Colors.black.withOpacity(.32)],
        stops: const [.6, 1],
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, vignette);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class GKBackground extends StatelessWidget {
  final Widget child;

  const GKBackground({
    super.key,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const Positioned.fill(
          child: RepaintBoundary(
            child: CustomPaint(painter: _LeatherGrainPainter()),
          ),
        ),
        child,
      ],
    );
  }
}

/// A single dashed seam, drawn where a leather panel would be stitched to
/// its backing. One consistent material cue for the whole card system
/// rather than a border-radius-and-shadow card shell.
class _StitchSeamPainter extends CustomPainter {
  final Color color;
  const _StitchSeamPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;
    const dash = 5.0, gap = 4.0;
    var x = 0.0;
    while (x < size.width) {
      canvas.drawLine(Offset(x, 0), Offset(min(x + dash, size.width), 0), paint);
      x += dash + gap;
    }
  }

  @override
  bool shouldRepaint(covariant _StitchSeamPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// Irregular deckle edge for the [GKCard.paper] variant, like a torn or
/// rough-cut page edge rather than a machine-rounded corner.
class _DeckleEdgeClipper extends CustomClipper<Path> {
  const _DeckleEdgeClipper();

  @override
  Path getClip(Size size) {
    final path = Path()..moveTo(0, 6);
    final rng = Random(11);
    const step = 14.0;
    var x = 0.0;
    while (x < size.width) {
      final next = min(x + step, size.width);
      path.lineTo(next, rng.nextDouble() * 5);
      x = next;
    }
    path
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    return path;
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}

class GKCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;
  final Color? borderColor;
  final double radius;
  final VoidCallback? onTap;

  /// When true, renders as an aged-paper ledger-page inset (for dense
  /// tabular data: rosters, stat tables, standings) instead of the default
  /// dark leather panel. Callers are responsible for giving paper children
  /// ink-toned text via [GKText.onPaper].
  final bool paper;

  const GKCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(GKSpace.md),
    this.color,
    this.borderColor,
    this.radius = GKRadius.card,
    this.onTap,
    this.paper = false,
  });

  @override
  Widget build(BuildContext context) {
    final bg = color ?? (paper ? GKColors.agedPaper : GKColors.elevatedLeather);
    final line = borderColor ??
        (paper ? GKColors.paperShadow : GKColors.stitchLine.withOpacity(.55));

    Widget card = Container(
      padding: padding.add(const EdgeInsets.only(top: GKSpace.xs)),
      decoration: BoxDecoration(
        color: bg,
        border: Border.all(color: line),
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(paper ? .28 : .38),
            offset: const Offset(0, 4),
            blurRadius: 10,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CustomPaint(
            size: const Size(double.infinity, 6),
            painter: _StitchSeamPainter(
              paper ? GKColors.paperShadow : GKColors.kingdomBrass.withOpacity(.4),
            ),
          ),
          const SizedBox(height: GKSpace.xs),
          child,
        ],
      ),
    );

    if (paper) {
      card = ClipPath(clipper: const _DeckleEdgeClipper(), child: card);
    }

    if (onTap == null) return card;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(radius),
        child: card,
      ),
    );
  }
}

/// A stamped brass plate: top-lit gradient bevel and a real drop shadow,
/// standing in for the old flat-fill, glow-shadowed pill button.
class GKPrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;

  const GKPrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: Material(
        color: Colors.transparent,
        child: Ink(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: enabled
                  ? const [GKColors.brightBrass, GKColors.kingdomBrass]
                  : [
                      GKColors.kingdomBrass.withOpacity(.28),
                      GKColors.kingdomBrass.withOpacity(.22),
                    ],
            ),
            borderRadius: BorderRadius.circular(GKRadius.card),
            border: Border.all(color: GKColors.ledgerBlack.withOpacity(.4)),
            boxShadow: enabled
                ? [
                    BoxShadow(
                      color: Colors.black.withOpacity(.4),
                      offset: const Offset(0, 3),
                      blurRadius: 8,
                    ),
                  ]
                : null,
          ),
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(GKRadius.card),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (icon != null) ...[
                  Icon(icon,
                      size: 19,
                      color: GKColors.inkBlack
                          .withOpacity(enabled ? 1 : .45)),
                  const SizedBox(width: GKSpace.xs),
                ],
                Text(
                  label.toUpperCase(),
                  style: GKText.button.copyWith(
                    color: GKColors.inkBlack.withOpacity(enabled ? 1 : .45),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The leather-strap counterpart: saddle-leather fill, brass hairline seam.
class GKSecondaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;

  const GKSecondaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: Material(
        color: Colors.transparent,
        child: Ink(
          decoration: BoxDecoration(
            color: GKColors.saddleLeather,
            borderRadius: BorderRadius.circular(GKRadius.card),
            border: Border.all(color: GKColors.stitchLine),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(.3),
                offset: const Offset(0, 2),
                blurRadius: 5,
              ),
            ],
          ),
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(GKRadius.card),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 18, color: GKColors.parchmentWhite),
                  const SizedBox(width: GKSpace.xs),
                ],
                Text(
                  label.toUpperCase(),
                  style: GKText.button.copyWith(color: GKColors.parchmentWhite),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// No kicker/eyebrow above the heading — the title carries its own weight.
class GKSectionHeader extends StatelessWidget {
  final String title;
  final String? subtitle;

  const GKSectionHeader({
    super.key,
    required this.title,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title.toUpperCase(), style: GKText.pageTitle),
        if (subtitle != null) ...[
          const SizedBox(height: GKSpace.xs),
          Text(subtitle!, style: GKText.body),
        ],
      ],
    );
  }
}

/// The studio's mark as a stamped brass medallion — a real bevel from a
/// two-stop gradient and an offset shadow, not a glossy diagonal sheen
/// with a colored glow.
class GKStudioMark extends StatelessWidget {
  const GKStudioMark({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 84,
          height: 84,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [GKColors.brightBrass, GKColors.kingdomBrass],
            ),
            border: Border.all(color: GKColors.ledgerBlack.withOpacity(.45)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(.4),
                offset: const Offset(0, 3),
                blurRadius: 8,
              ),
            ],
          ),
          alignment: Alignment.center,
          child: Text(
            'GK',
            style: GoogleFonts.cinzel(
              color: GKColors.inkBlack,
              fontSize: 28,
              fontWeight: FontWeight.w700,
              letterSpacing: -.5,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'GAME DAY STUDIOS',
          style: GoogleFonts.cinzel(
            color: GKColors.fadedInk,
            fontSize: 10,
            fontWeight: FontWeight.w600,
            letterSpacing: 3.1,
          ),
        ),
      ],
    );
  }
}

/// A varsity letter-patch: the team's own colors, stitched brass edge, and
/// an authored monogram — no emoji standing in for the crest this codebase
/// doesn't have.
class GKTeamBadge extends StatelessWidget {
  final CollegeTeam team;
  final double size;

  const GKTeamBadge({
    super.key,
    required this.team,
    this.size = 54,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(size * .07),
      decoration: BoxDecoration(
        color: GKColors.kingdomBrass,
        borderRadius: BorderRadius.circular(size * .16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(.35),
            offset: const Offset(0, 3),
            blurRadius: 6,
          ),
        ],
      ),
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              team.primary,
              gkDarkenedSchoolColor(team.primary, .36),
            ],
          ),
          borderRadius: BorderRadius.circular(size * .12),
          border: Border.all(color: team.secondary.withOpacity(.85), width: 1.5),
        ),
        alignment: Alignment.center,
        child: Text(
          teamMonogram(team.name),
          style: GoogleFonts.cinzel(
            fontSize: size * .3,
            fontWeight: FontWeight.w700,
            letterSpacing: -.5,
            color: gkReadableOn(team.primary),
          ),
        ),
      ),
    );
  }
}

class RoadToPlayoffsApp extends StatelessWidget {
  const RoadToPlayoffsApp({super.key});

  @override
  Widget build(BuildContext context) {
    final baseTextTheme = ThemeData(brightness: Brightness.dark).textTheme;
    return MaterialApp(
      title: 'GRIDIRON KINGDOM',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        scaffoldBackgroundColor: GKColors.ledgerBlack,
        // Zilla Slab as the ambient workhorse face: this alone repaints
        // every inline TextStyle in the app (none of them set fontFamily,
        // so each inherits it through DefaultTextStyle) without a
        // screen-by-screen edit.
        textTheme: GoogleFonts.zillaSlabTextTheme(baseTextTheme).apply(
          bodyColor: GKColors.parchmentWhite,
          displayColor: GKColors.parchmentWhite,
        ),
        colorScheme: const ColorScheme.dark(
          primary: GKColors.kingdomBrass,
          onPrimary: GKColors.inkBlack,
          secondary: GKColors.fieldGreen,
          surface: GKColors.elevatedLeather,
          onSurface: GKColors.parchmentWhite,
          error: GKColors.stampRed,
        ),
        appBarTheme: AppBarTheme(
          backgroundColor: GKColors.ledgerBlack,
          foregroundColor: GKColors.parchmentWhite,
          centerTitle: true,
          elevation: 0,
          scrolledUnderElevation: 0,
          titleTextStyle: GKText.pageTitle.copyWith(fontSize: 19),
        ),
        dividerColor: GKColors.stitchLine,
        snackBarTheme: SnackBarThemeData(
          backgroundColor: GKColors.elevatedLeather,
          contentTextStyle: GKText.bodyStrong,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: GKColors.kingdomBrass,
            foregroundColor: GKColors.inkBlack,
            elevation: 4,
            shadowColor: Colors.black.withOpacity(.4),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(GKRadius.card),
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: GKColors.parchmentWhite,
            side: const BorderSide(color: GKColors.stitchLine),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(GKRadius.card),
            ),
          ),
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

class AppTitle extends StatelessWidget {
  final String title;

  const AppTitle(this.title, {super.key});

  @override
  Widget build(BuildContext context) {
    return Text(
      title.toUpperCase(),
      style: GKText.pageTitle.copyWith(fontSize: 18),
    );
  }
}

class DynastyButton extends StatelessWidget {
  final String text;
  final VoidCallback onPressed;
  final Color color;

  const DynastyButton({
    super.key,
    required this.text,
    required this.onPressed,
    this.color = kGold,
  });

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      style: ElevatedButton.styleFrom(
        backgroundColor: color,
        foregroundColor: GKColors.inkBlack,
        minimumSize: const Size(double.infinity, 54),
        elevation: 4,
        shadowColor: Colors.black.withOpacity(.4),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(GKRadius.card),
        ),
      ),
      onPressed: onPressed,
      child: Text(text.toUpperCase(), style: GKText.button),
    );
  }
}

class SectionCard extends StatelessWidget {
  final String title;
  final Widget child;

  const SectionCard({
    super.key,
    required this.title,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 18),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: kCardColor,
        border: Border.all(color: kBorder),
        borderRadius: BorderRadius.circular(GKRadius.featured),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title.toUpperCase(), style: GKText.sectionLabel),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  Future<void> _restoreRemoveAds(BuildContext context) async {
    if (!PurchaseManager.storeAvailable) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('The App Store is not available right now.'),
        ),
      );
      return;
    }

    await PurchaseManager.restorePurchases();

    if (!context.mounted) return;

    await Future<void>.delayed(const Duration(milliseconds: 800));

    if (!context.mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          PurchaseManager.adsRemoved
              ? 'Your remove-ads purchase was restored.'
              : 'No previous remove-ads purchase was found.',
        ),
      ),
    );
  }

  Future<void> _openLoadScreen(BuildContext context) async {
    final saves = await loadCareerSaves();

    if (!context.mounted) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LoadCareerScreen(saves: saves),
      ),
    );
  }

  Future<void> _continueLatestCareer(BuildContext context) async {
    final saves = await loadCareerSaves();

    if (!context.mounted) return;

    if (saves.isEmpty) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => const TeamSelectionScreen(),
        ),
      );
      return;
    }

    saves.sort(
      (a, b) =>
          '${b['savedAt'] ?? ''}'.compareTo('${a['savedAt'] ?? ''}'),
    );

    final save = saves.first;
    final team = teamByName(save['team'] ?? '');
    final coach = coachFromJson(
      Map<String, dynamic>.from(save['coach'] ?? {}),
    );

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DashboardScreen(
          team: team,
          coach: coach,
          careerId: careerKeyFromSave(save),
          savedCareer: save,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: GKBackground(
        child: SafeArea(
          child: FutureBuilder<List<Map<String, dynamic>>>(
            future: loadCareerSaves(),
            builder: (context, snapshot) {
              final saves = snapshot.data ?? const <Map<String, dynamic>>[];
              final hasSave = saves.isNotEmpty;

              Map<String, dynamic>? latestSave;
              if (hasSave) {
                final sorted = [...saves]
                  ..sort(
                    (a, b) => '${b['savedAt'] ?? ''}'
                        .compareTo('${a['savedAt'] ?? ''}'),
                  );
                latestSave = sorted.first;
              }

              return Padding(
                padding: const EdgeInsets.fromLTRB(
                  GKSpace.xl,
                  GKSpace.lg,
                  GKSpace.xl,
                  GKSpace.xl,
                ),
                child: Column(
                  children: [
                    const Spacer(flex: 2),
                    const GKStudioMark(),
                    const SizedBox(height: GKSpace.xxl),
                    Text(
                      'GRIDIRON\nKINGDOM',
                      textAlign: TextAlign.center,
                      style: GKText.display,
                    ),
                    const SizedBox(height: GKSpace.sm),
                    Text(
                      'BUILD A PROGRAM. SHAPE A LEGACY.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: GKColors.mutedSilver,
                        fontSize: 11,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.9,
                      ),
                    ),
                    const Spacer(flex: 2),

                    if (latestSave != null) ...[
                      _LatestDynastyPreview(save: latestSave),
                      const SizedBox(height: GKSpace.md),
                      GKPrimaryButton(
                        label: 'Continue Dynasty',
                        icon: Icons.play_arrow_rounded,
                        onPressed: () => _continueLatestCareer(context),
                      ),
                    ] else
                      GKPrimaryButton(
                        label: 'Start New Dynasty',
                        icon: Icons.sports_football_rounded,
                        onPressed: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const TeamSelectionScreen(),
                            ),
                          );
                        },
                      ),

                    const SizedBox(height: GKSpace.sm),

                    if (hasSave)
                      GKSecondaryButton(
                        label: 'New Dynasty',
                        icon: Icons.add_rounded,
                        onPressed: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const TeamSelectionScreen(),
                            ),
                          );
                        },
                      ),

                    if (hasSave) const SizedBox(height: GKSpace.sm),

                    GKSecondaryButton(
                      label: hasSave ? 'Manage Saved Careers' : 'Load Dynasty',
                      icon: Icons.folder_open_rounded,
                      onPressed: () => _openLoadScreen(context),
                    ),

                    const SizedBox(height: GKSpace.sm),

                    if (!PurchaseManager.adsRemoved)
                      TextButton(
                        onPressed: () => AdManager._showRemoveAdsOffer(context),
                        child: Text(
                          'REMOVE ADS',
                          style: TextStyle(
                            color: GKColors.mutedSilver,
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.3,
                          ),
                        ),
                      ),

                    TextButton(
                      onPressed: () => _restoreRemoveAds(context),
                      child: Text(
                        'RESTORE PURCHASES',
                        style: TextStyle(
                          color: GKColors.mutedSilver,
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.3,
                        ),
                      ),
                    ),

                    Text(
                      'A GAME DAY STUDIOS EXPERIENCE',
                      style: TextStyle(
                        color: GKColors.fadedInk.withOpacity(.55),
                        fontSize: 9,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 2,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _LatestDynastyPreview extends StatelessWidget {
  final Map<String, dynamic> save;

  const _LatestDynastyPreview({
    required this.save,
  });

  @override
  Widget build(BuildContext context) {
    final team = teamByName(save['team'] ?? '');
    final coach = coachFromJson(
      Map<String, dynamic>.from(save['coach'] ?? {}),
    );
    final record = '${save['wins'] ?? 0}-${save['losses'] ?? 0}';
    final season = save['season'] ?? 1;
    final week = save['gamesPlayed'] ?? 0;

    return GKCard(
      padding: const EdgeInsets.all(GKSpace.md),
      color: gkDarkenedSchoolColor(team.primary, .72),
      borderColor: team.primary.withOpacity(.65),
      child: Row(
        children: [
          GKTeamBadge(team: team, size: 58),
          const SizedBox(width: GKSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('CURRENT DYNASTY', style: GKText.sectionLabel),
                const SizedBox(height: 5),
                Text(team.name, style: GKText.cardTitle),
                const SizedBox(height: 3),
                Text(
                  'Coach ${coach.name}  •  Season $season  •  $record',
                  style: GKText.body.copyWith(fontSize: 12),
                ),
              ],
            ),
          ),
          Column(
            children: [
              Text(
                record,
                style: const TextStyle(
                  color: GKColors.kingdomGold,
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                ),
              ),
              Text(
                'WEEK ${week + 1}',
                style: const TextStyle(
                  color: GKColors.mutedSilver,
                  fontSize: 9,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class LoadCareerScreen extends StatelessWidget {
  final List<Map<String, dynamic>> saves;

  const LoadCareerScreen({
    super.key,
    required this.saves,
  });

  List<Map<String, dynamic>> _latestCareerSaves() {
    final latestByCareer = <String, Map<String, dynamic>>{};

    for (final save in saves) {
      final key = careerKeyFromSave(save);
      final existing = latestByCareer[key];

      if (existing == null ||
          '${save['savedAt'] ?? ''}'
                  .compareTo('${existing['savedAt'] ?? ''}') >
              0) {
        latestByCareer[key] = save;
      }
    }

    return latestByCareer.values.toList()
      ..sort(
        (a, b) =>
            '${b['savedAt'] ?? ''}'.compareTo('${a['savedAt'] ?? ''}'),
      );
  }

  @override
  Widget build(BuildContext context) {
    final sorted = _latestCareerSaves();

    return Scaffold(
      body: GKBackground(
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  GKSpace.sm,
                  GKSpace.xs,
                  GKSpace.xl,
                  GKSpace.md,
                ),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(
                        Icons.arrow_back_ios_new_rounded,
                        color: GKColors.warmWhite,
                      ),
                    ),
                    const SizedBox(width: GKSpace.xs),
                    const Expanded(
                      child: GKSectionHeader(
                        title: 'Saved Careers',
                        subtitle:
                            'Continue a coaching career without changing its simulation data.',
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: sorted.isEmpty
                    ? _EmptyCareerState(
                        onStart: () {
                          Navigator.of(context).pushReplacement(
                            MaterialPageRoute(
                              builder: (_) => const TeamSelectionScreen(),
                            ),
                          );
                        },
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(
                          GKSpace.xl,
                          GKSpace.sm,
                          GKSpace.xl,
                          GKSpace.xxl,
                        ),
                        itemCount: sorted.length,
                        separatorBuilder: (_, _unused) =>
                            const SizedBox(height: GKSpace.sm),
                        itemBuilder: (context, index) {
                          return _CareerSaveCard(
                            save: sorted[index],
                            isMostRecent: index == 0,
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CareerSaveCard extends StatelessWidget {
  final Map<String, dynamic> save;
  final bool isMostRecent;

  const _CareerSaveCard({
    required this.save,
    required this.isMostRecent,
  });

  @override
  Widget build(BuildContext context) {
    final team = teamByName(save['team'] ?? '');
    final coach = coachFromJson(
      Map<String, dynamic>.from(save['coach'] ?? {}),
    );
    final wins = save['wins'] ?? 0;
    final losses = save['losses'] ?? 0;
    final record = '$wins-$losses';
    final season = save['season'] ?? 1;
    final gamesPlayed = save['gamesPlayed'] ?? 0;
    final ranking = save['ranking'] ?? save['displayRank'];

    return GKCard(
      onTap: () {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => DashboardScreen(
              team: team,
              coach: coach,
              careerId: careerKeyFromSave(save),
              savedCareer: save,
            ),
          ),
        );
      },
      padding: EdgeInsets.zero,
      color: gkDarkenedSchoolColor(team.primary, .77),
      borderColor: isMostRecent
          ? team.primary.withOpacity(.85)
          : GKColors.divider,
      radius: GKRadius.featured,
      child: Column(
        children: [
          Container(
            height: 6,
            decoration: BoxDecoration(
              color: team.primary,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(GKRadius.featured),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(GKSpace.md),
            child: Row(
              children: [
                GKTeamBadge(team: team, size: 62),
                const SizedBox(width: GKSpace.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (isMostRecent) ...[
                        Text(
                          'MOST RECENT',
                          style: GKText.sectionLabel,
                        ),
                        const SizedBox(height: 4),
                      ],
                      Text(
                        ranking is int && ranking <= 25
                            ? '#$ranking ${team.name}'
                            : team.name,
                        style: GKText.cardTitle.copyWith(fontSize: 19),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        'Coach ${coach.name}',
                        style: GKText.body.copyWith(
                          color: GKColors.warmWhite,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        'Season $season  •  Week ${gamesPlayed + 1}',
                        style: GKText.body.copyWith(fontSize: 12),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: GKSpace.sm),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      record,
                      style: const TextStyle(
                        color: GKColors.kingdomGold,
                        fontSize: 24,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    Text(
                      'RECORD',
                      style: TextStyle(
                        color: GKColors.mutedSilver,
                        fontSize: 9,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.3,
                      ),
                    ),
                    const SizedBox(height: GKSpace.sm),
                    const Icon(
                      Icons.arrow_forward_rounded,
                      color: GKColors.kingdomGold,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyCareerState extends StatelessWidget {
  final VoidCallback onStart;

  const _EmptyCareerState({
    required this.onStart,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(GKSpace.xl),
        child: GKCard(
          padding: const EdgeInsets.all(GKSpace.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.emoji_events_outlined,
                color: GKColors.kingdomGold,
                size: 48,
              ),
              const SizedBox(height: GKSpace.md),
              Text(
                'NO DYNASTIES YET',
                style: GKText.cardTitle,
              ),
              const SizedBox(height: GKSpace.xs),
              Text(
                'Choose a program, create your coach, and begin building a legacy.',
                textAlign: TextAlign.center,
                style: GKText.body,
              ),
              const SizedBox(height: GKSpace.xl),
              GKPrimaryButton(
                label: 'Start New Dynasty',
                icon: Icons.sports_football_rounded,
                onPressed: onStart,
              ),
            ],
          ),
        ),
      ),
    );
  }
}


class GKSetupProgress extends StatelessWidget {
  final int currentStep;

  const GKSetupProgress({
    super.key,
    required this.currentStep,
  });

  @override
  Widget build(BuildContext context) {
    const labels = ['Program', 'Coach', 'Contract'];

    return Row(
      children: List.generate(labels.length, (index) {
        final complete = index < currentStep;
        final active = index == currentStep;

        return Expanded(
          child: Row(
            children: [
              Expanded(
                child: Column(
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      height: 4,
                      decoration: BoxDecoration(
                        color: complete || active
                            ? GKColors.kingdomGold
                            : GKColors.divider,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    const SizedBox(height: 7),
                    Text(
                      labels[index].toUpperCase(),
                      style: TextStyle(
                        color: active
                            ? GKColors.warmWhite
                            : complete
                                ? GKColors.kingdomGold
                                : GKColors.mutedSilver,
                        fontSize: 9,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ],
                ),
              ),
              if (index != labels.length - 1)
                const SizedBox(width: GKSpace.xs),
            ],
          ),
        );
      }),
    );
  }
}

class GKSetupHeader extends StatelessWidget {
  final int step;
  final String title;
  final String subtitle;
  final VoidCallback onBack;

  const GKSetupHeader({
    super.key,
    required this.step,
    required this.title,
    required this.subtitle,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        GKSpace.sm,
        GKSpace.xs,
        GKSpace.xl,
        GKSpace.md,
      ),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              IconButton(
                onPressed: onBack,
                icon: const Icon(
                  Icons.arrow_back_ios_new_rounded,
                  color: GKColors.warmWhite,
                ),
              ),
              const SizedBox(width: GKSpace.xs),
              Expanded(
                child: GKSectionHeader(
                  title: title,
                  subtitle: subtitle,
                ),
              ),
            ],
          ),
          const SizedBox(height: GKSpace.md),
          Padding(
            padding: const EdgeInsets.only(left: 52),
            child: GKSetupProgress(currentStep: step),
          ),
        ],
      ),
    );
  }
}

class TeamSelectionScreen extends StatefulWidget {
  const TeamSelectionScreen({super.key});

  @override
  State<TeamSelectionScreen> createState() => _TeamSelectionScreenState();
}

class _TeamSelectionScreenState extends State<TeamSelectionScreen> {
  String conferenceFilter = 'All';
  String searchQuery = '';

  bool _isUnlockedStarter(CollegeTeam team) {
    return prestige100(team.prestige) <= 59;
  }

  List<String> get conferences {
    final values = g5Teams.map((team) => team.conference).toSet().toList()
      ..sort();
    return ['All', ...values];
  }

  List<CollegeTeam> get visibleTeams {
    final query = searchQuery.trim().toLowerCase();

    final teams = g5Teams.where((team) {
      final conferenceMatch =
          conferenceFilter == 'All' || team.conference == conferenceFilter;
      final searchMatch = query.isEmpty ||
          team.name.toLowerCase().contains(query) ||
          team.conference.toLowerCase().contains(query);

      return conferenceMatch && searchMatch;
    }).toList();

    teams.sort((a, b) {
      final unlockedCompare = _isUnlockedStarter(b)
          .toString()
          .compareTo(_isUnlockedStarter(a).toString());
      if (unlockedCompare != 0) return unlockedCompare;

      final prestigeCompare =
          prestige100(a.prestige).compareTo(prestige100(b.prestige));
      if (prestigeCompare != 0) return prestigeCompare;

      return a.name.compareTo(b.name);
    });

    return teams;
  }

  void _selectTeam(CollegeTeam team) {
    if (!_isUnlockedStarter(team)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${team.name} is not available as a first head-coaching job. Build your résumé and earn this opportunity later.',
          ),
        ),
      );
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CoachSetupScreen(team: team),
      ),
    );
  }

  String _programChallenge(CollegeTeam team) {
    final prestige = prestige100(team.prestige);
    if (prestige <= 52) return 'Complete rebuild';
    if (prestige <= 55) return 'Major rebuild';
    if (prestige <= 59) return 'Developing program';
    if (prestige <= 69) return 'Bowl contender';
    if (prestige <= 79) return 'Conference contender';
    return 'National contender';
  }

  int _expectedWins(CollegeTeam team) {
    return realisticExpectedWins(team.prestige);
  }

  @override
  Widget build(BuildContext context) {
    final teams = visibleTeams;
    final availableCount = teams.where(_isUnlockedStarter).length;

    return Scaffold(
      body: GKBackground(
        child: SafeArea(
          child: Column(
            children: [
              GKSetupHeader(
                step: 0,
                title: 'Choose Your Program',
                subtitle:
                    'Begin at a rebuilding program, establish your identity, and earn bigger opportunities.',
                onBack: () => Navigator.of(context).pop(),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  GKSpace.xl,
                  0,
                  GKSpace.xl,
                  GKSpace.sm,
                ),
                child: Column(
                  children: [
                    TextField(
                      onChanged: (value) {
                        setState(() => searchQuery = value);
                      },
                      style: const TextStyle(
                        color: GKColors.warmWhite,
                        fontWeight: FontWeight.w700,
                      ),
                      decoration: InputDecoration(
                        hintText: 'Search programs or conferences',
                        hintStyle: const TextStyle(
                          color: GKColors.mutedSilver,
                        ),
                        prefixIcon: const Icon(
                          Icons.search_rounded,
                          color: GKColors.mutedSilver,
                        ),
                        filled: true,
                        fillColor: GKColors.broadcastNavy.withOpacity(.88),
                        enabledBorder: OutlineInputBorder(
                          borderSide:
                              const BorderSide(color: GKColors.divider),
                          borderRadius:
                              BorderRadius.circular(GKRadius.card),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderSide: const BorderSide(
                            color: GKColors.kingdomGold,
                            width: 1.5,
                          ),
                          borderRadius:
                              BorderRadius.circular(GKRadius.card),
                        ),
                      ),
                    ),
                    const SizedBox(height: GKSpace.sm),
                    SizedBox(
                      height: 42,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: conferences.length,
                        separatorBuilder: (_, _unused) =>
                            const SizedBox(width: GKSpace.xs),
                        itemBuilder: (context, index) {
                          final conference = conferences[index];
                          final selected = conferenceFilter == conference;

                          return ChoiceChip(
                            label: Text(conference),
                            selected: selected,
                            onSelected: (_) {
                              setState(() => conferenceFilter = conference);
                            },
                            selectedColor: GKColors.kingdomGold,
                            backgroundColor: GKColors.broadcastNavy,
                            side: BorderSide(
                              color: selected
                                  ? GKColors.kingdomGold
                                  : GKColors.divider,
                            ),
                            labelStyle: TextStyle(
                              color:
                                  selected ? GKColors.inkBlack : GKColors.warmWhite,
                              fontWeight: FontWeight.w900,
                              fontSize: 12,
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: GKSpace.xl,
                  vertical: GKSpace.xs,
                ),
                child: Row(
                  children: [
                    Text(
                      '$availableCount STARTING JOBS',
                      style: GKText.sectionLabel,
                    ),
                    const Spacer(),
                    const Icon(
                      Icons.lock_outline_rounded,
                      color: GKColors.mutedSilver,
                      size: 15,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      'Higher-tier jobs unlock later',
                      style: TextStyle(
                        color: GKColors.mutedSilver,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: teams.isEmpty
                    ? Center(
                        child: Text(
                          'No programs match this search.',
                          style: GKText.body,
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(
                          GKSpace.xl,
                          GKSpace.xs,
                          GKSpace.xl,
                          GKSpace.xxl,
                        ),
                        itemCount: teams.length,
                        separatorBuilder: (_, _unused) =>
                            const SizedBox(height: GKSpace.sm),
                        itemBuilder: (context, index) {
                          final team = teams[index];

                          return TeamCard(
                            team: team,
                            locked: !_isUnlockedStarter(team),
                            stars: prestigeStars(team.prestige),
                            challenge: _programChallenge(team),
                            expectedWins: _expectedWins(team),
                            onTap: () => _selectTeam(team),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class TeamCard extends StatelessWidget {
  final CollegeTeam team;
  final bool locked;
  final String stars;
  final String challenge;
  final int expectedWins;
  final VoidCallback onTap;

  const TeamCard({
    super.key,
    required this.team,
    required this.locked,
    required this.stars,
    required this.challenge,
    required this.expectedWins,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final teamColor = locked
        ? GKColors.broadcastNavy
        : gkDarkenedSchoolColor(team.primary, .72);
    final borderColor =
        locked ? GKColors.divider : team.primary.withOpacity(.68);

    return Opacity(
      opacity: locked ? .58 : 1,
      child: GKCard(
        onTap: onTap,
        color: teamColor,
        borderColor: borderColor,
        radius: GKRadius.featured,
        padding: EdgeInsets.zero,
        child: Column(
          children: [
            Container(
              height: 5,
              decoration: BoxDecoration(
                color: locked ? GKColors.divider : team.primary,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(GKRadius.featured),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(GKSpace.md),
              child: Row(
                children: [
                  GKTeamBadge(team: team, size: 66),
                  const SizedBox(width: GKSpace.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${team.emoji} ${team.fullName.toUpperCase()}',
                                style: GKText.cardTitle.copyWith(fontSize: 18),
                              ),
                            ),
                            if (locked)
                              const Icon(
                                Icons.lock_rounded,
                                color: GKColors.mutedSilver,
                                size: 18,
                              )
                            else
                              const Icon(
                                Icons.arrow_forward_rounded,
                                color: GKColors.kingdomGold,
                              ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          team.conference.toUpperCase(),
                          style: const TextStyle(
                            color: GKColors.mutedSilver,
                            fontSize: 10,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1.3,
                          ),
                        ),
                        const SizedBox(height: GKSpace.sm),
                        Wrap(
                          spacing: GKSpace.xs,
                          runSpacing: GKSpace.xs,
                          children: [
                            _TeamInfoPill(
                              icon: Icons.star_rounded,
                              text: stars,
                            ),
                            _TeamInfoPill(
                              icon: Icons.flag_rounded,
                              text: '$expectedWins-win expectation',
                            ),
                            _TeamInfoPill(
                              icon: Icons.trending_up_rounded,
                              text: challenge,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TeamInfoPill extends StatelessWidget {
  final IconData icon;
  final String text;

  const _TeamInfoPill({
    required this.icon,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: 9,
        vertical: 6,
      ),
      decoration: BoxDecoration(
        color: GKColors.midnight.withOpacity(.58),
        border: Border.all(color: GKColors.divider),
        borderRadius: BorderRadius.circular(GKRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: GKColors.kingdomGold, size: 13),
          const SizedBox(width: 5),
          Text(
            text,
            style: const TextStyle(
              color: GKColors.warmWhite,
              fontSize: 10,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class CoachSetupScreen extends StatefulWidget {
  final CollegeTeam team;

  const CoachSetupScreen({
    super.key,
    required this.team,
  });

  @override
  State<CoachSetupScreen> createState() => _CoachSetupScreenState();
}

class _CoachSetupScreenState extends State<CoachSetupScreen> {
  final TextEditingController nameController = TextEditingController();

  String skinTone = 'Tan';
  String hairStyle = 'Curly';
  String hairColor = 'Brown';
  String beard = 'None';
  bool glasses = false;
  String coachType = 'Offensive Mind';
  String offensiveScheme = 'Air Raid';
  String defensiveScheme = '4-3 Defense';

  final hairStyles = const [
    'Short',
    'Buzz Cut',
    'Curly',
    'Waves',
    'Long',
    'Bald',
    'Fade',
    'Afro',
    'Mohawk',
    'Slick Back',
    'Man Bun',
    'Dreads',
  ];

  final beardOptions = const [
    'None',
    'Stubble',
    'Goatee',
    'Mustache',
    'Chin Strap',
    'Soul Patch',
    'Full Beard',
  ];

  final offensiveSchemes = const [
    'Air Raid',
    'Ground & Pound',
    'Option',
    'Pro Style',
    'Spread',
  ];

  final defensiveSchemes = const [
    '4-3 Defense',
    '3-4 Defense',
    'Nickel',
    'Man Blitz',
    'Zone Heavy',
  ];

  Color get skinColor => coachSkinColorFor(skinTone);

  Color get coachHairColor => coachHairColorFor(hairColor);

  String get coachTypeDescription {
    return switch (coachType) {
      'Offensive Mind' =>
        'Builds explosive offenses and develops quarterbacks.',
      'Defensive Mind' =>
        'Creates physical defenses and improves weekly preparation.',
      'Motivator' =>
        'Builds culture, improves retention, and steadies momentum.',
      _ => 'Wins recruiting battles and builds stronger classes.',
    };
  }

  String _offensiveDescription(String scheme) {
    return switch (scheme) {
      'Air Raid' => 'Pass-first attack built around tempo and explosive plays.',
      'Ground & Pound' =>
        'Physical rushing identity that controls possession and wears teams down.',
      'Option' =>
        'Quarterback-driven rushing system with high upside and added risk.',
      'Spread' =>
        'Creates space, balances the field, and stresses defensive matchups.',
      _ => 'Traditional balanced system adaptable to roster strengths.',
    };
  }

  String _defensiveDescription(String scheme) {
    return switch (scheme) {
      '4-3 Defense' =>
        'Balanced front designed to control the run without sacrificing coverage.',
      '3-4 Defense' =>
        'Flexible linebacker pressure with multiple pass-rush looks.',
      'Nickel' =>
        'Extra defensive back improves coverage against modern passing attacks.',
      'Man Blitz' =>
        'Aggressive pressure creates negative plays but exposes the secondary.',
      _ => 'Disciplined zone structure limits explosive plays.',
    };
  }

  void _continue() {
    final coachName = nameController.text.trim();

    final coach = CoachProfile(
      name: coachName.isEmpty ? 'Coach' : coachName,
      skinTone: skinTone,
      hairStyle: hairStyle,
      hairColor: hairColor,
      beard: beard,
      glasses: glasses,
      coachType: coachType,
      offensiveScheme: offensiveScheme,
      defensiveScheme: defensiveScheme,
    );

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ContractSigningScreen(
          team: widget.team,
          coach: coach,
        ),
      ),
    );
  }

  void _cycleHair(int direction) {
    final index = hairStyles.indexOf(hairStyle);
    final next = (index + direction) % hairStyles.length;

    setState(() {
      hairStyle = hairStyles[next < 0 ? next + hairStyles.length : next];
    });
  }

  void _cycleBeard(int direction) {
    final index = beardOptions.indexOf(beard);
    final next = (index + direction) % beardOptions.length;

    setState(() {
      beard = beardOptions[next < 0 ? next + beardOptions.length : next];
    });
  }

  Widget _colorChoice({
    required Color color,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Semantics(
      selected: selected,
      button: true,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: 32,
          height: 32,
          margin: const EdgeInsets.only(left: 9),
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected
                  ? GKColors.kingdomGold
                  : GKColors.parchmentWhite.withOpacity(.25),
              width: selected ? 4 : 2,
            ),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: GKColors.kingdomGold.withOpacity(.24),
                      blurRadius: 8,
                      offset: const Offset(0, 3),
                    ),
                  ]
                : null,
          ),
        ),
      ),
    );
  }

  Widget _appearanceControl({
    required String label,
    required String value,
    required VoidCallback previous,
    required VoidCallback next,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: GKSpace.sm),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: GKColors.divider),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label.toUpperCase(),
              style: const TextStyle(
                color: GKColors.mutedSilver,
                fontSize: 11,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.3,
              ),
            ),
          ),
          IconButton(
            onPressed: previous,
            icon: const Icon(
              Icons.chevron_left_rounded,
              color: GKColors.warmWhite,
            ),
          ),
          SizedBox(
            width: 90,
            child: Text(
              value,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: GKColors.warmWhite,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          IconButton(
            onPressed: next,
            icon: const Icon(
              Icons.chevron_right_rounded,
              color: GKColors.warmWhite,
            ),
          ),
        ],
      ),
    );
  }

  Widget _coachTypeCard({
    required String title,
    required IconData icon,
  }) {
    final selected = coachType == title;

    return Expanded(
      child: GKCard(
        onTap: () => setState(() => coachType = title),
        padding: const EdgeInsets.all(GKSpace.sm),
        color: selected
            ? gkDarkenedSchoolColor(widget.team.primary, .57)
            : GKColors.broadcastNavy,
        borderColor:
            selected ? widget.team.primary : GKColors.divider,
        radius: GKRadius.small,
        child: Column(
          children: [
            Icon(
              icon,
              color: selected
                  ? GKColors.kingdomGold
                  : GKColors.mutedSilver,
              size: 26,
            ),
            const SizedBox(height: GKSpace.xs),
            Text(
              title.toUpperCase(),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: selected
                    ? GKColors.warmWhite
                    : GKColors.mutedSilver,
                fontSize: 10,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _philosophyChoice({
    required String title,
    required String description,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: GKSpace.xs),
      child: GKCard(
        onTap: onTap,
        color: selected
            ? gkDarkenedSchoolColor(widget.team.primary, .62)
            : GKColors.broadcastNavy,
        borderColor:
            selected ? widget.team.primary : GKColors.divider,
        radius: GKRadius.small,
        padding: const EdgeInsets.all(GKSpace.sm),
        child: Row(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected
                    ? GKColors.kingdomGold
                    : Colors.transparent,
                border: Border.all(
                  color: selected
                      ? GKColors.kingdomGold
                      : GKColors.mutedSilver,
                  width: 2,
                ),
              ),
              child: selected
                  ? const Icon(
                      Icons.check_rounded,
                      color: GKColors.inkBlack,
                      size: 17,
                    )
                  : null,
            ),
            const SizedBox(width: GKSpace.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title.toUpperCase(), style: GKText.cardTitle),
                  const SizedBox(height: 4),
                  Text(
                    description,
                    style: GKText.body.copyWith(fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: GKBackground(
        child: SafeArea(
          child: Column(
            children: [
              GKSetupHeader(
                step: 1,
                title: 'Create Your Coach',
                subtitle:
                    '${widget.team.name} — define the leader, personality, and football identity that will shape this dynasty.',
                onBack: () => Navigator.of(context).pop(),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(
                    GKSpace.xl,
                    GKSpace.sm,
                    GKSpace.xl,
                    GKSpace.xxl,
                  ),
                  children: [
                    GKCard(
                      color:
                          gkDarkenedSchoolColor(widget.team.primary, .72),
                      borderColor: widget.team.primary.withOpacity(.72),
                      radius: GKRadius.featured,
                      child: Row(
                        children: [
                          Container(
                            width: 142,
                            height: 142,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: GKColors.midnight,
                              border: Border.all(
                                color: GKColors.kingdomGold,
                                width: 3,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: widget.team.primary.withOpacity(.26),
                                  blurRadius: 14,
                                  offset: const Offset(0, 6),
                                ),
                              ],
                            ),
                            child: ClipOval(
                              child: CustomPaint(
                                painter: CoachAvatarPainter(
                                  skinColor: skinColor,
                                  hairColor: coachHairColor,
                                  hairStyle: hairStyle,
                                  beard: beard,
                                  glasses: glasses,
                                  teamColor: widget.team.primary,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: GKSpace.md),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                GKTeamBadge(team: widget.team, size: 52),
                                const SizedBox(height: GKSpace.sm),
                                Text(
                                  widget.team.fullName.toUpperCase(),
                                  style: GKText.cardTitle,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '${widget.team.conference} • ${prestigeStars(widget.team.prestige)} program',
                                  style:
                                      GKText.body.copyWith(fontSize: 12),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: GKSpace.md),
                    GKCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('COACH IDENTITY', style: GKText.sectionLabel),
                          const SizedBox(height: GKSpace.sm),
                          TextField(
                            controller: nameController,
                            textCapitalization: TextCapitalization.words,
                            style: const TextStyle(
                              color: GKColors.warmWhite,
                              fontWeight: FontWeight.w800,
                            ),
                            decoration: InputDecoration(
                              labelText: 'Coach name',
                              labelStyle: const TextStyle(
                                color: GKColors.mutedSilver,
                              ),
                              prefixIcon: const Icon(
                                Icons.badge_outlined,
                                color: GKColors.kingdomGold,
                              ),
                              filled: true,
                              fillColor: GKColors.midnight.withOpacity(.65),
                              enabledBorder: OutlineInputBorder(
                                borderSide: const BorderSide(
                                  color: GKColors.divider,
                                ),
                                borderRadius:
                                    BorderRadius.circular(GKRadius.small),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderSide: const BorderSide(
                                  color: GKColors.kingdomGold,
                                  width: 1.5,
                                ),
                                borderRadius:
                                    BorderRadius.circular(GKRadius.small),
                              ),
                            ),
                          ),
                          const SizedBox(height: GKSpace.md),
                          Text('SKIN TONE', style: GKText.sectionLabel.copyWith(fontSize: 11)),
                          const SizedBox(height: GKSpace.xs),
                          Wrap(
                            spacing: 9,
                            runSpacing: 9,
                            children: [
                              _colorChoice(
                                color: Color(0xFFF5D4A8),
                                selected: skinTone == 'Fair',
                                onTap: () => setState(() => skinTone = 'Fair'),
                              ),
                              _colorChoice(
                                color: Color(0xFFF1C27D),
                                selected: skinTone == 'Light',
                                onTap: () =>
                                    setState(() => skinTone = 'Light'),
                              ),
                              _colorChoice(
                                color: Color(0xFFD6A06A),
                                selected: skinTone == 'Tan',
                                onTap: () =>
                                    setState(() => skinTone = 'Tan'),
                              ),
                              _colorChoice(
                                color: Color(0xFFC08552),
                                selected: skinTone == 'Olive',
                                onTap: () => setState(() => skinTone = 'Olive'),
                              ),
                              _colorChoice(
                                color: Color(0xFFA86B32),
                                selected: skinTone == 'Brown',
                                onTap: () =>
                                    setState(() => skinTone = 'Brown'),
                              ),
                              _colorChoice(
                                color: Color(0xFF6B4423),
                                selected: skinTone == 'Deep',
                                onTap: () => setState(() => skinTone = 'Deep'),
                              ),
                              _colorChoice(
                                color: Color(0xFF5C3317),
                                selected: skinTone == 'Dark',
                                onTap: () =>
                                    setState(() => skinTone = 'Dark'),
                              ),
                            ],
                          ),
                          const SizedBox(height: GKSpace.sm),
                          _appearanceControl(
                            label: 'Hair',
                            value: hairStyle,
                            previous: () => _cycleHair(-1),
                            next: () => _cycleHair(1),
                          ),
                          const SizedBox(height: GKSpace.xs),
                          Text('HAIR COLOR', style: GKText.sectionLabel.copyWith(fontSize: 11)),
                          const SizedBox(height: GKSpace.xs),
                          Wrap(
                            spacing: 9,
                            runSpacing: 9,
                            children: [
                              _colorChoice(
                                color: GKColors.inkBlack,
                                selected: hairColor == 'Black',
                                onTap: () =>
                                    setState(() => hairColor = 'Black'),
                              ),
                              _colorChoice(
                                color: Color(0xFF3A2417),
                                selected: hairColor == 'Dark Brown',
                                onTap: () => setState(() => hairColor = 'Dark Brown'),
                              ),
                              _colorChoice(
                                color: Color(0xFF4E2A14),
                                selected: hairColor == 'Brown',
                                onTap: () =>
                                    setState(() => hairColor = 'Brown'),
                              ),
                              _colorChoice(
                                color: Color(0xFF7A3B2E),
                                selected: hairColor == 'Auburn',
                                onTap: () => setState(() => hairColor = 'Auburn'),
                              ),
                              _colorChoice(
                                color: Color(0xFFB8895A),
                                selected: hairColor == 'Sandy',
                                onTap: () => setState(() => hairColor = 'Sandy'),
                              ),
                              _colorChoice(
                                color: Color(0xFFE6C35C),
                                selected: hairColor == 'Blonde',
                                onTap: () =>
                                    setState(() => hairColor = 'Blonde'),
                              ),
                              _colorChoice(
                                color: Color(0xFF9E2A2B),
                                selected: hairColor == 'Red',
                                onTap: () =>
                                    setState(() => hairColor = 'Red'),
                              ),
                              _colorChoice(
                                color: Color(0xFFC8C8C8),
                                selected: hairColor == 'Silver',
                                onTap: () => setState(() => hairColor = 'Silver'),
                              ),
                              _colorChoice(
                                color: GKColors.fadedInk,
                                selected: hairColor == 'Gray',
                                onTap: () =>
                                    setState(() => hairColor = 'Gray'),
                              ),
                            ],
                          ),
                          _appearanceControl(
                            label: 'Facial Hair',
                            value: beard,
                            previous: () => _cycleBeard(-1),
                            next: () => _cycleBeard(1),
                          ),
                          const SizedBox(height: GKSpace.xs),
                          Row(
                            children: [
                              Expanded(
                                child: Text('GLASSES',
                                    style: GKText.sectionLabel.copyWith(fontSize: 11)),
                              ),
                              Switch(
                                value: glasses,
                                activeThumbColor: GKColors.kingdomBrass,
                                onChanged: (v) => setState(() => glasses = v),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: GKSpace.md),
                    GKCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('COACH ARCHETYPE',
                              style: GKText.sectionLabel),
                          const SizedBox(height: GKSpace.sm),
                          Row(
                            children: [
                              _coachTypeCard(
                                title: 'Offensive Mind',
                                icon: Icons.bolt_rounded,
                              ),
                              const SizedBox(width: GKSpace.xs),
                              _coachTypeCard(
                                title: 'Defensive Mind',
                                icon: Icons.shield_outlined,
                              ),
                            ],
                          ),
                          const SizedBox(height: GKSpace.xs),
                          Row(
                            children: [
                              _coachTypeCard(
                                title: 'Motivator',
                                icon: Icons.campaign_outlined,
                              ),
                              const SizedBox(width: GKSpace.xs),
                              _coachTypeCard(
                                title: 'Recruiter',
                                icon: Icons.groups_2_outlined,
                              ),
                            ],
                          ),
                          const SizedBox(height: GKSpace.sm),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(GKSpace.sm),
                            decoration: BoxDecoration(
                              color: GKColors.midnight.withOpacity(.58),
                              borderRadius:
                                  BorderRadius.circular(GKRadius.small),
                            ),
                            child: Text(
                              coachTypeDescription,
                              style: GKText.body.copyWith(fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: GKSpace.md),
                    GKCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('OFFENSIVE PHILOSOPHY',
                              style: GKText.sectionLabel),
                          const SizedBox(height: GKSpace.sm),
                          ...offensiveSchemes.map(
                            (scheme) => _philosophyChoice(
                              title: scheme,
                              description:
                                  _offensiveDescription(scheme),
                              selected: offensiveScheme == scheme,
                              onTap: () => setState(
                                () => offensiveScheme = scheme,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: GKSpace.md),
                    GKCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('DEFENSIVE PHILOSOPHY',
                              style: GKText.sectionLabel),
                          const SizedBox(height: GKSpace.sm),
                          ...defensiveSchemes.map(
                            (scheme) => _philosophyChoice(
                              title: scheme,
                              description:
                                  _defensiveDescription(scheme),
                              selected: defensiveScheme == scheme,
                              onTap: () => setState(
                                () => defensiveScheme = scheme,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: GKSpace.md),
                    GKPrimaryButton(
                      label: 'Review Contract',
                      icon: Icons.description_outlined,
                      onPressed: _continue,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ContractSigningScreen extends StatelessWidget {
  final CollegeTeam team;
  final CoachProfile coach;

  const ContractSigningScreen({
    super.key,
    required this.team,
    required this.coach,
  });

  int get programTier => prestigeTier(team.prestige);

  int get expectedWins => realisticExpectedWins(team.prestige);

  String get goal => realisticContractGoal(team.prestige);

  String get jobSecurity => realisticJobSecurityLabel(team.prestige);

  int get contractYears {
    return switch (programTier) {
      1 => 3,
      2 => 3,
      3 => 4,
      4 => 4,
      _ => 5,
    };
  }

  void _sign(BuildContext context) {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => DashboardScreen(team: team, coach: coach),
      ),
    );
  }

  Widget _paperRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 11),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 126,
            child: Text(
              label.toUpperCase(),
              style: const TextStyle(
                color: Color(0xFF68717A),
                fontSize: 9,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.2,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value.toUpperCase(),
              textAlign: TextAlign.right,
              style: const TextStyle(
                color: Color(0xFF18212B),
                fontSize: 12,
                fontWeight: FontWeight.w900,
                height: 1.25,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final stars = List.generate(
      5,
      (index) => index < programTier ? '★' : '☆',
    ).join();

    return Scaffold(
      body: GKBackground(
        child: SafeArea(
          child: Column(
            children: [
              GKSetupHeader(
                step: 2,
                title: 'Sign Your Contract',
                subtitle:
                    'Review the program’s expectations before beginning your career.',
                onBack: () => Navigator.of(context).pop(),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(
                    GKSpace.xl,
                    GKSpace.sm,
                    GKSpace.xl,
                    GKSpace.xxl,
                  ),
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: Color(0xFFF3EFE4),
                        borderRadius:
                            BorderRadius.circular(GKRadius.featured),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(.35),
                            blurRadius: 30,
                            offset: const Offset(0, 18),
                          ),
                        ],
                      ),
                      child: Column(
                        children: [
                          Container(
                            height: 10,
                            decoration: BoxDecoration(
                              color: team.primary,
                              borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(GKRadius.featured),
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(
                              24,
                              24,
                              24,
                              28,
                            ),
                            child: Column(
                              children: [
                                Row(
                                  children: [
                                    GKTeamBadge(team: team, size: 72),
                                    const SizedBox(width: GKSpace.md),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            team.name.toUpperCase(),
                                            style: TextStyle(
                                              color: team.primary,
                                              fontSize: 24,
                                              fontWeight: FontWeight.w900,
                                              letterSpacing: 1.4,
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            'HEAD FOOTBALL COACH AGREEMENT',
                                            style: TextStyle(
                                              color: Color(0xFF68717A),
                                              fontSize: 9,
                                              fontWeight: FontWeight.w900,
                                              letterSpacing: 1.5,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: GKSpace.xl),
                                Container(
                                  width: double.infinity,
                                  height: 1,
                                  color: Color(0xFFC9C2B5),
                                ),
                                const SizedBox(height: GKSpace.sm),
                                _paperRow('Coach', coach.name),
                                _paperRow('Conference', team.conference),
                                _paperRow('Program Prestige', stars),
                                _paperRow(
                                  'Contract Length',
                                  '$contractYears years',
                                ),
                                _paperRow(
                                  'Expected Wins',
                                  '$expectedWins regular-season wins',
                                ),
                                _paperRow('Program Goal', goal),
                                _paperRow('Job Environment', jobSecurity),
                                _paperRow(
                                  'Offensive System',
                                  coach.offensiveScheme,
                                ),
                                _paperRow(
                                  'Defensive System',
                                  coach.defensiveScheme,
                                ),
                                _paperRow(
                                  'Coach Identity',
                                  coach.coachType,
                                ),
                                const SizedBox(height: GKSpace.lg),
                                Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.all(GKSpace.md),
                                  decoration: BoxDecoration(
                                    color: team.primary.withOpacity(.08),
                                    border: Border.all(
                                      color: team.primary.withOpacity(.28),
                                    ),
                                    borderRadius:
                                        BorderRadius.circular(GKRadius.small),
                                  ),
                                  child: Text(
                                    programTier == 1
                                        ? 'The administration understands this is a rebuild. Bowl eligibility represents a successful first season.'
                                        : 'Performance will be evaluated against the expectations listed in this agreement.',
                                    style: const TextStyle(
                                      color: Color(0xFF36404A),
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      height: 1.45,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 34),
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            coach.name,
                                            style: TextStyle(
                                              color: team.primary,
                                              fontSize: 23,
                                              fontWeight: FontWeight.w500,
                                              fontStyle: FontStyle.italic,
                                            ),
                                          ),
                                          Container(
                                            height: 1,
                                            color:
                                                Color(0xFF6F7478),
                                          ),
                                          const SizedBox(height: 5),
                                          Text(
                                            'HEAD COACH SIGNATURE',
                                            style: TextStyle(
                                              color: Color(0xFF68717A),
                                              fontSize: 8,
                                              fontWeight: FontWeight.w900,
                                              letterSpacing: 1.2,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: GKSpace.xl),
                                    Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.end,
                                      children: [
                                        Text(
                                          'SEASON 1',
                                          style: TextStyle(
                                            color: team.primary,
                                            fontWeight: FontWeight.w900,
                                          ),
                                        ),
                                        Text(
                                          'EFFECTIVE DATE',
                                          style: TextStyle(
                                            color: Color(0xFF68717A),
                                            fontSize: 8,
                                            fontWeight: FontWeight.w900,
                                            letterSpacing: 1.2,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: GKSpace.xl),
                    GKCard(
                      color: gkDarkenedSchoolColor(team.primary, .72),
                      borderColor: team.primary.withOpacity(.68),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.info_outline_rounded,
                            color: GKColors.kingdomGold,
                          ),
                          const SizedBox(width: GKSpace.sm),
                          Expanded(
                            child: Text(
                              'Signing begins your dynasty immediately. Your current save, simulation, advertising, and purchase systems remain unchanged.',
                              style: GKText.body.copyWith(fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: GKSpace.md),
                    GKPrimaryButton(
                      label: 'Sign Contract',
                      icon: Icons.draw_outlined,
                      onPressed: () => _sign(context),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class OffseasonResult {
  final CollegeTeam team;
  final List<Player> roster;
  final CollegeTeam? rivalry;
  final List<CollegeTeam> customNonConference;

  const OffseasonResult({
    required this.team,
    required this.roster,
    required this.rivalry,
    required this.customNonConference,
  });
}


int realisticExpectedWins(num prestigeValue) {
  return switch (prestigeTier(prestigeValue)) {
    1 => 6,
    2 => 6,
    3 => 7,
    4 => 8,
    _ => 10,
  };
}

String realisticContractGoal(num prestigeValue) {
  final expectedWins = realisticExpectedWins(prestigeValue);
  final tier = prestigeTier(prestigeValue);

  return switch (tier) {
    1 => 'WIN $expectedWins GAMES',
    2 => 'MAKE A BOWL',
    3 => 'WIN 7-8 GAMES',
    4 => 'CONTEND FOR CONFERENCE',
    _ => 'MAKE THE KP',
  };
}

String realisticJobSecurityLabel(num prestigeValue) {
  return switch (prestigeTier(prestigeValue)) {
    1 => 'REBUILDING',
    2 => 'DEVELOPING',
    3 => 'STABLE',
    4 => 'HIGH EXPECTATIONS',
    _ => 'CHAMPIONSHIP PRESSURE',
  };
}

int seasonScoreFor(int wins, int losses, int prestige) {
  final expectedWins = switch (prestige) {
    1 => 4,
    2 => 6,
    3 => 7,
    4 => 8,
    _ => 9,
  };

  return (50 + (wins - expectedWins) * 9 + wins * 2 - losses * 2).clamp(0, 100);
}

int maxJobPrestigeForSeason(int wins, int losses, int currentPrestige) {
  if (wins <= 6) return currentPrestige;
  if (wins == 7) return (currentPrestige + 1).clamp(1, 2);
  if (wins == 8) return (currentPrestige + 1).clamp(1, 3);
  if (wins == 9) return (currentPrestige + 2).clamp(1, 3);
  if (wins == 10) return (currentPrestige + 2).clamp(1, 4);
  return (currentPrestige + 3).clamp(1, 5);
}

int retentionBudgetForSeason(int wins, int losses, num prestige) {
  final base = switch (prestigeTier(prestige)) {
    1 => 500000,
    2 => 1000000,
    3 => 1800000,
    4 => 3500000,
    _ => 6000000,
  };

  final bonus = wins * 90000;
  final bowlBonus = wins >= 6 ? 200000 : 0;
  final greatSeason = wins >= 9 ? 550000 : 0;
  final eliteSeason = wins >= 11 ? 1200000 : 0;
  final penalty = losses * 30000;

  return (base + bonus + bowlBonus + greatSeason + eliteSeason - penalty).clamp(250000, 14000000);
}

String moneyText(int amount) {
  if (amount >= 1000000) {
    final m = amount / 1000000;
    return '\$${m.toStringAsFixed(m >= 10 ? 0 : 1)}M';
  }
  return '\$${(amount / 1000).round()}K';
}


List<String> skillCategoriesForPosition(String position) {
  return switch (position) {
    'QB' => ['Accuracy', 'Power', 'Mobility'],
    'HB' => ['Speed', 'Power', 'Ball Security'],
    'WR' => ['Speed', 'Hands', 'Route Running'],
    'TE' => ['Hands', 'Blocking', 'Power'],
    'DE' => ['Power', 'Pass Rush', 'Speed'],
    'LB' => ['Tackling', 'Coverage', 'Speed'],
    'DB' => ['Coverage', 'Speed', 'Tackling'],
    _ => ['Power', 'Speed', 'Awareness'],
  };
}

Map<String, int> playerSkillRatings(Player p) {
  final skills = skillCategoriesForPosition(p.position);
  final spread = [
    ((p.name.hashCode.abs() % 9) - 4),
    (((p.name.hashCode ~/ 7).abs() % 9) - 4),
    (((p.name.hashCode ~/ 13).abs() % 9) - 4),
  ];

  return {
    for (int i = 0; i < skills.length; i++)
      skills[i]: (p.overall + spread[i]).clamp(40, 94),
  };
}

int playerRetentionAsk(Player p) {
  return ((p.overall * p.overall * 42) + p.stars * 35000).round();
}




int transferMaxStarsForPrestige(num prestige, int wins) {
  final p = prestige100(prestige);
  var maxStars = 2;

  if (p >= 90) {
    maxStars = 5;
  } else if (p >= 80) {
    maxStars = 4;
  } else if (p >= 70) {
    maxStars = 4;
  } else if (p >= 60) {
    maxStars = 3;
  } else {
    maxStars = 2;
  }

  if (wins >= 9) maxStars += 1;
  if (wins <= 4) maxStars -= 1;

  return maxStars.clamp(1, 5);
}

int transferStarsForUserSchool(num prestige, int wins) {
  final maxStars = transferMaxStarsForPrestige(prestige, wins);
  final roll = rng.nextInt(100);

  if (maxStars <= 2) {
    if (roll < 72) return 1;
    if (roll < 96) return 2;
    return 3; // rare good transfer for a bad program
  }

  if (maxStars == 3) {
    if (roll < 42) return 1;
    if (roll < 82) return 2;
    if (roll < 98) return 3;
    return 4;
  }

  if (maxStars == 4) {
    if (roll < 20) return 2;
    if (roll < 58) return 3;
    if (roll < 94) return 4;
    return 5;
  }

  if (roll < 12) return 3;
  if (roll < 45) return 4;
  return 5;
}

int transferOverallForStarsAndPrestige(int stars, num prestige, int wins) {
  final p = prestige100(prestige);
  final maxAllowed = transferMaxStarsForPrestige(prestige, wins);

  // If a player is above the realistic max for the user's school, make them less common and not absurdly high.
  final effectiveStars = min(stars, maxAllowed);

  int minOvr;
  int maxOvr;
  switch (effectiveStars) {
    case 1:
      minOvr = 50;
      maxOvr = 61;
      break;
    case 2:
      minOvr = 58;
      maxOvr = 70;
      break;
    case 3:
      minOvr = 66;
      maxOvr = 78;
      break;
    case 4:
      minOvr = 75;
      maxOvr = 86;
      break;
    default:
      minOvr = 84;
      maxOvr = 94;
  }

  if (p < 60 && wins < 8) {
    maxOvr = min(maxOvr, 74);
  } else if (p < 70 && wins < 8) {
    maxOvr = min(maxOvr, 80);
  }

  return minOvr + rng.nextInt(max(1, maxOvr - minOvr + 1));
}

int transferInterestForUserSchool({
  required int playerStars,
  required int playerOverall,
  required num prestige,
  required int wins,
}) {
  final p = prestige100(prestige);
  final maxStars = transferMaxStarsForPrestige(prestige, wins);

  var interest = 35 + ((p - 50) ~/ 2) + (wins * 3);
  interest += (maxStars - playerStars) * 12;

  if (playerStars > maxStars) interest -= (playerStars - maxStars) * 28;
  if (playerOverall >= 88 && p < 80) interest -= 25;
  if (playerOverall >= 92 && p < 90) interest -= 30;
  if (wins >= 9) interest += 12;
  if (wins <= 4) interest -= 12;

  return interest.clamp(1, 99);
}

class TransferTarget {
  final String name;
  final String position;
  final int overall;
  final int potential;
  final String year;
  final int stars;
  final int interest;
  bool offered = false;
  bool signed = false;
  bool declined = false;

  TransferTarget({
    required this.name,
    required this.position,
    required this.overall,
    required this.potential,
    required this.year,
    required this.stars,
    required this.interest,
  });

  Player toPlayer() {
    return Player(
      name: name,
      position: position,
      overall: overall,
      potential: potential,
      year: year,
      stars: stars,
    );
  }

  double get lastYearYards {
    final base = overall * 7.0 + (name.hashCode.abs() % 220);
    if (position == 'QB') return base * 4.8;
    if (position == 'HB' || position == 'RB') return base * 2.2;
    if (position == 'WR' || position == 'TE') return base * 1.8;
    return base * .45;
  }

  int get lastYearTd {
    final bonus = position == 'QB' ? 15 : (position == 'HB' || position == 'RB' || position == 'WR') ? 6 : 2;
    return ((overall - 55) / 5).round().clamp(0, 12) + bonus;
  }

  int get lastYearTackles {
    if (['DE', 'DL', 'LB', 'DB', 'CB', 'S'].contains(position)) {
      return (overall + 15 + (name.hashCode.abs() % 55)).clamp(30, 145);
    }
    return (name.hashCode.abs() % 10);
  }

  String get transferProfileText {
    if (position == 'QB') return '${lastYearYards.round()} pass yds • $lastYearTd TD • ${lastYearTackles} tackles';
    if (position == 'HB' || position == 'RB') return '${lastYearYards.round()} rush yds • $lastYearTd TD';
    if (position == 'WR' || position == 'TE') return '${lastYearYards.round()} rec yds • $lastYearTd TD';
    return '$lastYearTackles tackles • $lastYearTd impact plays';
  }


  String get hometown {
    final states = ['TX', 'FL', 'CA', 'GA', 'OH', 'PA', 'NC', 'VA', 'AL', 'LA', 'AZ', 'NJ'];
    return states[name.hashCode.abs() % states.length];
  }

  String get previousSchool {
    final schools = [
      'Tempe', 'Boulder', 'Chestnut Hill', 'West Lafayette', 'Bluff City', 'Boise',
      'Orlando', 'Broad Street', 'Salt City', 'Old Dominion', 'Houston', 'Boone'
    ];
    return schools[(name.hashCode.abs() ~/ 7) % schools.length];
  }

  String get roleFit {
    if (overall >= 84) return 'Day-one starter';
    if (overall >= 76) return 'Rotation player with starter upside';
    if (overall >= 68) return 'Depth piece with development upside';
    return 'Long-term developmental add';
  }

  String get scoutingReport {
    final upside = potential - overall;
    if (upside >= 10) return 'High-upside transfer with room to grow quickly in the right system.';
    if (overall >= 82) return 'Polished veteran who can help immediately if the fit is right.';
    if (interest >= 75) return 'Strong interest and a realistic target for this program.';
    return 'Could be a tough pull, but worth monitoring if roster need is high.';
  }

  String get pastSeasonHeadline {
    if (position == 'QB') return '${lastYearYards.round()} pass yds • $lastYearTd TD';
    if (position == 'HB' || position == 'RB') return '${lastYearYards.round()} rush yds • $lastYearTd TD';
    if (position == 'WR' || position == 'TE') return '${lastYearYards.round()} rec yds • $lastYearTd TD';
    return '$lastYearTackles tackles • $lastYearTd impact plays';
  }

}



List<int> jobOfferPrestigeTargets({
  required int currentPrestige,
  required int wins,
  required int losses,
  required int expectedWins,
}) {
  final current = prestige100(currentPrestige);
  final overExpectation = wins - expectedWins;
  final winningSeason = wins >= 7;
  final greatSeason = wins >= 9 || overExpectation >= 3;
  final badSeason = wins <= 5 || overExpectation <= -2;

  int clampP(int v) => v.clamp(50, 100);

  if (greatSeason) {
    return [
      clampP(current + 8 + rng.nextInt(8)),   // clear better offer
      clampP(current + 3 + rng.nextInt(7)),   // slightly better
      clampP(current - 4 + rng.nextInt(9)),   // similar/fallback
    ];
  }

  if (winningSeason) {
    return [
      clampP(current + 3 + rng.nextInt(6)),   // one better
      clampP(current - 2 + rng.nextInt(7)),   // similar
      clampP(current - 8 + rng.nextInt(8)),   // slightly lower
    ];
  }

  if (badSeason) {
    return [
      clampP(current + rng.nextInt(5)),       // maybe one small upgrade
      clampP(current - 8 - rng.nextInt(8)),   // worse
      clampP(current - 12 - rng.nextInt(10)), // much worse
    ];
  }

  return [
    clampP(current + rng.nextInt(5)),         // similar/slightly better
    clampP(current - 4 + rng.nextInt(7)),     // similar
    clampP(current - 10 + rng.nextInt(8)),    // lower
  ];
}

CollegeTeam teamClosestToPrestige(List<CollegeTeam> teams, int target, Set<String> usedNames, CollegeTeam currentTeam) {
  final pool = teams
      .where((t) => t.name != currentTeam.name && !usedNames.contains(t.name))
      .toList();

  if (pool.isEmpty) return teams.firstWhere((t) => t.name != currentTeam.name, orElse: () => currentTeam);

  pool.sort((a, b) {
    final da = (prestige100(a.prestige) - target).abs();
    final db = (prestige100(b.prestige) - target).abs();
    if (da != db) return da.compareTo(db);
    return rng.nextInt(3) - 1;
  });

  return pool.first;
}

class JobOffer {
  final CollegeTeam team;
  final int years;

  const JobOffer({
    required this.team,
    required this.years,
  });
}




class CoachTransitionResult {
  final List<Player> playersFollowing;
  final List<Recruit> recruitsFollowing;
  final List<Recruit> recruitsStayed;
  final List<Recruit> recruitsReopened;

  const CoachTransitionResult({
    required this.playersFollowing,
    required this.recruitsFollowing,
    required this.recruitsStayed,
    required this.recruitsReopened,
  });
}

int prestigeExpectationWins(int prestige) {
  if (prestige >= 88) return 10;
  if (prestige >= 78) return 8;
  if (prestige >= 66) return 6;
  if (prestige >= 55) return 5;
  return 4;
}

int updatedPrestigeAfterSeason(int prestige, int wins, int losses, {bool madeCfp = false, bool wonConference = false, bool wonTitle = false}) {
  final expected = prestigeExpectationWins(prestige);
  int change = 0;
  if (wins >= expected + 4) change += 5;
  else if (wins >= expected + 2) change += 3;
  else if (wins >= expected) change += 1;
  else if (wins <= expected - 3) change -= 4;
  else if (wins < expected) change -= 2;
  if (wonConference) change += 2;
  if (madeCfp) change += 3;
  if (wonTitle) change += 5;
  if (losses >= 9) change -= 2;
  return (prestige + change).clamp(1, 100);
}

int coachRecruitingRating(CoachProfile coach) {
  try {
    final dyn = coach as dynamic;
    final v = dyn.recruiting;
    if (v is int) return v.clamp(25, 99);
    if (v is num) return v.round().clamp(25, 99);
  } catch (_) {}
  return 45;
}

int maxVisibleStarsForCoachAndSchool(CoachProfile coach, CollegeTeam team) {
  final cr = coachRecruitingRating(coach);
  final p = team.prestige;
  if (p >= 88 || cr >= 85) return 5;
  if (p >= 76 || cr >= 75) return 4;
  if (p >= 62 || cr >= 65) return 3;
  return 2;
}

int cappedFreshmanOverall(int overall) => overall.clamp(40, 94);


int awardScoreForPlayer(Player player) {
  final overall = awardOverall(player);
  final yearBonus = switch (player.year) {
    'SR' => 6,
    'JR' => 4,
    'SO' => 2,
    _ => 0,
  };

  final positionBonus = switch (player.position) {
    'QB' => 8,
    'HB' => 5,
    'WR' => 4,
    'DE' => 4,
    'LB' => 3,
    'DB' => 3,
    'TE' => 1,
    _ => 0,
  };

  final starBonus = player.stars * 2;
  final seedBonus = player.name.hashCode.abs() % 7;

  return overall * 3 + yearBonus + positionBonus + starBonus + seedBonus;
}

List<Player> realisticAllAmericanTeam(List<Player> players, {required Set<String> usedNames}) {
  final positionNeeds = <String, int>{
    'QB': 1,
    'HB': 1,
    'WR': 2,
    'TE': 1,
    'DE': 2,
    'LB': 2,
    'DB': 3,
  };

  final selected = <Player>[];

  for (final entry in positionNeeds.entries) {
    final candidates = players
        .where((p) => p.position == entry.key && !usedNames.contains(p.name))
        .toList()
      ..sort((a, b) => awardScoreForPlayer(b).compareTo(awardScoreForPlayer(a)));

    for (final player in candidates.take(entry.value)) {
      selected.add(player);
      usedNames.add(player.name);
    }
  }

  selected.sort((a, b) => awardScoreForPlayer(b).compareTo(awardScoreForPlayer(a)));
  return selected;
}

class DashboardScreen extends StatefulWidget {
  final CollegeTeam team;
  final CoachProfile coach;
  final String? careerId;
  final Map<String, dynamic>? savedCareer;
  final List<TrophyEntry> initialTrophies;
  final List<NationalTitleHistoryEntry> initialNationalHistory;

  const DashboardScreen({
    super.key,
    required this.team,
    required this.coach,
    this.careerId,
    this.savedCareer,
    this.initialTrophies = const [],
    this.initialNationalHistory = const [],
  });

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> with WidgetsBindingObserver {
  final List<String> weeklyNewsHeadlines = [];
  final List<TrophyEntry> trophyRoom = [];
  final List<NationalTitleHistoryEntry> nationalHistory = [];
  bool nationalHistoryRecordedThisSeason = false;

  late CollegeTeam selectedTeam;
  late List<Player> roster;
  late List<Recruit> recruits;
  late List<CollegeTeam> schedule;
  late CollegeTeam nextOpponent;
  CollegeTeam? rivalryTeam;
  CoachTransitionResult? transitionResult;
  List<CollegeTeam> nextCustomNonConference = [];
  late Map<String, TeamSeasonRecord> teamRecords;
  // Program prestige (stars) for the team the coach currently leads. Starts
  // at the team's base prestige but evolves offseason to offseason via
  // updatedPrestigeAfterSeason — wins above expectation, conference titles,
  // CFP runs, and national titles raise it; bad seasons lower it. widget.team
  // itself never changes across seasons while staying at the same job, so
  // this is the field everything season-quality-related should read instead
  // of widget.team.prestige.
  late int programPrestige;

  int selectedTab = 0;
  int recruitingPoints = 100;
  int wins = 0;
  int losses = 0;
  int confWins = 0;
  int confLosses = 0;
  int gamesPlayed = 0;
  int season = 1;
  int commits = 0;
  int recruitingWindow = 1;
  String seasonPhase = 'regular';
  int postseasonRound = 0;
  bool madeCfpThisSeason = false;
  String assignedBowlName = '';
  int mediaReputation = 50;
  int playerMorale = 50;
  int boosterApproval = 50;
  int recruitingBuzz = 50;
  int fanHappiness = 50;
  final List<String> worldNewsHeadlines = [];
  String lastPressTone = '';
  String lastPressQuote = '';
  late String activeCareerId;

  int? starFilter;
  String? positionFilter;
  String? stateFilter;
  String recruitSort = 'Rank';
  int recruitBoardTab = 0;
  String _newCareerId() {
    return careerKeyFromCoachName(widget.coach.name);
  }

  Map<String, dynamic> _careerSaveJson() {
    return {
      'id': activeCareerId,
      'careerKey': activeCareerId,
      'coach': coachToJson(widget.coach),
      'team': selectedTeam.name,
      'season': season,
      'wins': wins,
      'losses': losses,
      'confWins': confWins,
      'confLosses': confLosses,
      'gamesPlayed': gamesPlayed,
      'recruitingPoints': recruitingPoints,
      'recruitingWindow': recruitingWindow,
      'commits': commits,
      'seasonPhase': seasonPhase,
      'postseasonRound': postseasonRound,
      'madeCfpThisSeason': madeCfpThisSeason,
      'programPrestige': programPrestige,
      'assignedBowlName': assignedBowlName,
      'mediaReputation': mediaReputation,
      'playerMorale': playerMorale,
      'boosterApproval': boosterApproval,
      'recruitingBuzz': recruitingBuzz,
      'fanHappiness': fanHappiness,
      'worldNewsHeadlines': worldNewsHeadlines,
      'lastPressTone': lastPressTone,
      'lastPressQuote': lastPressQuote,
      'roster': roster.map(playerToJson).toList(),
      'trophies': trophyRoom.map(trophyToJson).toList(),
      'history': nationalHistory.map(historyToJson).toList(),
      'savedAt': DateTime.now().toIso8601String(),
    };
  }

  void _autoSaveCareer() {
    upsertCareerSave(_careerSaveJson());
  }

  void _loadSavedCareer(Map<String, dynamic> save) {
    selectedTeam = teamByName(save['team'] ?? selectedTeam.name);
    season = save['season'] ?? season;
    wins = save['wins'] ?? 0;
    losses = save['losses'] ?? 0;
    confWins = save['confWins'] ?? 0;
    confLosses = save['confLosses'] ?? 0;
    gamesPlayed = save['gamesPlayed'] ?? 0;
    recruitingPoints = save['recruitingPoints'] ?? 100;
    recruitingWindow = save['recruitingWindow'] ?? 1;
    commits = save['commits'] ?? 0;
    seasonPhase = save['seasonPhase'] ?? 'regular';
    postseasonRound = save['postseasonRound'] ?? 0;
    madeCfpThisSeason = save['madeCfpThisSeason'] ?? false;
    programPrestige =
        (save['programPrestige'] as num?)?.toInt() ?? widget.team.prestige;
    assignedBowlName = '${save['assignedBowlName'] ?? ''}';
    mediaReputation =
        (save['mediaReputation'] as num?)?.toInt() ?? 50;
    playerMorale =
        (save['playerMorale'] as num?)?.toInt() ?? 50;
    boosterApproval =
        (save['boosterApproval'] as num?)?.toInt() ?? 50;
    recruitingBuzz =
        (save['recruitingBuzz'] as num?)?.toInt() ?? 50;
    fanHappiness =
        (save['fanHappiness'] as num?)?.toInt() ?? 50;
    final savedWorldNews = save['worldNewsHeadlines'];
    if (savedWorldNews is List) {
      worldNewsHeadlines
        ..clear()
        ..addAll(savedWorldNews.map((item) => '$item'));
    }
    lastPressTone = '${save['lastPressTone'] ?? ''}';
    lastPressQuote = '${save['lastPressQuote'] ?? ''}';

    final savedRoster = save['roster'];
    if (savedRoster is List) {
      roster = savedRoster
          .whereType<Map>()
          .map((e) => playerFromJson(Map<String, dynamic>.from(e)))
          .toList();
    }

    final savedTrophies = save['trophies'];
    if (savedTrophies is List) {
      trophyRoom
        ..clear()
        ..addAll(savedTrophies.whereType<Map>().map((e) => trophyFromJson(Map<String, dynamic>.from(e))));
    }

    final savedHistory = save['history'];
    if (savedHistory is List) {
      nationalHistory
        ..clear()
        ..addAll(savedHistory.whereType<Map>().map((e) => historyFromJson(Map<String, dynamic>.from(e))));
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    selectedTeam = widget.team;
    activeCareerId = widget.savedCareer != null ? careerKeyFromSave(widget.savedCareer!) : (widget.careerId ?? _newCareerId());
    trophyRoom.addAll(widget.initialTrophies);
    nationalHistory.addAll(widget.initialNationalHistory);
    programPrestige = widget.team.prestige;
    roster = generateRoster(programPrestige);
    recruits = generateRecruits(programPrestige);
    teamRecords = {for (final team in g5Teams) team.name: TeamSeasonRecord()};
    schedule = _generateSchedule();

    if (widget.savedCareer != null) {
      _loadSavedCareer(widget.savedCareer!);
      schedule = _generateSchedule();
    }

    nextOpponent = gamesPlayed < schedule.length ? schedule[gamesPlayed] : schedule.last;
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoSaveCareer());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // paused: user backgrounded the app. detached: the engine is being torn
    // down. Both are points after which the process may be killed with no
    // further callback, so the career must be persisted right away rather
    // than waiting for the next in-game autosave trigger.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.inactive) {
      _autoSaveCareer();
    }
    super.didChangeAppLifecycleState(state);
  }

  List<CollegeTeam> _generateSchedule({List<CollegeTeam>? customNonConference, CollegeTeam? rivalry}) {
    final isIndependent = widget.team.conference == 'Independent';

    final sameConf = g5Teams
        .where((t) => t.conference == widget.team.conference && t.name != widget.team.name)
        .toList();
    final nonConf = g5Teams
        .where((t) => t.name != widget.team.name && (isIndependent || t.conference != widget.team.conference))
        .toList();

    sameConf.shuffle(rng);
    nonConf.shuffle(rng);

    final ncGames = <CollegeTeam>[];
    final confGames = <CollegeTeam>[];

    if (rivalry != null && rivalry.name != widget.team.name) {
      if (!isIndependent && rivalry.conference == widget.team.conference) {
        confGames.add(rivalry);
      } else {
        ncGames.add(rivalry);
      }
    }

    if (customNonConference != null) {
      for (final team in customNonConference) {
        if (team.name != widget.team.name &&
            (isIndependent || team.conference != widget.team.conference) &&
            !ncGames.any((t) => t.name == team.name)) {
          ncGames.add(team);
        }
      }
    }

    if (isIndependent) {
      // Independents have no conference-mates, so the whole 12-game slate
      // is drawn at random from schools nationwide instead of the usual
      // 9 conference + 3 non-conference split.
      while (ncGames.length < 12 && nonConf.isNotEmpty) {
        final candidate = nonConf[rng.nextInt(nonConf.length)];
        if (!ncGames.any((t) => t.name == candidate.name)) {
          ncGames.add(candidate);
        }
      }
      return ncGames.take(12).toList();
    }

    while (ncGames.length < 3 && nonConf.isNotEmpty) {
      final candidate = nonConf[rng.nextInt(nonConf.length)];
      if (!ncGames.any((t) => t.name == candidate.name)) {
        ncGames.add(candidate);
      }
    }

    for (final team in sameConf) {
      if (confGames.length >= 9) break;
      if (!confGames.any((t) => t.name == team.name)) {
        confGames.add(team);
      }
    }

    while (confGames.length < 9) {
      if (sameConf.isNotEmpty) {
        final candidate = sameConf[confGames.length % sameConf.length];
        confGames.add(candidate);
      } else if (nonConf.isNotEmpty) {
        confGames.add(nonConf[rng.nextInt(nonConf.length)]);
      } else {
        break;
      }
    }

    return [...ncGames.take(3), ...confGames.take(9)];
  }

  double get teamOvr {
    if (roster.isEmpty) {
      return rosterBaseForPrestige(programPrestige).clamp(48, 96).toDouble();
    }
    // The team's overall is the average of the actual starting lineup — no
    // clamping against the program's prestige tier. Prestige (stars) is a
    // separate, slow-moving reputation metric that only shifts a little
    // each offseason via updatedPrestigeAfterSeason (winning culture); team
    // overall should track the real starters immediately as they develop,
    // graduate, or get replaced, even if that temporarily runs ahead of or
    // behind what the program's reputation currently says it "should" be.
    final lineup = starters.isEmpty ? roster : starters;
    final avg = lineup.map((p) => p.overall).reduce((a, b) => a + b) / lineup.length;
    return avg.clamp(40, 99);
  }

  int get opponentOvr {
    final min = switch (prestigeTier(nextOpponent.prestige)) {
      1 => 50,
      2 => 58,
      3 => 68,
      4 => 78,
      _ => 88,
    };
    final max = switch (prestigeTier(nextOpponent.prestige)) {
      1 => 60,
      2 => 68,
      3 => 78,
      4 => 88,
      _ => 99,
    };
    return ((min + max) / 2).round();
  }

  List<CollegeTeam> _rankedTeams() {
    final teams = g5Teams.toList();

    teams.sort((a, b) {
      final ar = teamRecords[a.name] ?? TeamSeasonRecord();
      final br = teamRecords[b.name] ?? TeamSeasonRecord();

      final bPct = br.winPct.compareTo(ar.winPct);
      if (bPct != 0) return bPct;

      final bWins = br.wins.compareTo(ar.wins);
      if (bWins != 0) return bWins;

      final bPrestige = b.prestige.compareTo(a.prestige);
      if (bPrestige != 0) return bPrestige;

      return a.name.compareTo(b.name);
    });

    return teams;
  }

  int get displayRank {
    final index = _rankedTeams().indexWhere((team) => team.name == widget.team.name);
    return index < 0 ? 260 : index + 1;
  }

  List<CollegeTeam> _conferenceStandings() {
    final teams = g5Teams
        .where((team) => team.conference == widget.team.conference)
        .toList();

    teams.sort((a, b) {
      final ar = teamRecords[a.name] ?? TeamSeasonRecord();
      final br = teamRecords[b.name] ?? TeamSeasonRecord();

      final aPlayed = max(1, ar.confWins + ar.confLosses);
      final bPlayed = max(1, br.confWins + br.confLosses);
      final aConfPct = ar.confWins / aPlayed;
      final bConfPct = br.confWins / bPlayed;

      final pctCompare = bConfPct.compareTo(aConfPct);
      if (pctCompare != 0) return pctCompare;

      final confWinsCompare = br.confWins.compareTo(ar.confWins);
      if (confWinsCompare != 0) return confWinsCompare;

      final overallWinsCompare = br.wins.compareTo(ar.wins);
      if (overallWinsCompare != 0) return overallWinsCompare;

      final prestigeCompare = prestige100(b.prestige).compareTo(prestige100(a.prestige));
      if (prestigeCompare != 0) return prestigeCompare;

      return a.name.compareTo(b.name);
    });

    return teams;
  }

  List<CollegeTeam> get conferenceTopTwo {
    return _conferenceStandings().take(2).toList();
  }

  bool get userMadeConferenceChampionship {
    if (gamesPlayed < 12) return false;
    return conferenceTopTwo.any((team) => team.name == widget.team.name);
  }

  CollegeTeam _conferenceTitleOpponent() {
    final opponent = conferenceTopTwo
        .where((team) => team.name != widget.team.name)
        .toList();
    if (opponent.isNotEmpty) return opponent.first;
    return _bestConferenceOpponent();
  }

  void _beginConferenceChampionship({bool openGame = false, bool simGame = false}) {
    setState(() {
      seasonPhase = 'confChamp';
      postseasonRound = 1;
      nextOpponent = _conferenceTitleOpponent();
    });

    if (openGame) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _openGameSim();
      });
    }

    if (simGame) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _simNextGame();
      });
    }
  }

  String get recordText => '$wins-$losses';
  String get confText => '$confWins-$confLosses';

  String get jobSecurity {
    if (losses >= 8) return 'HOT SEAT';
    if (losses >= 5) return 'SHAKY';
    return 'SECURE';
  }

  Color get jobSecurityColor {
    if (jobSecurity == 'HOT SEAT') return kRed;
    if (jobSecurity == 'SHAKY') return kGold;
    return kGreen;
  }

  bool get conferenceChampEligible {
    if (gamesPlayed < 12) return false;
    return _conferenceRankForTeam(widget.team) <= 2;
  }
  bool get cfpEligible => gamesPlayed >= 12 && _userSelectedForCfp;
  bool get bowlEligible => gamesPlayed >= 12 && wins >= 6 && !cfpEligible;

  String get postseasonStatus {
    if (seasonPhase == 'regular') {
      if (gamesPlayed < 12) return 'REGULAR SEASON';
      if (conferenceChampEligible) return 'CONFERENCE CHAMPIONSHIP';
      if (cfpEligible) return 'KP SELECTION';
      if (bowlEligible) return 'BOWL SELECTION';
      return 'SEASON COMPLETE';
    }
    if (seasonPhase == 'confChamp') return 'CONFERENCE CHAMPIONSHIP';
    if (seasonPhase == 'selectionShow') return 'KP SELECTION SHOW';
    if (seasonPhase == 'selectionShow') return 'KP SELECTION SHOW';
    if (seasonPhase == 'cfp') return _cfpGameNameForRound(postseasonRound);
    if (seasonPhase == 'bowl') return _assignedBowlName.toUpperCase();
    return 'OFFSEASON';
  }

  List<Player> _playersAt(String position) {
    return roster.where((p) => p.position == position).toList()
      ..sort((a, b) => awardOverall(b).compareTo(awardOverall(a)));
  }

  List<Player> get starters {
    final s = <Player>[];
    void add(String pos, int count) => s.addAll(_playersAt(pos).take(count));
    add('QB', 1);
    add('HB', 1);
    add('WR', 2);
    add('TE', 1);
    add('DE', 1);
    add('LB', 1);
    add('DB', 2);
    return s;
  }

  List<Player> get bench {
    final starterNames = starters.map((p) => p.name).toSet();
    return roster.where((p) => !starterNames.contains(p.name)).toList()
      ..sort((a, b) {
        final pos = a.position.compareTo(b.position);
        if (pos != 0) return pos;
        return awardOverall(b).compareTo(awardOverall(a));
      });
  }


  int _rankForTeam(CollegeTeam team) {
    final ranked = _rankedTeams();
    final index = ranked.indexWhere((t) => t.name == team.name);
    return index < 0 ? 999 : index + 1;
  }

  String _rankedDisplayNameForTeam(CollegeTeam team) {
    return rankedDisplayName(team, _rankForTeam(team));
  }


  CollegeTeam _projectedConferenceChampion(String conference) {
    final conferenceTeams = g5Teams
        .where((team) => team.conference == conference)
        .toList();

    if (conferenceTeams.isEmpty) return widget.team;

    final userWonConference = widget.team.conference == conference &&
        trophyRoom.any(
          (trophy) =>
              trophy.year == season &&
              trophy.type == 'Conference Championship',
        );

    if (userWonConference) return widget.team;

    conferenceTeams.sort((a, b) {
      final aRecord = teamRecords[a.name] ?? TeamSeasonRecord();
      final bRecord = teamRecords[b.name] ?? TeamSeasonRecord();

      final conferenceWinCompare =
          bRecord.confWins.compareTo(aRecord.confWins);
      if (conferenceWinCompare != 0) return conferenceWinCompare;

      final conferenceLossCompare =
          aRecord.confLosses.compareTo(bRecord.confLosses);
      if (conferenceLossCompare != 0) return conferenceLossCompare;

      final overallWinCompare = bRecord.wins.compareTo(aRecord.wins);
      if (overallWinCompare != 0) return overallWinCompare;

      return _rankForTeam(a).compareTo(_rankForTeam(b));
    });

    return conferenceTeams.first;
  }

  List<CollegeTeam> _powerFourConferenceChampions() {
    const powerFour = ['Southern Crown Conference', 'Heartland Conference', 'Atlantic Coalition', 'Frontier Conference'];

    return powerFour
        .map(_projectedConferenceChampion)
        .fold<List<CollegeTeam>>(<CollegeTeam>[], (champions, team) {
          if (!champions.any((existing) => existing.name == team.name)) {
            champions.add(team);
          }
          return champions;
        });
  }

  List<CollegeTeam> _cfpSeeds() {
    _normalizeConferenceRecords();

    final nationalRanking = _rankedTeams();
    final selected = <CollegeTeam>[];

    // Every Power 4 conference champion receives a guaranteed bid.
    for (final champion in _powerFourConferenceChampions()) {
      if (!selected.any((team) => team.name == champion.name)) {
        selected.add(champion);
      }
    }

    // Fill the remaining positions with the best available teams nationally.
    for (final team in nationalRanking) {
      if (selected.length >= 12) break;

      if (!selected.any((selectedTeam) => selectedTeam.name == team.name)) {
        selected.add(team);
      }
    }

    // Seed all selected teams according to the national committee ranking.
    selected.sort(
      (a, b) => _rankForTeam(a).compareTo(_rankForTeam(b)),
    );

    return selected.take(12).toList();
  }

  bool _userHasPowerFourAutoBid() {
    return isPowerFourConference(widget.team.conference) &&
        trophyRoom.any(
          (trophy) =>
              trophy.year == season &&
              trophy.type == 'Conference Championship',
        );
  }

  bool get _userSelectedForCfp {
    return _cfpSeeds().any((team) => team.name == widget.team.name);
  }

  int get _userCfpSeed {
    final seeds = _cfpSeeds();
    final index = seeds.indexWhere((team) => team.name == widget.team.name);
    return index < 0 ? 999 : index + 1;
  }

  String _cfpGameNameForRound(int round) {
    final seed = _userCfpSeed;

    if (round <= 1) {
      const firstRoundNames = [
        'Heritage Bowl',
        'Coastline Bowl',
        'Mission Bowl',
        'Grove Bowl',
      ];
      return '${firstRoundNames[(max(seed, 5) - 5).clamp(0, 3)]} · KP FIRST ROUND';
    }

    if (round == 2) {
      const quarterfinalNames = [
        'Arroyo Bowl',
        'Cane Bowl',
        'Saguaro Bowl',
        'Orchard Bowl',
      ];
      return '${quarterfinalNames[(max(seed, 1) - 1) % quarterfinalNames.length]} · KP QUARTERFINAL';
    }

    if (round == 3) {
      return seed.isEven
          ? 'COTTON BOWL · KP SEMIFINAL'
          : 'ORANGE BOWL · KP SEMIFINAL';
    }

    return 'KP NATIONAL CHAMPIONSHIP';
  }

  String _bowlNameForRecord({
    required int teamWins,
    required int teamLosses,
    required CollegeTeam team,
  }) {
    final recordKey =
        teamWins * 31 + teamLosses * 17 + team.name.hashCode.abs();

    final List<String> choices;

    if (teamWins >= 11) {
      choices = const [
        'Grove Bowl',
        'Mission Bowl',
        'Bayfront Bowl',
        'Coastline Bowl',
      ];
    } else if (teamWins == 10) {
      choices = const [
        'Harmony Bowl',
        'Rio Bowl',
        'Neon Bowl',
        'Riverside Bowl',
      ];
    } else if (teamWins == 9) {
      choices = const [
        'Heritage Bowl',
        'Solstice Bowl',
        'Empire Bowl',
        'Queen City Bowl',
      ];
    } else if (teamWins == 8) {
      choices = const [
        'Patriots Bowl',
        'Service Bowl',
        'Ironworks Bowl',
        'Desert Sky Bowl',
      ];
    } else if (teamWins == 7) {
      choices = const [
        'Frontline Bowl',
        'Metroplex Bowl',
        'Mesa Bowl',
        'Buccaneer Bowl',
      ];
    } else {
      choices = const [
        'Beacon Bowl',
        'Boardwalk Bowl',
        'Bayou Bowl',
        'Magnolia Bowl',
      ];
    }

    return choices[recordKey % choices.length];
  }

  String get _assignedBowlName {
    if (assignedBowlName.trim().isNotEmpty) {
      return assignedBowlName;
    }

    return _bowlNameForRecord(
      teamWins: wins,
      teamLosses: losses,
      team: widget.team,
    );
  }


  void _normalizeConferenceRecords() {
    for (final team in g5Teams) {
      final rec = teamRecords[team.name] ?? TeamSeasonRecord();

      final confPlayed = rec.confWins + rec.confLosses;
      if (confPlayed < 9) {
        final remaining = 9 - confPlayed;
        final strength = prestige100(team.prestige);
        for (int i = 0; i < remaining; i++) {
          final winChance = (0.28 + (strength / 180)).clamp(.25, .82);
          if (rng.nextDouble() < winChance) {
            rec.confWins++;
          } else {
            rec.confLosses++;
          }
        }
      } else if (confPlayed > 9) {
        while (rec.confWins + rec.confLosses > 9 && rec.confLosses > 0) {
          rec.confLosses--;
          if (rec.losses > 0) rec.losses--;
        }
        while (rec.confWins + rec.confLosses > 9 && rec.confWins > 0) {
          rec.confWins--;
          if (rec.wins > 0) rec.wins--;
        }
      }

      final nonConfWins = max(0, rec.wins - rec.confWins);
      final nonConfLosses = max(0, rec.losses - rec.confLosses);
      final cappedNonConfWins = min(nonConfWins, 3);
      final cappedNonConfLosses = min(nonConfLosses, 3 - cappedNonConfWins);

      rec.wins = cappedNonConfWins + rec.confWins;
      rec.losses = cappedNonConfLosses + rec.confLosses;

      final totalPlayed = rec.wins + rec.losses;
      if (totalPlayed < 12) {
        final remaining = 12 - totalPlayed;
        for (int i = 0; i < remaining; i++) {
          if (rng.nextDouble() < .50) {
            rec.wins++;
          } else {
            rec.losses++;
          }
        }
      }

      teamRecords[team.name] = rec;
    }
  }

  int _conferenceRankForTeam(CollegeTeam team) {
    _normalizeConferenceRecords();
    final standings = _conferenceStandings();
    final index = standings.indexWhere((t) => t.name == team.name);
    return index < 0 ? 999 : index + 1;
  }

  CollegeTeam _bestConferenceOpponent() {
    final teams = g5Teams
        .where((t) => t.conference == widget.team.conference && t.name != widget.team.name)
        .toList();
    teams.sort((a, b) => b.prestige.compareTo(a.prestige));
    return teams.isEmpty ? schedule.first : teams.first;
  }

  CollegeTeam _playoffOpponent() {
    final seeds = _cfpSeeds();
    final userIndex =
        seeds.indexWhere((team) => team.name == widget.team.name);

    if (seeds.isEmpty || userIndex < 0) {
      final fallback = _rankedTeams()
          .where((team) => team.name != widget.team.name)
          .toList();
      return fallback.isEmpty ? schedule.first : fallback.first;
    }

    final seed = userIndex + 1;
    int opponentSeed;

    if (postseasonRound <= 1) {
      opponentSeed = switch (seed) {
        5 => 12,
        6 => 11,
        7 => 10,
        8 => 9,
        9 => 8,
        10 => 7,
        11 => 6,
        12 => 5,
        _ => min(12, max(5, 13 - seed)),
      };
    } else if (postseasonRound == 2) {
      opponentSeed = switch (seed) {
        1 => 8,
        2 => 7,
        3 => 6,
        4 => 5,
        _ => ((seed + 3).clamp(1, 12)),
      };
    } else if (postseasonRound == 3) {
      opponentSeed = seed <= 6 ? 4 : 2;
    } else {
      opponentSeed = seed == 1 ? 2 : 1;
    }

    final opponentIndex = (opponentSeed - 1).clamp(0, seeds.length - 1);
    final selectedOpponent = seeds[opponentIndex];

    if (selectedOpponent.name != widget.team.name) {
      return selectedOpponent;
    }

    return seeds.firstWhere(
      (team) => team.name != widget.team.name,
      orElse: () => schedule.first,
    );
  }

  int _projectedOvrForTeam(CollegeTeam team) {
    final tier = prestigeTier(team.prestige);
    final min = switch (tier) {
      1 => 50,
      2 => 58,
      3 => 68,
      4 => 78,
      _ => 88,
    };
    final max = switch (tier) {
      1 => 60,
      2 => 68,
      3 => 78,
      4 => 88,
      _ => 96,
    };
    return ((min + max) / 2).round();
  }

  CollegeTeam _bowlOpponent() {
    final ranked = _rankedTeams();
    final myWins = wins;
    final myOvr = teamOvr.round();

    int targetWins;
    int maxOvrGap;

    if (myWins >= 10) {
      targetWins = 9;
      maxOvrGap = 8;
    } else if (myWins == 9) {
      targetWins = 8;
      maxOvrGap = 7;
    } else if (myWins == 8) {
      targetWins = 7;
      maxOvrGap = 6;
    } else if (myWins == 7) {
      targetWins = 7;
      maxOvrGap = 5;
    } else {
      targetWins = 6;
      maxOvrGap = 5;
    }

    final candidates = ranked
        .where((t) => t.name != widget.team.name)
        .where((t) => t.conference != widget.team.conference)
        .where((t) {
          final rec = teamRecords[t.name] ?? TeamSeasonRecord();
          final oppWins = rec.gamesPlayed == 0 ? targetWins : rec.wins;
          final oppLosses = rec.gamesPlayed == 0 ? max(12 - oppWins, 0) : rec.losses;
          final oppOvr = _projectedOvrForTeam(t);

          final recordFits = (oppWins - targetWins).abs() <= 1 && oppWins >= 6;
          final overallFits = (oppOvr - myOvr).abs() <= maxOvrGap;

          // Avoid giving 6-6/7-5 teams elite opponents.
          final notTooElite = myWins >= 9 || (oppWins <= 8 && oppOvr <= myOvr + maxOvrGap);

          // Avoid giving 10+ win teams a weak 6-6 team unless there are no options.
          final notTooWeak = myWins < 9 || oppWins >= 8;

          return recordFits && overallFits && notTooElite && notTooWeak && oppLosses <= 7;
        })
        .toList();

    if (candidates.isNotEmpty) {
      candidates.sort((a, b) {
        final ar = teamRecords[a.name] ?? TeamSeasonRecord();
        final br = teamRecords[b.name] ?? TeamSeasonRecord();

        final aWins = ar.gamesPlayed == 0 ? targetWins : ar.wins;
        final bWins = br.gamesPlayed == 0 ? targetWins : br.wins;
        final aOvr = _projectedOvrForTeam(a);
        final bOvr = _projectedOvrForTeam(b);

        final aScore = (aWins - targetWins).abs() * 10 + (aOvr - myOvr).abs();
        final bScore = (bWins - targetWins).abs() * 10 + (bOvr - myOvr).abs();
        return aScore.compareTo(bScore);
      });

      final top = candidates.take(min(4, candidates.length)).toList();
      return top[rng.nextInt(top.length)];
    }

    final fallback = ranked
        .where((t) => t.name != widget.team.name)
        .where((t) => t.conference != widget.team.conference)
        .toList()
      ..sort((a, b) {
        final aOvr = _projectedOvrForTeam(a);
        final bOvr = _projectedOvrForTeam(b);
        return (aOvr - myOvr).abs().compareTo((bOvr - myOvr).abs());
      });

    return fallback.isEmpty ? schedule.first : fallback.first;
  }

  void _advancePostseason() {
    _normalizeConferenceRecords();

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SelectionScreen(
          team: widget.team,
          record: recordText,
          wins: wins,
          losses: losses,
          confWins: confWins,
          confLosses: confLosses,
          rank: displayRank,
          teamOvr: teamOvr.round(),
          teamRecords: teamRecords,
          conferenceChampEligible: conferenceChampEligible,
          cfpEligible: cfpEligible,
          bowlEligible: bowlEligible,
          existingAssignedBowlName: assignedBowlName,
          onContinue: (SelectionResult result) {
            setState(() {
              if (result.bowlName != null &&
                  result.bowlName!.trim().isNotEmpty) {
                assignedBowlName = result.bowlName!;
              }
              if (result.phase == 'confChamp') {
                seasonPhase = 'confChamp';
                postseasonRound = 1;
                nextOpponent = _bestConferenceOpponent();
              } else if (result.phase == 'cfp') {
                seasonPhase = 'cfp';
                postseasonRound = 1;
                madeCfpThisSeason = true;
                nextOpponent = _playoffOpponent();
              } else if (result.phase == 'bowl') {
                seasonPhase = 'bowl';
                postseasonRound = 1;
                nextOpponent = _bowlOpponent();
              } else {
                seasonPhase = 'offseason';
              }
            });
            _autoSaveCareer();
          },
        ),
      ),
    );
  }

  List<Recruit> get committedRecruits {
    return recruits.where((r) => r.committedSchool == widget.team.name).toList();
  }

  void _openOffseason() {
    _recordSimulatedNationalTitleIfNeeded();

    // A season's results move the program's prestige (and star rating)
    // before the offseason begins, so contract talks, job offers, the
    // retention budget, and the incoming recruiting class all react to it
    // immediately rather than a season late.
    final seasonEndPrestige = updatedPrestigeAfterSeason(
      programPrestige,
      wins,
      losses,
      madeCfp: madeCfpThisSeason,
      wonConference: _wonConferenceChampionshipThisSeason,
      wonTitle: _wonNationalChampionshipThisSeason,
    );

    final teamForOffseason = CollegeTeam(
      name: widget.team.name,
      conference: widget.team.conference,
      prestige: seasonEndPrestige,
      primary: widget.team.primary,
      secondary: widget.team.secondary,
      emoji: widget.team.emoji,
      mascot: widget.team.mascot,
    );

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => OffseasonScreen(
          team: teamForOffseason,
          coach: widget.coach,
          season: season,
          wins: wins,
          losses: losses,
          confWins: confWins,
          confLosses: confLosses,
          roster: roster,
          incomingRecruits: committedRecruits,
          onFinish: (result) {
            if (result.team.name != widget.team.name) {
              Navigator.of(context).pushReplacement(
                MaterialPageRoute(
                  builder: (_) => DashboardScreen(
                    team: result.team,
                    coach: widget.coach,
                    careerId: activeCareerId,
                    initialTrophies: trophyRoom,
                    initialNationalHistory: nationalHistory,
                  ),
                ),
              );
              return;
            }

            setState(() {
              programPrestige = result.team.prestige;
              roster = result.roster;
              rivalryTeam = result.rivalry;
              nextCustomNonConference = result.customNonConference;
            });
            _autoSaveCareer();
            _advanceSeason();
          },
        ),
      ),
    );
  }

  void _advanceSeason() {
    setState(() {
      // Note: roster is intentionally left untouched here. OffseasonScreen
      // already advanced every returning player's class year, applied
      // graduations/draft declarations/transfers, added the signed
      // recruiting class, and filled any remaining walk-on spots — its
      // result was assigned to `roster` in _openOffseason's onFinish just
      // before this method runs. Re-deriving it here would double-advance
      // class years and duplicate the incoming recruiting class.
      season++;
      nationalHistoryRecordedThisSeason = false;
      wins = 0;
      losses = 0;
      confWins = 0;
      confLosses = 0;
      gamesPlayed = 0;
      recruitingPoints = 100;
      recruitingWindow = 1;
      commits = 0;
      seasonPhase = 'regular';
      postseasonRound = 0;
      madeCfpThisSeason = false;
      assignedBowlName = '';
      teamRecords = {for (final team in g5Teams) team.name: TeamSeasonRecord()};
      schedule = _generateSchedule(
        customNonConference: nextCustomNonConference,
        rivalry: rivalryTeam,
      );
      nextOpponent = schedule.first;
      recruits = generateRecruits(programPrestige);
    });
  }

  void _updateUserAndOpponentRecord({
    required bool won,
    required bool wasConferenceGame,
    required CollegeTeam opponent,
  }) {
    final userRecord = teamRecords[widget.team.name]!;
    final opponentRecord = teamRecords[opponent.name] ?? TeamSeasonRecord();

    if (won) {
      userRecord.wins++;
      opponentRecord.losses++;
      if (wasConferenceGame) {
        userRecord.confWins++;
        opponentRecord.confLosses++;
      }
    } else {
      userRecord.losses++;
      opponentRecord.wins++;
      if (wasConferenceGame) {
        userRecord.confLosses++;
        opponentRecord.confWins++;
      }
    }

    teamRecords[opponent.name] = opponentRecord;
  }

  void _simulateNationalWeek(CollegeTeam userOpponent) {
    final pool = g5Teams
        .where((team) => team.name != widget.team.name && team.name != userOpponent.name)
        .toList()
      ..shuffle(rng);

    for (int i = 0; i + 1 < pool.length; i += 2) {
      final a = pool[i];
      final b = pool[i + 1];
      final aRecord = teamRecords[a.name] ?? TeamSeasonRecord();
      final bRecord = teamRecords[b.name] ?? TeamSeasonRecord();

      final aChance = (0.50 + ((a.prestige - b.prestige) * 0.08)).clamp(0.20, 0.80);
      final aWon = rng.nextDouble() < aChance;
      final conferenceGame = a.conference == b.conference && rng.nextDouble() < .65;

      if (aWon) {
        aRecord.wins++;
        bRecord.losses++;
        if (conferenceGame) {
          aRecord.confWins++;
          bRecord.confLosses++;
        }
      } else {
        aRecord.losses++;
        bRecord.wins++;
        if (conferenceGame) {
          aRecord.confLosses++;
          bRecord.confWins++;
        }
      }

      teamRecords[a.name] = aRecord;
      teamRecords[b.name] = bRecord;
    }
  }


  Player _playerOfGameForResult(bool won) {
    final pool = starters.isNotEmpty ? starters : roster;
    if (pool.isEmpty) {
      return Player(name: 'Unknown Player', position: 'QB', overall: 60, potential: 70, year: 'FR', stars: 1);
    }

    final offense = pool.where((p) => ['QB', 'HB', 'RB', 'WR', 'TE'].contains(p.position)).toList();
    final defense = pool.where((p) => ['DE', 'DL', 'LB', 'DB', 'CB', 'S'].contains(p.position)).toList();
    final candidates = (won || rng.nextInt(100) < 70)
        ? (offense.isNotEmpty ? offense : pool)
        : (defense.isNotEmpty ? defense : pool);

    candidates.sort((a, b) => b.overall.compareTo(a.overall));
    final top = candidates.take(min(4, candidates.length)).toList();
    return top[rng.nextInt(top.length)];
  }

  String _statLineForPlayer(Player p) {
    switch (p.position) {
      case 'QB':
        return '${210 + rng.nextInt(190)} pass yds, ${2 + rng.nextInt(4)} TD';
      case 'HB':
      case 'RB':
        return '${80 + rng.nextInt(120)} rush yds, ${1 + rng.nextInt(3)} TD';
      case 'WR':
      case 'TE':
        return '${65 + rng.nextInt(125)} rec yds, ${1 + rng.nextInt(3)} TD';
      case 'DE':
      case 'DL':
      case 'LB':
        return '${6 + rng.nextInt(8)} tackles, ${1 + rng.nextInt(3)} sacks';
      default:
        return '${5 + rng.nextInt(7)} tackles, ${rng.nextInt(2) + 1} impact plays';
    }
  }
  (int, int) _headlineScoreForResult(bool won) {
    final baseUser = teamOvr.round().clamp(45, 99).toInt();
    final baseOpp = opponentOvr.clamp(45, 99).toInt();
    final strengthGap = ((baseUser - baseOpp) / 4).round();

    var userScore = 17 + rng.nextInt(24) + max(0, strengthGap);
    var oppScore = 17 + rng.nextInt(24) + max(0, -strengthGap);

    if (won && userScore <= oppScore) {
      userScore = oppScore + 1 + rng.nextInt(10);
    }

    if (!won && oppScore <= userScore) {
      oppScore = userScore + 1 + rng.nextInt(10);
    }

    final safeUserScore = userScore.clamp(3, 63).toInt();
    final safeOppScore = oppScore.clamp(3, 63).toInt();

    return (safeUserScore, safeOppScore);
  }


  void _addGameHeadlines({
    required bool won,
    required CollegeTeam opponent,
  }) {
    final (userScore, opponentScore) = _headlineScoreForResult(won);
    final player = _playerOfGameForResult(won);
    final playerLine = _statLineForPlayer(player);

    final weekLabel = seasonPhase == 'regular' ? 'Week ${gamesPlayed + 1}' : postseasonStatus;
    final resultHeadline = won
        ? '$weekLabel: ${selectedTeam.displayName} beats ${opponent.displayName} $userScore-$opponentScore'
        : '$weekLabel: ${selectedTeam.displayName} falls to ${opponent.displayName} $opponentScore-$userScore';

    final playerHeadline = '$weekLabel Player of the Game: ${player.cleanName} (${player.position}) — $playerLine';
    final lastWeekHeadline = 'Last game: ${selectedTeam.displayName} vs ${opponent.displayName} recap is now on the feed.';

    weeklyNewsHeadlines.insert(0, playerHeadline);
    weeklyNewsHeadlines.insert(0, resultHeadline);
    weeklyNewsHeadlines.insert(2, lastWeekHeadline);

    if (weeklyNewsHeadlines.length > 10) {
      weeklyNewsHeadlines.removeRange(10, weeklyNewsHeadlines.length);
    }
  }



  String _committeeSeasonReview() {
    if (_userHasPowerFourAutoBid()) {
      return '${widget.team.name} won the ${widget.team.conference} Championship and receives a guaranteed Power 4 conference-champion bid to the 12-team KP.';
    }
    final powerFourChamp = isPowerFourConference(widget.team.conference) &&
        trophyRoom.any((t) => t.year == season && t.type == 'Conference Championship');

    if (powerFourChamp) {
      return 'The committee values ${widget.team.name} as a ${widget.team.conference} champion. Winning a Power 4 conference title gives this team an automatic KP bid.';
    }

    if (displayRank <= 12 && wins >= 10) {
      return '${widget.team.name} finished $recordText with a playoff-level resume. The committee rewards the strong record, ranking, and quality season with a KP spot.';
    }

    if (wins >= 9) {
      return '${widget.team.name} had a strong $recordText season, but the committee felt the resume was just outside the KP field. This team earns a strong bowl destination.';
    }

    if (wins >= 6) {
      return '${widget.team.name} finished bowl eligible at $recordText. The committee sends the program to a bowl game after a solid season.';
    }

    return '${widget.team.name} finished $recordText. The committee did not see enough wins for the postseason, so the season ends here.';
  }

  void _advanceFromSelectionShow() {
    final seeds = _cfpSeeds();
    final userInCfp = seeds.any((team) => team.name == widget.team.name);
    setState(() {
      if (userInCfp) {
        seasonPhase = 'cfp';
        postseasonRound = 1;
        madeCfpThisSeason = true;
        nextOpponent = _playoffOpponent();
      } else if (wins >= 6) {
        seasonPhase = 'bowl';
        nextOpponent = _bowlOpponent();
      } else {
        seasonPhase = 'offseason';
      }
    });
    _autoSaveCareer();
  }

  void _simNextGame() {
    if (seasonPhase == 'selectionShow') {
      _advanceFromSelectionShow();
      return;
    }

    if (gamesPlayed >= 12 && seasonPhase == 'regular') {
      _advancePostseason();
      return;
    }

    if (seasonPhase == 'offseason') {
      AdManager.showAd(context, onContinue: _openOffseason);
      return;
    }

    final myChance =
        (0.5 + ((teamOvr - opponentOvr) * 0.026)).clamp(0.10, 0.90);
    final won = rng.nextDouble() < myChance;

    _applyGameResult(
      GameCompletionResult(
        won: won,
        pressConference: PressConferenceResult(
          tone: 'Stay Composed',
          quote: won
              ? 'We handled our business, but there is still work to do.'
              : 'We will study it, correct it, and move forward together.',
          mediaReaction: won
              ? 'The media views the response as focused and professional.'
              : 'The media views the response as calm and accountable.',
          mediaDelta: 2,
          moraleDelta: won ? 2 : 1,
          boosterDelta: won ? 1 : 0,
          recruitingDelta: won ? 1 : 0,
        ),
      ),
    );
  }

  void _addTrophy({
    required String type,
    required String title,
    required CollegeTeam opponent,
  }) {
    trophyRoom.add(
      TrophyEntry(
        year: season,
        type: type,
        title: title,
        opponent: opponent.name,
      ),
    );
  }

  String _championshipScore(bool won) {
    final userScore = won ? 27 + rng.nextInt(18) : 17 + rng.nextInt(14);
    final oppScore = won ? max(10, userScore - (3 + rng.nextInt(14))) : userScore + (3 + rng.nextInt(14));
    return won ? '$userScore-$oppScore' : '$oppScore-$userScore';
  }

  void _recordNationalTitleHistory({
    required String winner,
    required String loser,
    required String score,
  }) {
    if (nationalHistoryRecordedThisSeason) return;
    nationalHistory.add(
      NationalTitleHistoryEntry(
        year: season,
        winner: winner,
        loser: loser,
        score: score,
      ),
    );
    nationalHistoryRecordedThisSeason = true;
  }

  void _recordSimulatedNationalTitleIfNeeded() {
    if (nationalHistoryRecordedThisSeason) return;

    final contenders = _rankedTeams()
        .where((t) => t.name != widget.team.name)
        .take(12)
        .toList();

    if (contenders.length < 2) return;

    contenders.shuffle(rng);
    final a = contenders[0];
    final b = contenders[1];
    final aChance = (0.50 + ((prestige100(a.prestige) - prestige100(b.prestige)) / 220)).clamp(.38, .62);
    final aWon = rng.nextDouble() < aChance;
    final winner = aWon ? a : b;
    final loser = aWon ? b : a;
    final winnerScore = 24 + rng.nextInt(22);
    final loserScore = max(10, winnerScore - (3 + rng.nextInt(18)));

    _recordNationalTitleHistory(
      winner: winner.name,
      loser: loser.name,
      score: '$winnerScore-$loserScore',
    );
  }

  void _applyGameResult(GameCompletionResult completion) {
    final won = completion.won;
    final press = completion.pressConference;
    String? celebrationTitle;
    String? celebrationSubtitle;
    bool celebrationConfetti = false;
    final playedOpponent = nextOpponent;

    setState(() {
      mediaReputation =
          (mediaReputation + press.mediaDelta).clamp(0, 100);
      playerMorale =
          (playerMorale + press.moraleDelta).clamp(0, 100);
      boosterApproval =
          (boosterApproval + press.boosterDelta).clamp(0, 100);
      recruitingBuzz =
          (recruitingBuzz + press.recruitingDelta).clamp(0, 100);
      fanHappiness = (fanHappiness + (won ? 4 : -5)).clamp(0, 100);
      lastPressTone = press.tone;
      lastPressQuote = press.quote;
      weeklyNewsHeadlines.insert(
        0,
        'PRESS ROOM: Coach ${widget.coach.name} chose a '
        '${press.tone.toLowerCase()} message after the '
        '${won ? 'win' : 'loss'}.',
      );

      if (seasonPhase == 'regular') {
        final wasConfGame = gamesPlayed >= 3;

        _addGameHeadlines(won: won, opponent: playedOpponent);

        gamesPlayed++;

        if (won) {
          wins++;
          if (wasConfGame) confWins++;
        } else {
          losses++;
          if (wasConfGame) confLosses++;
        }

        _updateUserAndOpponentRecord(
          won: won,
          wasConferenceGame: wasConfGame,
          opponent: playedOpponent,
        );
        _simulateNationalWeek(playedOpponent);
        _generateLivingWorldHeadlines(userWon: won);

        if (gamesPlayed == 10) {
          _finalizeRecruitingClass();
        }

        if (gamesPlayed < 12) {
          nextOpponent = schedule[gamesPlayed];
        }

        if (gamesPlayed == 3 || gamesPlayed == 6 || gamesPlayed == 9) {
          recruitingWindow = (gamesPlayed ~/ 3).clamp(1, 3);
          recruitingPoints = 100;
          _processRecruitDecisions();
        }
      } else if (seasonPhase == 'confChamp') {
        _addGameHeadlines(won: won, opponent: playedOpponent);

        if (won) {
          wins++;
          celebrationTitle = 'CONFERENCE CHAMPIONS';
          celebrationSubtitle = '${widget.team.name} defeats ${playedOpponent.name} to win the ${widget.team.conference} Championship.';
          _addTrophy(
            type: 'Conference Championship',
            title: '${widget.team.conference} Champions',
            opponent: playedOpponent,
          );

          seasonPhase = 'selectionShow';
          assignedBowlName = '';
          nextOpponent = _cfpSeeds().any((team) => team.name == widget.team.name)
              ? _playoffOpponent()
              : (wins >= 6 ? _bowlOpponent() : nextOpponent);
        } else {
          losses++;
          seasonPhase = 'selectionShow';
          assignedBowlName = '';
        }
      } else if (seasonPhase == 'cfp') {
        _addGameHeadlines(won: won, opponent: playedOpponent);

        if (won && postseasonRound < 4) {
          wins++;
          postseasonRound++;
          nextOpponent = _playoffOpponent();
        } else {
          if (won) {
            wins++;
            celebrationTitle = 'NATIONAL CHAMPIONS';
            celebrationSubtitle = '${widget.team.name} finishes the run and wins the National Championship.';
            celebrationConfetti = true;
            final titleScore = _championshipScore(true);
            _addTrophy(
              type: 'National Championship',
              title: 'National Champions',
              opponent: playedOpponent,
            );
            _recordNationalTitleHistory(
              winner: widget.team.name,
              loser: playedOpponent.name,
              score: titleScore,
            );
          } else {
            losses++;
            if (postseasonRound >= 4) {
              final titleScore = _championshipScore(false);
              _recordNationalTitleHistory(
                winner: playedOpponent.name,
                loser: widget.team.name,
                score: titleScore,
              );
            }
          }
          seasonPhase = 'offseason';
        }
      } else if (seasonPhase == 'bowl') {
        _addGameHeadlines(won: won, opponent: playedOpponent);

        if (won) {
          wins++;
          celebrationTitle = '${_assignedBowlName.toUpperCase()} CHAMPIONS';
          celebrationSubtitle = '${widget.team.name} defeats ${playedOpponent.name} to win the $_assignedBowlName.';
          _addTrophy(
            type: 'Bowl Win',
            title: '$_assignedBowlName Champions',
            opponent: playedOpponent,
          );
        } else {
          losses++;
        }
        seasonPhase = 'offseason';
      }
    });

    _autoSaveCareer();

    if (celebrationTitle != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ChampionshipCelebrationScreen(
              title: celebrationTitle!,
              subtitle: celebrationSubtitle ?? '',
              team: widget.team,
              record: recordText,
              confetti: celebrationConfetti,
            ),
          ),
        );
      });
    }
  }


  void _simToMidpoint() {
    if (seasonPhase != 'regular') return;
    while (gamesPlayed < 6) {
      _simNextGame();
    }
  }

  void _simRegularSeasonEnd() {
    if (seasonPhase != 'regular') return;
    while (gamesPlayed < 12) {
      _simNextGame();
    }
  }

  void _openGameSim() {
    if (seasonPhase == 'selectionShow') {
      _advanceFromSelectionShow();
      return;
    }

    if (gamesPlayed >= 12 && seasonPhase == 'regular') {
      _advancePostseason();
      return;
    }

    if (seasonPhase == 'offseason') {
      AdManager.showAd(context, onContinue: _openOffseason);
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => GameSimScreen(
          team: widget.team,
          opponent: nextOpponent,
          teamOvr: teamOvr.round(),
          opponentOvr: opponentOvr,
          onFinished: _applyGameResult,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      _dashboardTab(),
      _rosterTab(),
      _playTab(),
      _recruitTab(),
      _menuTab(),
    ];

    return Scaffold(
      backgroundColor: GKColors.ledgerBlack,
      body: SafeArea(
        child: Column(
          children: [
            _kingdomMasthead(),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 260),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                child: KeyedSubtree(
                  key: ValueKey(selectedTab),
                  child: pages[selectedTab],
                ),
              ),
            ),
            _commandDock(),
          ],
        ),
      ),
    );
  }

  String get _weekDisplay {
    if (seasonPhase == 'regular') {
      return gamesPlayed >= 12 ? 'POSTSEASON' : 'WEEK ${gamesPlayed + 1}';
    }

    if (seasonPhase == 'selectionShow') return 'SELECTION SHOW';
    if (seasonPhase == 'confChamp') return 'CONFERENCE TITLE';
    if (seasonPhase == 'cfp') return 'KP ROUND $postseasonRound';
    if (seasonPhase == 'bowl') return 'BOWL WEEK';
    return 'OFFSEASON';
  }

  String get _advanceLabel {
    if (seasonPhase == 'offseason') return 'Advance to Offseason';
    if (seasonPhase == 'selectionShow') return 'Reveal Postseason';
    if (gamesPlayed >= 12 && seasonPhase == 'regular') {
      return conferenceChampEligible
          ? 'Play Conference Championship'
          : 'Open Selection Show';
    }
    if (seasonPhase == 'cfp') return 'Play KP Game';
    if (seasonPhase == 'bowl') return 'Play Bowl Game';
    if (seasonPhase == 'confChamp') return 'Play Conference Championship';
    return 'Advance to Week ${gamesPlayed + 1}';
  }

  String get _gameLocation {
    return gamesPlayed.isEven ? 'AWAY' : 'HOME';
  }

  String get _weatherLabel {
    final value =
        (season * 19 + gamesPlayed * 11 + nextOpponent.name.length) % 5;

    return switch (value) {
      0 => 'Clear · 64°',
      1 => 'Cloudy · 58°',
      2 => 'Light rain · 51°',
      3 => 'Windy · 47°',
      _ => 'Clear · 72°',
    };
  }

  String get _broadcastLabel {
    if (displayRank <= 15 || _rankForTeam(nextOpponent) <= 15) {
      return 'NATIONAL TV';
    }
    if (rivalryTeam?.name == nextOpponent.name) return 'RIVALRY NETWORK';
    return gamesPlayed >= 8 ? 'PRIMETIME' : 'REGIONAL TV';
  }

  double get _projectedSpread {
    final raw = (teamOvr - opponentOvr) * .72;
    final rounded = (raw * 2).round() / 2;
    return rounded.clamp(-28, 28).toDouble();
  }

  String get _spreadLabel {
    final spread = _projectedSpread;

    if (spread == 0) return 'PICK';
    return spread > 0
        ? '${widget.team.name} -${spread.toStringAsFixed(1)}'
        : '${nextOpponent.name} -${spread.abs().toStringAsFixed(1)}';
  }

  String get _matchupStakes {
    if (seasonPhase == 'confChamp') {
      return 'Conference championship and possible automatic KP bid';
    }
    if (seasonPhase == 'cfp') return 'Win or the season ends';
    if (seasonPhase == 'bowl') return 'Finish the season with a trophy';
    if (rivalryTeam?.name == nextOpponent.name) {
      return 'Rivalry pride and recruiting momentum';
    }
    if (displayRank <= 25 || _rankForTeam(nextOpponent) <= 25) {
      return 'Top 25 and postseason implications';
    }
    if (wins == 5) return 'A win secures bowl eligibility';
    if (gamesPlayed >= 8) return 'Conference race and bowl positioning';
    return 'Build momentum and strengthen the program résumé';
  }

  List<Player> get _dashboardTeamLeaders {
    final sorted = [...roster]
      ..sort(
        (a, b) => awardOverall(b).compareTo(awardOverall(a)),
      );
    return sorted.take(3).toList();
  }

  void _showAdvanceWeekSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return SafeArea(
          child: Container(
            margin: const EdgeInsets.all(GKSpace.sm),
            padding: const EdgeInsets.all(GKSpace.xl),
            decoration: BoxDecoration(
              color: GKColors.elevatedPanel,
              border: Border.all(color: GKColors.divider),
              borderRadius: BorderRadius.circular(GKRadius.modal),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(.45),
                  blurRadius: 35,
                  offset: const Offset(0, 15),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'WEEKLY COMMAND',
                  style: GKText.sectionLabel,
                ),
                const SizedBox(height: GKSpace.xs),
                Text(
                  _advanceLabel.toUpperCase(),
                  style: GKText.pageTitle,
                ),
                const SizedBox(height: GKSpace.xs),
                Text(
                  seasonPhase == 'offseason'
                      ? 'The season is complete. Continue into the coaching carousel, retention, portal, development, and scheduling.'
                      : '$recordText ${widget.team.name} faces ${_rankedDisplayNameForTeam(nextOpponent)}. $_matchupStakes.',
                  style: GKText.body,
                ),
                const SizedBox(height: GKSpace.xl),
                if (seasonPhase != 'offseason') ...[
                  GKPrimaryButton(
                    label: seasonPhase == 'selectionShow'
                        ? 'Continue'
                        : 'Play With Broadcast',
                    icon: Icons.sports_football_rounded,
                    onPressed: () {
                      Navigator.of(sheetContext).pop();

                      if (seasonPhase == 'selectionShow') {
                        _simNextGame();
                      } else if (gamesPlayed >= 12 &&
                          seasonPhase == 'regular') {
                        _advancePostseason();
                      } else {
                        _openGameSim();
                      }
                    },
                  ),
                  const SizedBox(height: GKSpace.sm),
                ],
                GKSecondaryButton(
                  label: seasonPhase == 'offseason'
                      ? 'Enter Offseason'
                      : seasonPhase == 'selectionShow'
                          ? 'Reveal Selection'
                          : 'Quick Sim',
                  icon: seasonPhase == 'offseason'
                      ? Icons.arrow_forward_rounded
                      : Icons.fast_forward_rounded,
                  onPressed: () {
                    Navigator.of(sheetContext).pop();

                    if (seasonPhase == 'offseason') {
                      AdManager.showAd(
                        context,
                        onContinue: _openOffseason,
                      );
                    } else {
                      _simNextGame();
                    }
                  },
                ),
                const SizedBox(height: GKSpace.xs),
                Center(
                  child: TextButton(
                    onPressed: () => Navigator.of(sheetContext).pop(),
                    child: Text(
                      'NOT YET',
                      style: TextStyle(
                        color: GKColors.mutedSilver,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.4,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }


  Widget _kingdomMasthead() {
    final title = switch (selectedTab) {
      0 => 'PROGRAM HQ',
      1 => 'FOOTBALL OPERATIONS',
      2 => 'NATIONAL DESK',
      3 => 'RECRUITING ROOM',
      _ => 'COACH OFFICE',
    };

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: const BoxDecoration(
        color: GKColors.saddleLeather,
        border: Border(bottom: BorderSide(color: GKColors.elevatedLeather)),
      ),
      child: Row(
        children: [
          InkWell(
            onTap: _openKingdomNavigator,
            borderRadius: BorderRadius.circular(4),
            child: Container(
              width: 42,
              height: 42,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                border: Border.all(color: GKColors.stitchLine),
              ),
              child: const Icon(Icons.grid_view_rounded, color: GKColors.parchmentWhite, size: 20),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: GKColors.parchmentWhite,
                    fontSize: 17,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.6,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'SEASON $season  /  $_weekDisplay  /  $recordText',
                  style: const TextStyle(
                    color: GKColors.fadedInk,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: .8,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: GKColors.elevatedLeather,
              border: Border.all(color: GKColors.kingdomBrass.withOpacity(.55)),
            ),
            child: Text(
              '${recruitingPoints} RP',
              style: const TextStyle(
                color: GKColors.kingdomBrass,
                fontWeight: FontWeight.w900,
                fontSize: 11,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _openKingdomNavigator() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final destinations = <({IconData icon, String title, String detail})>[
          (icon: Icons.apartment_rounded, title: 'Program HQ', detail: 'Your week, pulse, and decisions'),
          (icon: Icons.sports_football_rounded, title: 'Football Operations', detail: 'Roster, depth chart, and personnel'),
          (icon: Icons.public_rounded, title: 'National Desk', detail: 'Polls, standings, and the college football world'),
          (icon: Icons.person_search_rounded, title: 'Recruiting Room', detail: 'Boards, scouting, offers, and commitments'),
          (icon: Icons.badge_outlined, title: 'Coach Office', detail: 'Career, contracts, history, and settings'),
        ];

        return SafeArea(
          child: Container(
            margin: const EdgeInsets.fromLTRB(10, 40, 10, 10),
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
            decoration: BoxDecoration(
              color: GKColors.saddleLeather,
              border: Border.all(color: GKColors.stitchLine),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'KINGDOM NAVIGATOR',
                  style: TextStyle(color: GKColors.parchmentWhite, fontSize: 20, fontWeight: FontWeight.w900, letterSpacing: 1.4),
                ),
                const SizedBox(height: 4),
                Text(
                  'Move through the program like a coach, not a row of app tabs.',
                  style: TextStyle(color: GKColors.fadedInk, fontSize: 12, height: 1.4),
                ),
                const SizedBox(height: 18),
                ...destinations.asMap().entries.map((entry) {
                  final active = selectedTab == entry.key;
                  final item = entry.value;
                  return InkWell(
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      setState(() => selectedTab = entry.key);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 15),
                      decoration: const BoxDecoration(
                        border: Border(bottom: BorderSide(color: GKColors.elevatedLeather)),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 42,
                            height: 42,
                            alignment: Alignment.center,
                            color: active ? GKColors.fieldGreen : GKColors.saddleLeather,
                            child: Icon(item.icon, color: active ? GKColors.kingdomBrass : GKColors.fadedInk),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(item.title.toUpperCase(), style: TextStyle(color: active ? GKColors.parchmentWhite : GKColors.parchmentWhite, fontWeight: FontWeight.w900, letterSpacing: .8)),
                                const SizedBox(height: 3),
                                Text(item.detail, style: const TextStyle(color: GKColors.fadedInk, fontSize: 11)),
                              ],
                            ),
                          ),
                          Icon(Icons.arrow_forward_rounded, color: active ? GKColors.kingdomBrass : GKColors.fieldGreen, size: 18),
                        ],
                      ),
                    ),
                  );
                }),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _commandDock() {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      decoration: BoxDecoration(
        color: GKColors.ledgerBlack,
        border: Border(top: BorderSide(color: GKColors.stitchLine)),
      ),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: _openKingdomNavigator,
              child: Container(
                height: 54,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(border: Border.all(color: GKColors.stitchLine)),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.grid_view_rounded, color: GKColors.fadedInk, size: 20),
                    const SizedBox(width: 8),
                    Text('NAVIGATE',
                        style: GKText.button.copyWith(
                          color: GKColors.parchmentWhite,
                          fontSize: 12,
                          letterSpacing: 1,
                        )),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: 2,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: _showAdvanceWeekSheet,
                child: Ink(
                  height: 54,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [GKColors.brightBrass, GKColors.kingdomBrass],
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('NEXT DECISION',
                                style: GKText.sectionLabel.copyWith(
                                  color: GKColors.inkBlack,
                                  fontSize: 9,
                                  letterSpacing: 1,
                                )),
                            Text('CONTINUE WEEK',
                                overflow: TextOverflow.ellipsis,
                                style: GKText.button.copyWith(
                                  color: GKColors.inkBlack,
                                  fontSize: 13,
                                  letterSpacing: .3,
                                )),
                          ],
                        ),
                      ),
                      const Icon(Icons.arrow_forward_rounded, color: GKColors.inkBlack, size: 22),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _hqIdentityBand() {
    final rank = displayRank <= 25 ? '#$displayRank' : 'UNRANKED';
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 22, 18, 20),
      decoration: BoxDecoration(
        color: gkDarkenedSchoolColor(widget.team.primary, .82),
        border: Border(bottom: BorderSide(color: widget.team.primary.withOpacity(.75), width: 3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 76,
            height: 76,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: GKColors.ledgerBlack,
              border: Border.all(color: widget.team.primary.withOpacity(.8), width: 2),
            ),
            child: Text(
              widget.team.broadcastInitials,
              style: const TextStyle(color: GKColors.parchmentWhite, fontSize: 23, fontWeight: FontWeight.w900, letterSpacing: 1),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(rank, style: const TextStyle(color: GKColors.kingdomBrass, fontSize: 12, fontWeight: FontWeight.w900, letterSpacing: 1.3)),
                const SizedBox(height: 4),
                Text(
                  '${widget.team.emoji} ${widget.team.displayName.toUpperCase()}',
                  style: const TextStyle(color: GKColors.parchmentWhite, fontSize: 21, fontWeight: FontWeight.w900, height: 1.05),
                ),
                const SizedBox(height: 7),
                Text(
                  '${widget.team.conference.toUpperCase()}  /  $recordText  /  ${teamOvr.round()} OVR',
                  style: const TextStyle(color: GKColors.fadedInk, fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: .7),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _hqNextAssignment() {
    final opponentRank = _rankForTeam(nextOpponent);
    final opponentPrefix = opponentRank <= 25 ? '#$opponentRank ' : '';
    return Container(
      decoration: const BoxDecoration(
        border: Border(
          top: BorderSide(color: GKColors.fieldGreen, width: 2),
          bottom: BorderSide(color: GKColors.elevatedLeather),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 9),
            child: Row(
              children: [
                Text('NEXT ASSIGNMENT', style: TextStyle(color: GKColors.parchmentWhite, fontSize: 12, fontWeight: FontWeight.w900, letterSpacing: 1.2)),
                const Spacer(),
                Text(_broadcastLabel, style: const TextStyle(color: GKColors.stampRed, fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: .8)),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 20),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: GKColors.elevatedLeather)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('$_gameLocation / GAME ${gamesPlayed + 1}', style: const TextStyle(color: GKColors.kingdomBrass, fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 1)),
                      const SizedBox(height: 7),
                      Text('$opponentPrefix${nextOpponent.displayName}'.toUpperCase(), style: const TextStyle(color: GKColors.parchmentWhite, fontSize: 20, fontWeight: FontWeight.w900, height: 1.08)),
                      const SizedBox(height: 8),
                      Text('${_recordForTeam(nextOpponent)}  /  $opponentOvr OVR  /  ${nextOpponent.conference}', style: const TextStyle(color: GKColors.fadedInk, fontSize: 11, fontWeight: FontWeight.w700)),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Container(
                  width: 84,
                  padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 7),
                  decoration: BoxDecoration(border: Border.all(color: GKColors.stitchLine)),
                  child: Column(
                    children: [
                      Text('LINE', style: TextStyle(color: GKColors.fadedInk, fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: 1)),
                      const SizedBox(height: 5),
                      Text(_spreadLabel, textAlign: TextAlign.center, style: const TextStyle(color: GKColors.parchmentWhite, fontSize: 12, fontWeight: FontWeight.w900)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              children: [
                const Icon(Icons.bolt_rounded, color: GKColors.kingdomBrass, size: 16),
                const SizedBox(width: 8),
                Expanded(child: Text(_matchupStakes, style: const TextStyle(color: GKColors.parchmentWhite, fontSize: 11, height: 1.35))),
                Text(_weatherLabel, style: const TextStyle(color: GKColors.fadedInk, fontSize: 10, fontWeight: FontWeight.w800)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _hqSectionLabel(String title, String meta) {
    return Row(
      children: [
        Text(title, style: const TextStyle(color: GKColors.parchmentWhite, fontSize: 13, fontWeight: FontWeight.w900, letterSpacing: 1.2)),
        const SizedBox(width: 10),
        const Expanded(child: Divider(color: GKColors.stitchLine, height: 1)),
        const SizedBox(width: 10),
        Text(meta, style: const TextStyle(color: GKColors.fadedInk, fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: .8)),
      ],
    );
  }

  Widget _hqProgramReadout() {
    final entries = <({String label, int value})>[
      (label: 'MEDIA', value: mediaReputation),
      (label: 'LOCKER ROOM', value: playerMorale),
      (label: 'BOOSTERS', value: boosterApproval),
      (label: 'RECRUITING', value: recruitingBuzz),
      (label: 'SUPPORTERS', value: fanHappiness),
    ];

    return Column(
      children: entries.map((entry) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Row(
            children: [
              SizedBox(width: 92, child: Text(entry.label, style: const TextStyle(color: GKColors.fadedInk, fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: .7))),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(1),
                  child: LinearProgressIndicator(
                    value: entry.value / 100,
                    minHeight: 9,
                    backgroundColor: GKColors.elevatedLeather,
                    valueColor: const AlwaysStoppedAnimation<Color>(GKColors.kingdomBrass),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(width: 28, child: Text('${entry.value}', textAlign: TextAlign.right, style: const TextStyle(color: GKColors.parchmentWhite, fontWeight: FontWeight.w900, fontSize: 12))),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _hqPriorityLedger() {
    final priorities = <({IconData icon, String title, String detail, VoidCallback action})>[
      (icon: Icons.person_search_rounded, title: 'Recruiting board', detail: '$recruitingPoints points available / $commits commitments', action: () => setState(() => selectedTab = 3)),
      (icon: Icons.groups_2_outlined, title: 'Personnel review', detail: '${roster.length} players / ${_dashboardTeamLeaders.first.name} leads the roster', action: () => setState(() => selectedTab = 1)),
      (icon: Icons.public_rounded, title: 'National picture', detail: displayRank <= 25 ? 'Currently ranked #$displayRank' : 'Outside the Top 25', action: () => setState(() => selectedTab = 2)),
    ];

    return Column(
      children: priorities.asMap().entries.map((entry) {
        final number = entry.key + 1;
        final item = entry.value;
        return InkWell(
          onTap: item.action,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: GKColors.elevatedLeather))),
            child: Row(
              children: [
                SizedBox(width: 30, child: Text('0$number', style: const TextStyle(color: GKColors.kingdomBrass, fontSize: 12, fontWeight: FontWeight.w900))),
                Icon(item.icon, color: GKColors.fadedInk, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(item.title.toUpperCase(), style: const TextStyle(color: GKColors.parchmentWhite, fontSize: 12, fontWeight: FontWeight.w900, letterSpacing: .5)),
                      const SizedBox(height: 3),
                      Text(item.detail, style: const TextStyle(color: GKColors.fadedInk, fontSize: 10)),
                    ],
                  ),
                ),
                const Icon(Icons.arrow_forward_rounded, color: GKColors.stitchLine, size: 18),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _hqWireStream() {
    final items = _newsFeedItems();
    return Column(
      children: items.asMap().entries.map((entry) {
        final breaking = entry.key == 0 && weeklyNewsHeadlines.isNotEmpty;
        return Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: GKColors.elevatedLeather))),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 5,
                height: 42,
                color: breaking ? GKColors.stampRed : GKColors.fieldGreen,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(breaking ? 'BREAKING' : 'NATIONAL DESK', style: TextStyle(color: breaking ? GKColors.stampRed : GKColors.kingdomBrass, fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: 1)),
                    const SizedBox(height: 4),
                    Text(entry.value, style: const TextStyle(color: GKColors.parchmentWhite, fontSize: 12, fontWeight: FontWeight.w700, height: 1.35)),
                  ],
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _topStatusBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(
        GKSpace.md,
        GKSpace.xs,
        GKSpace.md,
        GKSpace.sm,
      ),
      decoration: BoxDecoration(
        color: GKColors.midnight.withOpacity(.96),
        border: const Border(
          bottom: BorderSide(color: GKColors.divider),
        ),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => setState(() => selectedTab = 4),
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: GKColors.broadcastNavy,
                border: Border.all(color: GKColors.divider),
                borderRadius: BorderRadius.circular(GKRadius.small),
              ),
              child: const Icon(
                Icons.menu_rounded,
                color: GKColors.mutedSilver,
              ),
            ),
          ),
          const SizedBox(width: GKSpace.sm),
          GKTeamBadge(team: widget.team, size: 43),
          const SizedBox(width: GKSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _rankedDisplayNameForTeam(widget.team).toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: GKColors.warmWhite,
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '$recordText  •  $_weekDisplay',
                  style: const TextStyle(
                    color: GKColors.mutedSilver,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: .7,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 10,
              vertical: 7,
            ),
            decoration: BoxDecoration(
              color: GKColors.kingdomGold.withOpacity(.12),
              border: Border.all(
                color: GKColors.kingdomGold.withOpacity(.28),
              ),
              borderRadius: BorderRadius.circular(GKRadius.pill),
            ),
            child: Text(
              '${recruitingPoints} PTS',
              style: const TextStyle(
                color: GKColors.kingdomGold,
                fontSize: 11,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bottomNav() {
    const items = [
      (Icons.home_rounded, 'HOME'),
      (Icons.groups_2_outlined, 'TEAM'),
      (Icons.public_rounded, 'NATIONAL'),
      (Icons.travel_explore_rounded, 'RECRUIT'),
      (Icons.more_horiz_rounded, 'MORE'),
    ];

    return Container(
      height: 92,
      padding: const EdgeInsets.fromLTRB(8, 7, 8, 9),
      decoration: BoxDecoration(
        color: GKColors.midnight.withOpacity(.99),
        border: const Border(
          top: BorderSide(color: GKColors.divider),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(.28),
            blurRadius: 18,
            offset: const Offset(0, -5),
          ),
        ],
      ),
      child: Row(
        children: List.generate(items.length, (index) {
          final selected = selectedTab == index;
          final item = items[index];

          if (index == 2) {
            return Expanded(
              child: Center(
                child: GestureDetector(
                  onTap: _showAdvanceWeekSheet,
                  child: Container(
                    width: 66,
                    height: 66,
                    decoration: BoxDecoration(
                      color: GKColors.kingdomGold,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: GKColors.warmWhite.withOpacity(.45),
                        width: 2,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: GKColors.kingdomGold.withOpacity(.30),
                          blurRadius: 14,
                          offset: const Offset(0, 5),
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.play_arrow_rounded,
                      color: GKColors.inkBlack,
                      size: 40,
                    ),
                  ),
                ),
              ),
            );
          }

          return Expanded(
            child: InkWell(
              onTap: () => setState(() => selectedTab = index),
              borderRadius: BorderRadius.circular(GKRadius.small),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    item.$1,
                    color: selected
                        ? GKColors.kingdomGold
                        : GKColors.mutedSilver,
                    size: 25,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    item.$2,
                    style: TextStyle(
                      color: selected
                          ? GKColors.kingdomGold
                          : GKColors.mutedSilver,
                      fontSize: 9,
                      fontWeight: FontWeight.w900,
                      letterSpacing: .7,
                    ),
                  ),
                  const SizedBox(height: 4),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    width: selected ? 22 : 5,
                    height: 3,
                    decoration: BoxDecoration(
                      color: selected
                          ? GKColors.kingdomGold
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
      ),
    );
  }

  void _generateLivingWorldHeadlines({required bool userWon}) {
    final otherTeams = g5Teams
        .where((team) => team.name != selectedTeam.name && team.name != nextOpponent.name)
        .toList()
      ..shuffle(rng);
    if (otherTeams.length < 4) return;

    final contender = otherTeams[0];
    final upsetWinner = otherTeams[1];
    final upsetLoser = otherTeams[2];
    final recruitingSchool = otherTeams[3];
    final week = gamesPlayed.clamp(1, 15);

    final generated = <String>[
      'KINGDOM WIRE • ${contender.displayName} climbs into the national conversation after a statement victory.',
      'UPSET WATCH • ${upsetWinner.displayName} shocks ${upsetLoser.displayName} in Week $week.',
      'RECRUITING DESK • ${recruitingSchool.displayName} lands a major commitment for next season.',
      userWon
          ? 'PROGRAM RISE • ${selectedTeam.displayName} continues building momentum under Coach ${widget.coach.name}.'
          : 'PRESSURE REPORT • Supporters expect a response from ${selectedTeam.displayName} next week.',
    ];

    worldNewsHeadlines.insertAll(0, generated);
    if (worldNewsHeadlines.length > 16) {
      worldNewsHeadlines.removeRange(16, worldNewsHeadlines.length);
    }
  }

  List<String> _newsFeedItems() {
    final defaultFeed = <String>[
      'Coach ${widget.coach.name} begins Season $season leading ${selectedTeam.displayName}.',
      '${selectedTeam.displayName} enters $_weekDisplay at $recordText with ${recruitingPoints} recruiting points available.',
      '${_rankedDisplayNameForTeam(nextOpponent)} is next. The early line is $_spreadLabel.',
    ];

    return [
      ...weeklyNewsHeadlines,
      ...worldNewsHeadlines,
      ...defaultFeed,
    ].take(8).toList();
  }

  Widget _dashboardTab() {
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: _hqIdentityBand()),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 34),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              _hqNextAssignment(),
              const SizedBox(height: 22),
              _hqSectionLabel('PROGRAM READOUT', 'LIVE'),
              const SizedBox(height: 10),
              _hqProgramReadout(),
              const SizedBox(height: 24),
              _hqSectionLabel('COACH DESK', '3 PRIORITIES'),
              const SizedBox(height: 10),
              _hqPriorityLedger(),
              const SizedBox(height: 24),
              _hqSectionLabel('KINGDOM WIRE', '${_newsFeedItems().length} STORIES'),
              const SizedBox(height: 4),
              _hqWireStream(),
            ]),
          ),
        ),
      ],
    );
  }

  Widget _coachCommandHeader() {
    return GKCard(
      color: gkDarkenedSchoolColor(widget.team.primary, .70),
      borderColor: widget.team.primary.withOpacity(.65),
      radius: GKRadius.featured,
      child: Row(
        children: [
          Container(
            width: 86,
            height: 86,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: GKColors.midnight,
              border: Border.all(
                color: GKColors.kingdomGold,
                width: 2,
              ),
            ),
            child: ClipOval(
              child: CustomPaint(
                painter: CoachAvatarPainter(
                  skinColor: _skinColor(widget.coach.skinTone),
                  hairColor: _hairColor(widget.coach.hairColor),
                  hairStyle: widget.coach.hairStyle,
                  beard: widget.coach.beard,
                  glasses: widget.coach.glasses,
                  teamColor: widget.team.primary,
                ),
              ),
            ),
          ),
          const SizedBox(width: GKSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'COACH ${widget.coach.name.toUpperCase()}',
                  style: GKText.cardTitle,
                ),
                const SizedBox(height: 5),
                Text(
                  '${widget.coach.coachType}  •  ${widget.coach.offensiveScheme}',
                  style: GKText.body.copyWith(fontSize: 11),
                ),
                const SizedBox(height: GKSpace.sm),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: GKColors.midnight.withOpacity(.55),
                    borderRadius:
                        BorderRadius.circular(GKRadius.pill),
                  ),
                  child: Text(
                    'SEASON $season  •  ${realisticJobSecurityLabel(programPrestige).toUpperCase()}',
                    style: const TextStyle(
                      color: GKColors.kingdomGold,
                      fontSize: 9,
                      fontWeight: FontWeight.w900,
                      letterSpacing: .8,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Color _skinColor(String skinTone) => coachSkinColorFor(skinTone);

  Color _hairColor(String hairColor) => coachHairColorFor(hairColor);

  Widget _programCard() {
    final rankText = displayRank <= 25 ? '#$displayRank' : 'NR';
    final seasonProgress =
        seasonPhase == 'regular' ? (gamesPlayed / 12).clamp(0.0, 1.0) : 1.0;

    return GKCard(
      padding: const EdgeInsets.all(GKSpace.md),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _phase3Stat(recordText, 'OVERALL'),
              ),
              const _Phase3Divider(),
              Expanded(
                child: _phase3Stat(confText, 'CONFERENCE'),
              ),
              const _Phase3Divider(),
              Expanded(
                child: _phase3Stat(
                  rankText,
                  'NATIONAL',
                  highlight: displayRank <= 25,
                ),
              ),
              const _Phase3Divider(),
              Expanded(
                child: _phase3Stat(
                  teamOvr.toStringAsFixed(0),
                  'TEAM OVR',
                  highlight: true,
                ),
              ),
            ],
          ),
          const SizedBox(height: GKSpace.md),
          ClipRRect(
            borderRadius: BorderRadius.circular(5),
            child: LinearProgressIndicator(
              value: seasonProgress,
              minHeight: 6,
              backgroundColor: GKColors.divider,
              valueColor: AlwaysStoppedAnimation<Color>(
                widget.team.primary,
              ),
            ),
          ),
          const SizedBox(height: GKSpace.xs),
          Row(
            children: [
              Text(
                _weekDisplay,
                style: const TextStyle(
                  color: GKColors.mutedSilver,
                  fontSize: 10,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1,
                ),
              ),
              const Spacer(),
              Text(
                '${prestigeStars(programPrestige)} PROGRAM',
                style: const TextStyle(
                  color: GKColors.kingdomGold,
                  fontSize: 10,
                  fontWeight: FontWeight.w900,
                  letterSpacing: .8,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _programPulseCard() {
    String labelFor(int value) {
      if (value >= 80) return 'ELITE';
      if (value >= 65) return 'STRONG';
      if (value >= 45) return 'STEADY';
      if (value >= 30) return 'SHAKY';
      return 'CRITICAL';
    }

    Widget pulseItem(
      IconData icon,
      String label,
      int value,
    ) {
      return Expanded(
        child: Column(
          children: [
            Icon(
              icon,
              color: GKColors.kingdomGold,
              size: 20,
            ),
            const SizedBox(height: 5),
            Text(
              '$value',
              style: const TextStyle(
                color: GKColors.warmWhite,
                fontSize: 20,
                fontWeight: FontWeight.w900,
              ),
            ),
            Text(
              label,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: GKColors.mutedSilver,
                fontSize: 8,
                fontWeight: FontWeight.w900,
                letterSpacing: .5,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              labelFor(value),
              style: const TextStyle(
                color: GKColors.kingdomGold,
                fontSize: 8,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
      );
    }

    return GKCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('PROGRAM PULSE', style: GKText.sectionLabel),
          const SizedBox(height: GKSpace.sm),
          Row(
            children: [
              pulseItem(
                Icons.public_rounded,
                'MEDIA',
                mediaReputation,
              ),
              const _Phase3Divider(),
              pulseItem(
                Icons.groups_rounded,
                'MORALE',
                playerMorale,
              ),
              const _Phase3Divider(),
              pulseItem(
                Icons.handshake_rounded,
                'BOOSTERS',
                boosterApproval,
              ),
              const _Phase3Divider(),
              pulseItem(
                Icons.trending_up_rounded,
                'RECRUITING',
                recruitingBuzz,
              ),
              const _Phase3Divider(),
              pulseItem(
                Icons.stadium_rounded,
                'FANS',
                fanHappiness,
              ),
            ],
          ),
          if (lastPressQuote.isNotEmpty) ...[
            const SizedBox(height: GKSpace.md),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(GKSpace.sm),
              decoration: BoxDecoration(
                color: GKColors.kingdomGold.withOpacity(.08),
                borderRadius:
                    BorderRadius.circular(GKRadius.small),
              ),
              child: Text(
                '$lastPressTone: “$lastPressQuote”',
                style: GKText.body.copyWith(
                  color: GKColors.warmWhite,
                  fontStyle: FontStyle.italic,
                  fontSize: 11,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _phase3Stat(
    String value,
    String label, {
    bool highlight = false,
  }) {
    return Column(
      children: [
        Text(
          value,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: highlight
                ? GKColors.kingdomGold
                : GKColors.warmWhite,
            fontSize: 20,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: GKColors.mutedSilver,
            fontSize: 8,
            fontWeight: FontWeight.w900,
            letterSpacing: .8,
          ),
        ),
      ],
    );
  }

  bool get _wonNationalChampionshipThisSeason {
    return trophyRoom.any(
      (trophy) =>
          trophy.year == season &&
          trophy.type == 'National Championship',
    );
  }

  bool get _wonBowlThisSeason {
    return trophyRoom.any(
      (trophy) =>
          trophy.year == season &&
          trophy.type == 'Bowl Win',
    );
  }

  bool get _wonConferenceChampionshipThisSeason {
    return trophyRoom.any(
      (trophy) =>
          trophy.year == season &&
          trophy.type == 'Conference Championship',
    );
  }

  Widget _postseasonCard() {
    String title;
    String detail;
    String eyebrow;
    IconData icon;
    VoidCallback action;

    if (seasonPhase == 'regular' && gamesPlayed >= 12) {
      eyebrow = 'SEASON COMPLETE';
      title = 'Postseason Selection Show';
      detail =
          'Your regular season is over. Open the live reveal to learn whether you reached the conference championship, Kingdom Football Playoff, a bowl game, or the offseason.';
      icon = Icons.live_tv_rounded;
      action = _advancePostseason;
    } else if (seasonPhase == 'selectionShow') {
      eyebrow = 'LIVE REVEAL';
      title = 'Postseason Selection Show';
      detail =
          'The final envelope is ready. Your postseason destination has not been announced yet.';
      icon = Icons.markunread_mailbox_rounded;
      action = _advancePostseason;
    } else if (seasonPhase == 'offseason') {
      eyebrow = 'SEASON COMPLETE';

      if (_wonNationalChampionshipThisSeason) {
        title = 'National Champions';
        detail =
            '${widget.team.name} completed the KP run and won the National Championship. Continue to the championship season recap and offseason.';
        icon = Icons.emoji_events_rounded;
      } else if (_wonBowlThisSeason) {
        title = '$_assignedBowlName Champions';
        detail =
            '${widget.team.name} finished the season with a victory in the $_assignedBowlName. Continue to the season recap and offseason.';
        icon = Icons.military_tech_rounded;
      } else if (_wonConferenceChampionshipThisSeason) {
        title = '${widget.team.conference} Champions';
        detail =
            '${widget.team.name} won the conference championship and has completed its postseason run. Continue to the offseason.';
        icon = Icons.workspace_premium_rounded;
      } else if (gamesPlayed >= 12 && wins >= 6) {
        title = 'Postseason Complete';
        detail =
            'Your postseason run has ended. Continue into jobs, retention, the portal, development, and scheduling.';
        icon = Icons.flag_circle_rounded;
      } else {
        title = 'No Postseason Invitation';
        detail =
            'Your team did not receive a conference championship, KP, or bowl invitation. Continue directly into the offseason.';
        icon = Icons.event_available_rounded;
      }

      action = () {
        AdManager.showAd(
          context,
          onContinue: _openOffseason,
        );
      };
    } else if (seasonPhase == 'confChamp') {
      eyebrow = 'DESTINATION REVEALED';
      title = '${widget.team.conference} Championship';
      detail =
          'You earned a place in the conference title game. Win it and strengthen your path to the Kingdom Football Playoff.';
      icon = Icons.emoji_events_rounded;
      action = _openGameSim;
    } else if (seasonPhase == 'cfp') {
      eyebrow = 'DESTINATION REVEALED';
      title = _cfpGameNameForRound(postseasonRound);
      detail =
          'You are in the Kingdom Football Playoff. Your next opponent is now available on the matchup card below.';
      icon = Icons.workspace_premium_rounded;
      action = _openGameSim;
    } else {
      eyebrow = 'DESTINATION REVEALED';
      title = _assignedBowlName;
      detail =
          'Your season earned a bowl invitation. Your opponent is now available on the matchup card below.';
      icon = Icons.military_tech_rounded;
      action = _openGameSim;
    }

    return GKCard(
      onTap: action,
      color: Color(0xFF241E12),
      borderColor: GKColors.kingdomGold.withOpacity(.55),
      radius: GKRadius.featured,
      child: Row(
        children: [
          Container(
            width: 51,
            height: 51,
            decoration: BoxDecoration(
              color: GKColors.kingdomGold.withOpacity(.13),
              shape: BoxShape.circle,
            ),
            child: Icon(
              icon,
              color: GKColors.kingdomGold,
              size: 28,
            ),
          ),
          const SizedBox(width: GKSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(eyebrow, style: GKText.sectionLabel),
                const SizedBox(height: 4),
                Text(title.toUpperCase(), style: GKText.cardTitle),
                const SizedBox(height: 4),
                Text(
                  detail,
                  style: GKText.body.copyWith(fontSize: 12),
                ),
              ],
            ),
          ),
          const Icon(
            Icons.arrow_forward_rounded,
            color: GKColors.kingdomGold,
          ),
        ],
      ),
    );
  }

  Widget _nextGameCard() {
    if (gamesPlayed >= 12 && seasonPhase == 'offseason') {
      return GKCard(
        color: GKColors.broadcastNavy,
        borderColor: GKColors.kingdomGold.withOpacity(.38),
        radius: GKRadius.featured,
        child: Column(
          children: [
            const Icon(
              Icons.flag_circle_rounded,
              color: GKColors.kingdomGold,
              size: 42,
            ),
            const SizedBox(height: GKSpace.sm),
            Text(
              _wonNationalChampionshipThisSeason
                  ? 'NATIONAL CHAMPIONS'
                  : _wonBowlThisSeason
                      ? '${_assignedBowlName.toUpperCase()} CHAMPIONS'
                      : 'THE SEASON IS COMPLETE',
              textAlign: TextAlign.center,
              style: GKText.cardTitle,
            ),
            const SizedBox(height: GKSpace.xs),
            Text(
              _wonNationalChampionshipThisSeason
                  ? 'The national title is secured. Your championship season now moves into the offseason.'
                  : _wonBowlThisSeason
                      ? 'Your bowl victory is secured. Your next decisions begin in the offseason.'
                      : 'Your next decisions begin in the offseason.',
              textAlign: TextAlign.center,
              style: GKText.body,
            ),
            const SizedBox(height: GKSpace.md),
            GKPrimaryButton(
              label: 'Advance to Offseason',
              icon: Icons.arrow_forward_rounded,
              onPressed: () {
                AdManager.showAd(
                  context,
                  onContinue: _openOffseason,
                );
              },
            ),
          ],
        ),
      );
    }

    final opponentRank = _rankForTeam(nextOpponent);
    final userRankLabel =
        displayRank <= 25 ? '#$displayRank' : '';
    final opponentRankLabel =
        opponentRank <= 25 ? '#$opponentRank' : '';

    return GKCard(
      padding: EdgeInsets.zero,
      color: gkDarkenedSchoolColor(widget.team.primary, .78),
      borderColor: widget.team.primary.withOpacity(.65),
      radius: GKRadius.featured,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: GKSpace.md,
              vertical: GKSpace.sm,
            ),
            decoration: const BoxDecoration(
              color: GKColors.broadcastNavy,
              borderRadius: BorderRadius.vertical(
                top: Radius.circular(GKRadius.featured),
              ),
            ),
            child: Row(
              children: [
                Text(
                  gamesPlayed >= 12
                      ? postseasonStatus.toUpperCase()
                      : 'GAME ${gamesPlayed + 1} • $_gameLocation',
                  style: const TextStyle(
                    color: GKColors.warmWhite,
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.3,
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: GKColors.alertRed.withOpacity(.12),
                    borderRadius:
                        BorderRadius.circular(GKRadius.pill),
                  ),
                  child: Text(
                    _broadcastLabel,
                    style: const TextStyle(
                      color: GKColors.alertRed,
                      fontSize: 9,
                      fontWeight: FontWeight.w900,
                      letterSpacing: .7,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(GKSpace.md),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _matchupTeam(
                        team: widget.team,
                        ranking: userRankLabel,
                        record: recordText,
                        overall: teamOvr.round(),
                        isUser: true,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: GKSpace.sm,
                      ),
                      child: Column(
                        children: [
                          Text(
                            'VS',
                            style: TextStyle(
                              color: GKColors.mutedSilver,
                              fontSize: 13,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            _gameLocation,
                            style: const TextStyle(
                              color: GKColors.kingdomGold,
                              fontSize: 9,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: _matchupTeam(
                        team: nextOpponent,
                        ranking: opponentRankLabel,
                        record: _recordForTeam(nextOpponent),
                        overall: opponentOvr,
                        isUser: false,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: GKSpace.md),
                Container(
                  padding: const EdgeInsets.all(GKSpace.sm),
                  decoration: BoxDecoration(
                    color: GKColors.midnight.withOpacity(.58),
                    borderRadius:
                        BorderRadius.circular(GKRadius.small),
                  ),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: _matchupDetail(
                              Icons.cloud_outlined,
                              _weatherLabel,
                            ),
                          ),
                          Expanded(
                            child: _matchupDetail(
                              Icons.show_chart_rounded,
                              _spreadLabel,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: GKSpace.xs),
                      Row(
                        children: [
                          const Icon(
                            Icons.bolt_rounded,
                            color: GKColors.kingdomGold,
                            size: 16,
                          ),
                          const SizedBox(width: GKSpace.xs),
                          Expanded(
                            child: Text(
                              _matchupStakes,
                              style:
                                  GKText.body.copyWith(fontSize: 11),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: GKSpace.md),
                Row(
                  children: [
                    Expanded(
                      child: GKPrimaryButton(
                        label: 'Play Game',
                        icon: Icons.play_arrow_rounded,
                        onPressed: _openGameSim,
                      ),
                    ),
                    const SizedBox(width: GKSpace.sm),
                    Expanded(
                      child: GKSecondaryButton(
                        label: 'Quick Sim',
                        icon: Icons.fast_forward_rounded,
                        onPressed: _simNextGame,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _recordForTeam(CollegeTeam team) {
    final record = teamRecords[team.name] ?? TeamSeasonRecord();
    return '${record.wins}-${record.losses}';
  }

  Widget _matchupTeam({
    required CollegeTeam team,
    required String ranking,
    required String record,
    required int overall,
    required bool isUser,
  }) {
    return Column(
      children: [
        GKTeamBadge(team: team, size: 62),
        const SizedBox(height: GKSpace.xs),
        Text(
          ranking.isEmpty
              ? team.name.toUpperCase()
              : '$ranking ${team.name}'.toUpperCase(),
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: isUser
                ? GKColors.warmWhite
                : GKColors.mutedSilver,
            fontSize: 12,
            fontWeight: FontWeight.w900,
            height: 1.1,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '$record  •  $overall OVR',
          style: TextStyle(
            color: isUser
                ? GKColors.kingdomGold
                : GKColors.mutedSilver,
            fontSize: 10,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }

  Widget _matchupDetail(IconData icon, String text) {
    return Row(
      children: [
        Icon(
          icon,
          color: GKColors.mutedSilver,
          size: 15,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: GKColors.warmWhite,
              fontSize: 10,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ],
    );
  }

  Widget _weeklyPrioritiesCard() {
    final remainingGames = max(0, 12 - gamesPlayed);
    final priorityItems = <({IconData icon, String title, String detail})>[
      (
        icon: Icons.travel_explore_rounded,
        title: 'Recruiting board',
        detail:
            '$recruitingPoints points available • $commits commitments',
      ),
      (
        icon: Icons.sports_football_rounded,
        title: 'Game preparation',
        detail:
            '$remainingGames regular-season games remaining • $_spreadLabel',
      ),
      (
        icon: Icons.flag_rounded,
        title: 'Program expectation',
        detail:
            '${realisticContractGoal(programPrestige)} • currently $recordText',
      ),
    ];

    return GKCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('WEEKLY PRIORITIES', style: GKText.sectionLabel),
              const Spacer(),
              Text(
                '${priorityItems.length} ITEMS',
                style: const TextStyle(
                  color: GKColors.mutedSilver,
                  fontSize: 9,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          const SizedBox(height: GKSpace.sm),
          ...priorityItems.asMap().entries.map((entry) {
            final item = entry.value;

            return Container(
              padding: const EdgeInsets.symmetric(vertical: GKSpace.sm),
              decoration: BoxDecoration(
                border: entry.key == priorityItems.length - 1
                    ? null
                    : const Border(
                        bottom: BorderSide(color: GKColors.divider),
                      ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: GKColors.kingdomGold.withOpacity(.10),
                      borderRadius:
                          BorderRadius.circular(GKRadius.small),
                    ),
                    child: Icon(
                      item.icon,
                      color: GKColors.kingdomGold,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: GKSpace.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.title.toUpperCase(),
                          style: const TextStyle(
                            color: GKColors.warmWhite,
                            fontSize: 12,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          item.detail,
                          style:
                              GKText.body.copyWith(fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          }),
          const SizedBox(height: GKSpace.sm),
          GKPrimaryButton(
            label: _advanceLabel,
            icon: Icons.arrow_forward_rounded,
            onPressed: _showAdvanceWeekSheet,
          ),
        ],
      ),
    );
  }

  Widget _teamLeadersCard() {
    final leaders = _dashboardTeamLeaders;

    return GKCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('TEAM LEADERS', style: GKText.sectionLabel),
          const SizedBox(height: GKSpace.sm),
          if (leaders.isEmpty)
            Text(
              'No players are currently available.',
              style: GKText.body,
            )
          else
            ...leaders.asMap().entries.map((entry) {
              final player = entry.value;

              return Container(
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  border: entry.key == leaders.length - 1
                      ? null
                      : const Border(
                          bottom: BorderSide(
                            color: GKColors.divider,
                          ),
                        ),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 34,
                      height: 34,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: widget.team.primary.withOpacity(.18),
                        shape: BoxShape.circle,
                      ),
                      child: Text(
                        '${entry.key + 1}',
                        style: const TextStyle(
                          color: GKColors.kingdomGold,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    const SizedBox(width: GKSpace.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            player.cleanName,
                            style: const TextStyle(
                              color: GKColors.warmWhite,
                              fontSize: 13,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          Text(
                            '${player.position} • ${player.year} • ${player.stars}★',
                            style:
                                GKText.body.copyWith(fontSize: 10),
                          ),
                        ],
                      ),
                    ),
                    Text(
                      '${player.overall}',
                      style: const TextStyle(
                        color: GKColors.kingdomGold,
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }

  Widget _phase3NewsCard(
    String text, {
    required bool breaking,
  }) {
    return GKCard(
      padding: const EdgeInsets.all(GKSpace.sm),
      color: breaking
          ? GKColors.saddleLeather
          : GKColors.broadcastNavy,
      borderColor: breaking
          ? GKColors.alertRed.withOpacity(.50)
          : GKColors.divider,
      radius: GKRadius.small,
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: breaking
                  ? GKColors.alertRed.withOpacity(.15)
                  : GKColors.kingdomGold.withOpacity(.10),
              shape: BoxShape.circle,
            ),
            child: Icon(
              breaking
                  ? Icons.notifications_active_rounded
                  : Icons.bolt_rounded,
              color: breaking
                  ? GKColors.alertRed
                  : GKColors.kingdomGold,
              size: 18,
            ),
          ),
          const SizedBox(width: GKSpace.sm),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: GKColors.warmWhite,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _playTab() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 28, 18, 24),
      children: [
        Text('SIM CENTER', style: TextStyle(color: GKColors.parchmentWhite, fontSize: 36, fontWeight: FontWeight.w900, letterSpacing: 3)),
        const SizedBox(height: 18),
        _nextGameCard(),
        const SizedBox(height: 18),
        DynastyButton(
          text: gamesPlayed >= 12 && seasonPhase == 'offseason'
              ? 'Advance to Next Season'
              : gamesPlayed >= 12 && seasonPhase == 'regular'
                  ? 'Selection Show'
                  : '▶ Play Game',
          onPressed: gamesPlayed >= 12 && seasonPhase == 'regular'
              ? _advancePostseason
              : gamesPlayed >= 12 && seasonPhase == 'offseason'
                  ? () => AdManager.showAd(context, onContinue: _openOffseason)
                  : _openGameSim,
        ),
        const SizedBox(height: 12),
        _secondaryButton('Sim to Midpoint', _simToMidpoint),
        const SizedBox(height: 12),
        _secondaryButton('Sim Reg Season End', _simRegularSeasonEnd),
        const SizedBox(height: 12),
        _outlineGoldButton('Sim to Recruiting Window 1', () => setState(() => selectedTab = 3)),
      ],
    );
  }

  Widget _rosterTab() {
    final positionOrder = ['QB', 'HB', 'WR', 'TE', 'DE', 'LB', 'DB'];
    final rosterAverage = roster.isEmpty
        ? 0
        : (roster.map(awardOverall).reduce((a, b) => a + b) / roster.length)
            .round();
    final starterAverage = starters.isEmpty
        ? 0
        : (starters.map(awardOverall).reduce((a, b) => a + b) /
                starters.length)
            .round();
    final seniors = roster.where((player) => player.year == 'SR').length;

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        GKSpace.md,
        GKSpace.lg,
        GKSpace.md,
        GKSpace.xxl,
      ),
      children: [
        GKCard(
          color: GKColors.fieldGreen,
          borderColor: GKColors.kingdomBrass.withOpacity(.55),
          radius: GKRadius.featured,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  GKTeamBadge(team: widget.team, size: 54),
                  const SizedBox(width: GKSpace.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('ROSTER OPERATIONS', style: GKText.sectionLabel),
                        SizedBox(height: 4),
                        Text('CONTROL THE DEPTH CHART', style: GKText.cardTitle),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 9,
                    ),
                    decoration: BoxDecoration(
                      color: GKColors.kingdomBrass.withOpacity(.10),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: GKColors.kingdomBrass.withOpacity(.55),
                      ),
                    ),
                    child: Column(
                      children: [
                        Text(
                          '${roster.length}',
                          style: const TextStyle(
                            color: GKColors.kingdomBrass,
                            fontSize: 27,
                            fontWeight: FontWeight.w900,
                            height: 1,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'PLAYERS',
                          style: TextStyle(
                            color: GKColors.fieldGreen,
                            fontSize: 8,
                            fontWeight: FontWeight.w900,
                            letterSpacing: .8,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: GKSpace.md),
              Row(
                children: [
                  Expanded(
                    child: _rosterCommandStat(
                      '$starterAverage',
                      'STARTER OVR',
                    ),
                  ),
                  const _Phase3Divider(),
                  Expanded(
                    child: _rosterCommandStat(
                      '$rosterAverage',
                      'TEAM OVR',
                    ),
                  ),
                  const _Phase3Divider(),
                  Expanded(
                    child: _rosterCommandStat(
                      '$seniors',
                      'SENIORS',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: GKSpace.sm),
              Text(
                'Starting unit: 1 QB, 1 HB, 2 WR, 1 TE, 1 DE, 1 LB, and 2 DB. Maximum roster size is 22.',
                style: GKText.body.copyWith(fontSize: 11),
              ),
            ],
          ),
        ),
        const SizedBox(height: GKSpace.md),
        Row(
          children: [
            const Expanded(
              child: Text(
                'ACTIVE UNIT',
                style: TextStyle(
                  color: GKColors.parchmentWhite,
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.8,
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 9,
                vertical: 5,
              ),
              decoration: BoxDecoration(
                color: GKColors.fieldGreen.withOpacity(.10),
                borderRadius: BorderRadius.circular(99),
                border: Border.all(
                  color: GKColors.fieldGreen.withOpacity(.40),
                ),
              ),
              child: Text(
                '${starters.length} STARTERS',
                style: const TextStyle(
                  color: GKColors.fieldGreen,
                  fontSize: 8,
                  fontWeight: FontWeight.w900,
                  letterSpacing: .8,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: GKSpace.sm),
        ...starters.map(_starterPlayerCard),
        const SizedBox(height: GKSpace.lg),
        Text(
          'POSITION ROOMS',
          style: TextStyle(
            color: GKColors.parchmentWhite,
            fontSize: 18,
            fontWeight: FontWeight.w900,
            letterSpacing: 1.8,
          ),
        ),
        const SizedBox(height: GKSpace.sm),
        ...positionOrder.map(
          (position) => _benchGroup(
            position,
            bench.where((player) => player.position == position).toList(),
          ),
        ),
      ],
    );
  }

  Widget _rosterCommandStat(String value, String label) {
    return Column(
      children: [
        Text(
          value,
          style: const TextStyle(
            color: GKColors.parchmentWhite,
            fontSize: 20,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: GKColors.fadedInk,
            fontSize: 8,
            fontWeight: FontWeight.w900,
            letterSpacing: .8,
          ),
        ),
      ],
    );
  }

  List<Recruit> get myRecruitBoard {
    return recruits.where((r) => r.scouts > 0 || r.offered || r.committedSchool == widget.team.name).toList();
  }

  List<Recruit> get availableRecruitBoard {
    final maxStars = maxVisibleStarsForCoachAndSchool(widget.coach, widget.team);
    return recruits
        .where((r) => r.committedSchool == null)
        .where((r) => r.stars <= maxStars || r.scouts > 0 || r.offered)
        .toList();
  }


  List<Recruit> _sortRecruitList(List<Recruit> input) {
    final list = input.toList();

    int overallValue(Recruit r) {
      final text = r.cardOverallText;
      final nums = RegExp(r'\d+').allMatches(text).map((m) => int.parse(m.group(0)!)).toList();
      if (nums.isEmpty) return r.displayedOverall;
      if (nums.length == 1) return nums.first;
      return ((nums.first + nums.last) / 2).round();
    }

    switch (recruitSort) {
      case 'Interest':
        list.sort((a, b) => b.interest.compareTo(a.interest));
        break;
      case 'Overall':
        list.sort((a, b) => overallValue(b).compareTo(overallValue(a)));
        break;
      case 'Rank':
      default:
        list.sort((a, b) => recruits.indexOf(a).compareTo(recruits.indexOf(b)));
        break;
    }

    return list;
  }

  Widget _recruitTab() {
    final hasUnsignedProspects =
        recruits.any((recruit) => recruit.committedSchool == null);

    if (recruitingClosed && hasUnsignedProspects) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (!recruits.any(
          (recruit) => recruit.committedSchool == null,
        )) {
          return;
        }
        _finalizeRecruitingClass();
      });
    }

    final topNeeds = _positionNeeds();
    final filtered = _filteredRecruits();
    final myBoardCount = recruits
        .where(
          (recruit) =>
              recruit.offered ||
              recruit.scouts > 0 ||
              recruit.committedSchool == widget.team.name,
        )
        .length;
    final committedToUser = recruits
        .where((recruit) => recruit.committedSchool == widget.team.name)
        .toList();
    final averageStars = committedToUser.isEmpty
        ? 0.0
        : committedToUser
                .map((recruit) => recruit.stars)
                .reduce((a, b) => a + b) /
            committedToUser.length;

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        GKSpace.md,
        GKSpace.lg,
        GKSpace.md,
        GKSpace.xxl,
      ),
      children: [
        _recruitingCommandHeader(
          myBoardCount: myBoardCount,
          classAverage: averageStars,
        ),
        const SizedBox(height: GKSpace.md),
        _recruitingNeedsCard(topNeeds),
        const SizedBox(height: GKSpace.md),
        _officialVisitOutlook(),
        const SizedBox(height: GKSpace.md),
        _recruitBoardTabs(
          availableCount:
              recruits.where((recruit) => recruit.committedSchool == null).length,
          myBoardCount: myBoardCount,
        ),
        const SizedBox(height: GKSpace.sm),
        _dropdownFilters(),
        const SizedBox(height: GKSpace.sm),
        Row(
          children: [
            Text(
              '${filtered.length} PROSPECTS',
              style: GKText.sectionLabel,
            ),
            const Spacer(),
            Text(
              'WINDOW $recruitingWindow OF 3',
              style: const TextStyle(
                color: GKColors.mutedSilver,
                fontSize: 9,
                fontWeight: FontWeight.w900,
                letterSpacing: 1,
              ),
            ),
          ],
        ),
        const SizedBox(height: GKSpace.sm),
        if (recruitingClosed)
          _recruitingAlert(
            'BOARD LOCKED',
            'The cycle is complete. Every prospect now has a destination.',
            GKColors.alertRed,
          )
        else if (recruitingPoints <= 0)
          _recruitingAlert(
            'NO POINTS REMAINING',
            'Scouting and offers reopen when the next recruiting window begins.',
            GKColors.mutedSilver,
          ),
        if (recruitingClosed || recruitingPoints <= 0)
          const SizedBox(height: GKSpace.sm),
        if (filtered.isEmpty)
          GKCard(
            child: Column(
              children: [
                const Icon(
                  Icons.search_off_rounded,
                  color: GKColors.mutedSilver,
                  size: 38,
                ),
                const SizedBox(height: GKSpace.sm),
                Text(
                  'NO PROSPECTS MATCH',
                  style: GKText.cardTitle,
                ),
                const SizedBox(height: GKSpace.xs),
                Text(
                  'Adjust the board filters to find more recruits.',
                  textAlign: TextAlign.center,
                  style: GKText.body,
                ),
              ],
            ),
          )
        else
          ...filtered.asMap().entries.map(
                (entry) => Padding(
                  padding: const EdgeInsets.only(bottom: GKSpace.sm),
                  child: _recruitListRow(entry.key + 1, entry.value),
                ),
              ),
      ],
    );
  }

  Widget _recruitingCommandHeader({
    required int myBoardCount,
    required double classAverage,
  }) {
    final progress = (recruitingPoints / 100).clamp(0.0, 1.0);

    return GKCard(
      color: GKColors.fieldGreen,
      borderColor: GKColors.kingdomBrass.withOpacity(.55),
      radius: GKRadius.featured,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              GKTeamBadge(team: widget.team, size: 54),
              const SizedBox(width: GKSpace.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('RECRUITING OPERATIONS', style: GKText.sectionLabel),
                    SizedBox(height: 4),
                    Text('CONTROL THE TALENT BOARD', style: GKText.cardTitle),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  color: GKColors.kingdomBrass.withOpacity(.10),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: GKColors.kingdomBrass.withOpacity(.55),
                  ),
                ),
                child: Column(
                  children: [
                    Text(
                      '$recruitingPoints',
                      style: const TextStyle(
                        color: GKColors.kingdomBrass,
                        fontSize: 28,
                        fontWeight: FontWeight.w900,
                        height: 1,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'RP',
                      style: TextStyle(
                        color: GKColors.fadedInk,
                        fontSize: 9,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: GKSpace.md),
          ClipRRect(
            borderRadius: BorderRadius.circular(5),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 7,
              backgroundColor: GKColors.divider,
              valueColor: const AlwaysStoppedAnimation<Color>(
                GKColors.kingdomBrass,
              ),
            ),
          ),
          const SizedBox(height: GKSpace.sm),
          Row(
            children: [
              Expanded(
                child: _recruitingHeaderStat(
                  '$commits',
                  'COMMITMENTS',
                ),
              ),
              const _Phase3Divider(),
              Expanded(
                child: _recruitingHeaderStat(
                  '$myBoardCount',
                  'WATCHLIST',
                ),
              ),
              const _Phase3Divider(),
              Expanded(
                child: _recruitingHeaderStat(
                  committedToClassLabel(classAverage),
                  'CLASS AVG',
                ),
              ),
            ],
          ),
          const SizedBox(height: GKSpace.sm),
          Text(
            'Recruiting points reset each window. Evaluations cost 5 RP and scholarship offers cost 10 RP.',
            style: GKText.body.copyWith(fontSize: 11),
          ),
        ],
      ),
    );
  }

  String committedToClassLabel(double averageStars) {
    if (averageStars <= 0) return '—';
    return '${averageStars.toStringAsFixed(1)}★';
  }

  Widget _recruitingHeaderStat(String value, String label) {
    return Column(
      children: [
        Text(
          value,
          style: const TextStyle(
            color: GKColors.warmWhite,
            fontSize: 19,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: GKColors.mutedSilver,
            fontSize: 8,
            fontWeight: FontWeight.w900,
            letterSpacing: .8,
          ),
        ),
      ],
    );
  }

  Widget _recruitingNeedsCard(Map<String, int> topNeeds) {
    return GKCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('PERSONNEL PRIORITIES', style: GKText.sectionLabel),
          const SizedBox(height: GKSpace.xs),
          Text(
            'Seniors and thin position rooms determine the priority of this class.',
            style: GKText.body.copyWith(fontSize: 11),
          ),
          const SizedBox(height: GKSpace.sm),
          Wrap(
            spacing: GKSpace.xs,
            runSpacing: GKSpace.xs,
            children: topNeeds.entries.map((entry) {
              final urgency = entry.value >= 3
                  ? GKColors.alertRed
                  : entry.value == 2
                      ? GKColors.kingdomBrass
                      : GKColors.victoryGreen;

              return Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  color: urgency.withOpacity(.10),
                  border: Border.all(color: urgency.withOpacity(.38)),
                  borderRadius: BorderRadius.circular(GKRadius.pill),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      entry.key,
                      style: const TextStyle(
                        color: GKColors.warmWhite,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(width: 7),
                    Text(
                      '${entry.value} NEED',
                      style: TextStyle(
                        color: urgency,
                        fontSize: 9,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _officialVisitOutlook() {
    final offered = recruits
        .where(
          (recruit) =>
              recruit.offered &&
              recruit.committedSchool == null &&
              recruit.interest >= 55,
        )
        .toList()
      ..sort((a, b) => b.interest.compareTo(a.interest));

    final visitors = offered.take(3).toList();
    final nextHomeGame = gamesPlayed < 12 && gamesPlayed.isOdd;

    return GKCard(
      color: GKColors.saddleLeather,
      borderColor: GKColors.divider,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.stadium_outlined,
                color: GKColors.kingdomBrass,
                size: 24,
              ),
              const SizedBox(width: GKSpace.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('VISIT OPERATIONS', style: GKText.sectionLabel),
                    SizedBox(height: 4),
                    Text('GAME-DAY RECRUITING', style: GKText.cardTitle),
                  ],
                ),
              ),
              Text(
                nextHomeGame ? 'HOME WEEK' : 'NEXT HOME DATE',
                style: TextStyle(
                  color: nextHomeGame
                      ? GKColors.victoryGreen
                      : GKColors.mutedSilver,
                  fontSize: 9,
                  fontWeight: FontWeight.w900,
                  letterSpacing: .8,
                ),
              ),
            ],
          ),
          const SizedBox(height: GKSpace.sm),
          Text(
            visitors.isEmpty
                ? 'Offer interested prospects to make them eligible for a future game-day visit.'
                : '${visitors.length} priority prospects are strong candidates for your next home-game visit.',
            style: GKText.body.copyWith(fontSize: 11),
          ),
          if (visitors.isNotEmpty) ...[
            const SizedBox(height: GKSpace.sm),
            ...visitors.map(
              (recruit) => Padding(
                padding: const EdgeInsets.only(bottom: GKSpace.xs),
                child: Row(
                  children: [
                    PlayerAvatar(
                      seed: recruit.name.hashCode,
                      teamColor: widget.team.primary,
                      size: 34,
                    ),
                    const SizedBox(width: GKSpace.xs),
                    Expanded(
                      child: Text(
                        '${recruit.name} · ${recruit.position} · ${recruit.stars}★',
                        style: const TextStyle(
                          color: GKColors.warmWhite,
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    Text(
                      '${recruit.interest}%',
                      style: const TextStyle(
                        color: GKColors.kingdomBrass,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _recruitingAlert(
    String title,
    String detail,
    Color color,
  ) {
    return GKCard(
      color: color.withOpacity(.10),
      borderColor: color.withOpacity(.38),
      radius: GKRadius.small,
      child: Row(
        children: [
          Icon(Icons.info_outline_rounded, color: color),
          const SizedBox(width: GKSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: color,
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  detail,
                  style: GKText.body.copyWith(fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _recruitBoardTabs({
    required int availableCount,
    required int myBoardCount,
  }) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: GKColors.broadcastNavy,
        borderRadius: BorderRadius.circular(GKRadius.card),
        border: Border.all(color: GKColors.divider),
      ),
      child: Row(
        children: [
          _boardTabButton('OPEN BOARD', 0, availableCount),
          _boardTabButton('WATCHLIST', 1, myBoardCount),
          _boardTabButton('ALL', 2, recruits.length),
        ],
      ),
    );
  }

  Widget _boardTabButton(
    String label,
    int index,
    int count,
  ) {
    final selected = recruitBoardTab == index;

    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => recruitBoardTab = index),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 11),
          decoration: BoxDecoration(
            color: selected
                ? GKColors.kingdomBrass
                : Colors.transparent,
            borderRadius: BorderRadius.circular(GKRadius.small),
          ),
          child: Column(
            children: [
              Text(
                label,
                style: TextStyle(
                  color:
                      selected ? GKColors.inkBlack : GKColors.mutedSilver,
                  fontSize: 9,
                  fontWeight: FontWeight.w900,
                  letterSpacing: .7,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '$count',
                style: TextStyle(
                  color: selected ? GKColors.inkBlack : GKColors.warmWhite,
                  fontSize: 12,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dropdownFilters() {
    final states = recruits.map((recruit) => recruit.state).toSet().toList()
      ..sort();
    const positions = ['QB', 'HB', 'WR', 'TE', 'DE', 'LB', 'DB'];

    return GKCard(
      padding: const EdgeInsets.all(GKSpace.sm),
      radius: GKRadius.small,
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _phase5Filter<int?>(
                  value: starFilter,
                  items: const [null, 1, 2, 3, 4, 5],
                  label: (value) =>
                      value == null ? 'All Stars' : '$value★',
                  onChanged: (value) {
                    setState(() => starFilter = value);
                  },
                ),
              ),
              const SizedBox(width: GKSpace.xs),
              Expanded(
                child: _phase5Filter<String?>(
                  value: positionFilter,
                  items: const [null, ...positions],
                  label: (value) => value ?? 'All Positions',
                  onChanged: (value) {
                    setState(() => positionFilter = value);
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: GKSpace.xs),
          Row(
            children: [
              Expanded(
                child: _phase5Filter<String?>(
                  value: stateFilter,
                  items: [null, ...states],
                  label: (value) => value ?? 'All States',
                  onChanged: (value) {
                    setState(() => stateFilter = value);
                  },
                ),
              ),
              const SizedBox(width: GKSpace.xs),
              Expanded(
                child: _phase5Filter<String>(
                  value: recruitSort,
                  items: const ['Rank', 'Interest', 'Overall'],
                  label: (value) => value,
                  onChanged: (value) {
                    setState(() => recruitSort = value ?? 'Rank');
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _phase5Filter<T>({
    required T value,
    required List<T> items,
    required String Function(T) label,
    required ValueChanged<T?> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: GKColors.midnight.withOpacity(.64),
        border: Border.all(color: GKColors.divider),
        borderRadius: BorderRadius.circular(GKRadius.small),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          dropdownColor: GKColors.elevatedPanel,
          iconEnabledColor: GKColors.kingdomBrass,
          style: const TextStyle(
            color: GKColors.warmWhite,
            fontSize: 11,
            fontWeight: FontWeight.w800,
          ),
          items: items
              .map(
                (item) => DropdownMenuItem<T>(
                  value: item,
                  child: Text(
                    label(item),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              )
              .toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }

  String _recruitMemory(Recruit recruit) {
    final seed = recruit.name.hashCode.abs() % 6;

    return switch (seed) {
      0 => 'Remembers your early scholarship offer.',
      1 => 'Watching how your offense uses his position.',
      2 => 'Interested in the program’s development record.',
      3 => 'Tracking your record in rivalry and ranked games.',
      4 => 'Wants a clear path to early playing time.',
      _ => 'Evaluating the relationship with your coaching staff.',
    };
  }

  String _visitStatus(Recruit recruit) {
    if (recruit.committedSchool != null) {
      return recruit.committedSchool == widget.team.name
          ? 'SIGNED WITH YOU'
          : 'SIGNED ELSEWHERE';
    }
    if (!recruit.offered) return 'OFFER REQUIRED';
    if (recruit.interest >= 70) return 'PRIORITY VISIT';
    if (recruit.interest >= 55) return 'VISIT CANDIDATE';
    return 'BUILD INTEREST';
  }

  Color _interestColor(int interest) {
    if (interest >= 75) return GKColors.victoryGreen;
    if (interest >= 55) return GKColors.kingdomBrass;
    return GKColors.alertRed;
  }

  Widget _recruitListRow(int index, Recruit recruit) {
    final committedToUser =
        recruit.committedSchool == widget.team.name;
    final committedElsewhere = recruit.committedSchool != null &&
        recruit.committedSchool != widget.team.name;
    final interestColor = _interestColor(recruit.interest);

    return GKCard(
      onTap: () {
        Navigator.of(context)
            .push(
              MaterialPageRoute(
                builder: (_) => RecruitProfileScreen(
                  recruit: recruit,
                  rank: index,
                  userSchool: widget.team.name,
                  userTeamColor: widget.team.primary,
                  recruitingClosed: recruitingClosed,
                  recruitingPoints: recruitingPoints,
                  onScout: () => _scoutRecruit(recruit),
                  onOffer: () => _offerRecruit(recruit),
                ),
              ),
            )
            .then((_) => setState(() {}));
      },
      color: committedToUser
          ? GKColors.elevatedLeather
          : committedElsewhere
              ? GKColors.saddleLeather
              : GKColors.broadcastNavy,
      borderColor: committedToUser
          ? GKColors.victoryGreen.withOpacity(.48)
          : committedElsewhere
              ? GKColors.alertRed.withOpacity(.42)
              : recruit.offered
                  ? widget.team.primary.withOpacity(.50)
                  : GKColors.divider,
      radius: GKRadius.card,
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 28,
                child: Text(
                  '#$index',
                  style: const TextStyle(
                    color: GKColors.mutedSilver,
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              PlayerAvatar(
                seed: recruit.name.hashCode,
                teamColor: widget.team.primary,
                size: 50,
              ),
              const SizedBox(width: GKSpace.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            recruit.name.toUpperCase(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: GKColors.warmWhite,
                              fontSize: 14,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: GKColors.midnight.withOpacity(.60),
                            borderRadius:
                                BorderRadius.circular(GKRadius.pill),
                          ),
                          child: Text(
                            recruit.position,
                            style: const TextStyle(
                              color: GKColors.kingdomBrass,
                              fontSize: 10,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${recruit.state} • ${recruit.stars}★ • ${recruit.archetype}',
                      style: GKText.body.copyWith(fontSize: 10),
                    ),
                    const SizedBox(height: 7),
                    if (recruit.committedSchool == null)
                      Row(
                        children: [
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(
                                value:
                                    (recruit.interest / 100).clamp(0, 1),
                                minHeight: 6,
                                backgroundColor: GKColors.divider,
                                valueColor:
                                    AlwaysStoppedAnimation<Color>(
                                  interestColor,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: GKSpace.xs),
                          Text(
                            '${recruit.interest}%',
                            style: TextStyle(
                              color: interestColor,
                              fontSize: 10,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ],
                      )
                    else
                      Row(
                        children: [
                          Icon(
                            committedToUser
                                ? Icons.check_circle_rounded
                                : Icons.school_rounded,
                            size: 14,
                            color: committedToUser
                                ? GKColors.victoryGreen
                                : GKColors.kingdomBrass,
                          ),
                          const SizedBox(width: 5),
                          Expanded(
                            child: Text(
                              committedToUser
                                  ? 'COMMITTED TO YOUR PROGRAM'
                                  : 'COMMITTED TO ${universityDisplayName(recruit.committedSchool!).toUpperCase()}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: committedToUser
                                    ? GKColors.victoryGreen
                                    : GKColors.kingdomBrass,
                                fontSize: 9,
                                fontWeight: FontWeight.w900,
                                letterSpacing: .5,
                              ),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
              const SizedBox(width: GKSpace.sm),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    recruit.scouts >= 3
                        ? '${recruit.displayedOverall}'
                        : recruit.cardOverallText,
                    style: const TextStyle(
                      color: GKColors.warmWhite,
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  Text(
                    'OVR',
                    style: TextStyle(
                      color: GKColors.mutedSilver,
                      fontSize: 8,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: GKSpace.sm),
          Container(
            padding: const EdgeInsets.only(top: GKSpace.sm),
            decoration: const BoxDecoration(
              border: Border(
                top: BorderSide(color: GKColors.divider),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    recruit.committedSchool != null
                        ? recruit.committedSchool == widget.team.name
                            ? 'SIGNED WITH ${widget.team.displayName.toUpperCase()}'
                            : 'SIGNED WITH ${universityDisplayName(recruit.committedSchool!).toUpperCase()}'
                        : recruit.scoutingReport,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: committedToUser
                          ? GKColors.victoryGreen
                          : committedElsewhere
                              ? GKColors.alertRed
                              : GKColors.mutedSilver,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: GKSpace.xs),
                Text(
                  _visitStatus(recruit),
                  style: TextStyle(
                    color: committedToUser
                        ? GKColors.victoryGreen
                        : committedElsewhere
                            ? GKColors.kingdomBrass
                            : GKColors.kingdomBrass,
                    fontSize: 8,
                    fontWeight: FontWeight.w900,
                    letterSpacing: .6,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }


  void _returnToMainMenu() {
    _autoSaveCareer();

    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const HomeScreen()),
      (route) => false,
    );
  }

  Widget _menuTab() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 20, 0, 24),
      children: [
        _menuHeader('SEASON'),
        _menuItem(Icons.home_outlined, 'Dashboard', true, () => setState(() => selectedTab = 0)),
        _menuItem(Icons.calendar_month_outlined, 'Schedule', false, () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ScheduleScreen(team: widget.team, schedule: schedule, gamesPlayed: gamesPlayed)))),
        _menuItem(Icons.bar_chart, 'Standings', false, () { _normalizeConferenceRecords(); Navigator.of(context).push(MaterialPageRoute(builder: (_) => StandingsScreen(team: widget.team, teamRecords: teamRecords))); }),
        _menuItem(
          Icons.public_rounded,
          'Kingdom Network',
          false,
          () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => KingdomNetworkScreen(
                team: widget.team,
                season: season,
                rank: displayRank,
                record: recordText,
                teamRecords: teamRecords,
                roster: roster,
                trophies: trophyRoom,
                history: nationalHistory,
              ),
            ),
          ),
        ),
        _menuHeader('TEAM'),
        _menuItem(Icons.groups_2_outlined, 'Roster', false, () => setState(() => selectedTab = 1)),
        _menuItem(Icons.tune, 'Lineup', false, () => setState(() => selectedTab = 1)),
        _menuItem(Icons.chat_bubble_outline, 'Morale', false, () {}),
        _menuItem(Icons.medical_services_outlined, 'Medical', false, () {}),
        _menuHeader('PROGRAM'),
        _menuItem(Icons.travel_explore, 'Recruiting', false, () => setState(() => selectedTab = 3)),
        _menuItem(Icons.assignment_turned_in_outlined, 'Mock Draft', false, () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => MockDraftScreen(roster: roster)))),
        _menuItem(Icons.emoji_events, 'Trophy Room', false, () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => TrophyRoomScreen(team: widget.team, trophies: trophyRoom)))),
        _menuItem(
          Icons.history_toggle_off_rounded,
          'Dynasty Archive',
          false,
          () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => KingdomNetworkScreen(
                team: widget.team,
                season: season,
                rank: displayRank,
                record: recordText,
                teamRecords: teamRecords,
                roster: roster,
                trophies: trophyRoom,
                history: nationalHistory,
              ),
            ),
          ),
        ),
        _menuHeader('CAREER'),
        _menuItem(Icons.logout, 'Main Menu', false, _returnToMainMenu),
        _menuHeader('MORE'),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          child: Row(children: [Text('Auto-saved', style: TextStyle(color: GKColors.fadedInk)), Spacer(), Text('Build 142', style: TextStyle(color: GKColors.fadedInk))]),
        ),
        const SizedBox(height: 22),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 18), child: DynastyButton(text: seasonPhase == 'offseason' ? 'Advance Season' : '▶ Sim Next Game', onPressed: _simNextGame)),
        const SizedBox(height: 12),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 18), child: _secondaryButton('Sim to Midpoint', _simToMidpoint)),
        const SizedBox(height: 12),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 18), child: _secondaryButton('Sim Reg Season End', _simRegularSeasonEnd)),
      ],
    );
  }

  bool get recruitingClosed => gamesPlayed >= 10;

  String _randomOtherSchoolForRecruit(Recruit recruit) {
    final possible = g5Teams
        .where((team) => team.name != widget.team.name && team.prestige >= recruit.stars - 1)
        .toList()
      ..shuffle(rng);

    return possible.isEmpty ? 'another school' : possible.first.name;
  }

  void _showCommitPopup(Recruit recruit, bool toUser) {
    if (!toUser) return;

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: kCardColor,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text(
            'COMMITMENT!',
            style: TextStyle(
              color: kGold,
              fontWeight: FontWeight.w900,
              letterSpacing: 2,
            ),
          ),
          content: Text(
            '${recruit.name} has committed to ${widget.team.name}!',
            style: const TextStyle(color: GKColors.parchmentWhite, fontWeight: FontWeight.bold),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('OK', style: TextStyle(color: kGold, fontWeight: FontWeight.w900)),
            ),
          ],
        );
      },
    );
  }

  void _offerRecruit(Recruit recruit) {
    if (recruitingClosed || recruit.offered || recruit.committedSchool != null || recruitingPoints < 10) return;

    setState(() {
      recruitingPoints -= 10;
      recruit.offered = true;

      final instantChance = ((recruit.interest + programPrestige * 5 - recruit.stars * 8) / 420).clamp(.02, .16);

      if (rng.nextDouble() < instantChance) {
        recruit.committedSchool = widget.team.name;
        commits++;
      } else {
        final wait = 1 + rng.nextInt(3);
        recruit.decisionWindow = (recruitingWindow + wait).clamp(1, 3);
      }
    });

    if (recruit.committedSchool == widget.team.name && !recruit.commitmentPopupShown) {
      recruit.commitmentPopupShown = true;
      _showCommitPopup(recruit, true);
    }
  }

  void _scoutRecruit(Recruit recruit) {
    if (recruitingClosed || recruit.scouts >= 3 || recruit.committedSchool != null || recruitingPoints < 5) return;

    setState(() {
      recruitingPoints -= 5;
      recruit.scouts++;
    });
  }

  void _processRecruitDecisions() {
    final userCommits = <Recruit>[];

    setState(() {
      for (final recruit in recruits) {
        if (recruit.committedSchool != null) continue;
        if (recruit.decisionWindow == null) continue;
        if (recruit.decisionWindow! > recruitingWindow) continue;

        final userChance = ((recruit.interest + (prestige100(programPrestige) * .8).round() - recruit.stars * 7) / 100).clamp(.15, .78);

        if (rng.nextDouble() < userChance) {
          recruit.committedSchool = widget.team.name;
          commits++;
          userCommits.add(recruit);
        } else {
          recruit.committedSchool = _randomOtherSchoolForRecruit(recruit);
        }
      }
    });

    for (final recruit in userCommits) {
      if (!recruit.commitmentPopupShown) {
        recruit.commitmentPopupShown = true;
        _showCommitPopup(recruit, true);
      }
    }
  }

  void _finalizeRecruitingClass() {
    final userCommits = <Recruit>[];

    setState(() {
      recruitingWindow = 3;

      for (final recruit in recruits) {
        if (recruit.committedSchool != null) continue;

        // A player must have a destination once recruiting closes.
        // Offered players still give the user's program a final chance.
        if (recruit.offered) {
          final userChance = ((
                    recruit.interest +
                        (prestige100(programPrestige) * .8).round() -
                        recruit.stars * 7
                  ) /
                  100)
              .clamp(.15, .78);

          if (rng.nextDouble() < userChance) {
            recruit.committedSchool = widget.team.name;
            commits++;
            userCommits.add(recruit);
          } else {
            recruit.committedSchool =
                _randomOtherSchoolForRecruit(recruit);
          }
        } else {
          // Unoffered prospects sign elsewhere instead of remaining
          // uncommitted through the postseason and offseason.
          recruit.committedSchool =
              _randomOtherSchoolForRecruit(recruit);
        }

        recruit.decisionWindow = 3;
      }
    });

    for (final recruit in userCommits) {
      if (!recruit.commitmentPopupShown) {
        recruit.commitmentPopupShown = true;
        _showCommitPopup(recruit, true);
      }
    }

    _autoSaveCareer();
  }

  List<Recruit> _filteredRecruits() {
    final list = recruits.where((recruit) {
      final boardMatch = switch (recruitBoardTab) {
        1 => recruit.offered ||
            recruit.scouts > 0 ||
            recruit.committedSchool == widget.team.name,
        2 => true,
        _ => recruit.committedSchool == null,
      };

      final starMatch = starFilter == null || recruit.stars == starFilter;
      final positionMatch =
          positionFilter == null || recruit.position == positionFilter;
      final stateMatch =
          stateFilter == null || recruit.state == stateFilter;

      return boardMatch && starMatch && positionMatch && stateMatch;
    }).toList();

    return _sortRecruitList(list);
  }

  Map<String, int> _positionNeeds() {
    final result = <String, int>{};
    for (final pos in ['QB', 'HB', 'WR', 'TE', 'DE']) {
      result[pos] = roster.where((p) => p.position == pos && p.year == 'SR').length.clamp(1, 3);
    }
    return result;
  }

  String _recruitingAccessText() {
    return switch (prestigeTier(programPrestige)) {
      1 => '1★-2★ players',
      2 => '1★-3★ players',
      3 => '2★-4★ players',
      4 => '3★-5★ players',
      _ => 'all recruits',
    };
  }

  Widget _dropdown<T>({
    required String label,
    required T value,
    required List<T> items,
    required String Function(T) itemLabel,
    required ValueChanged<T?> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(color: kGold, borderRadius: BorderRadius.circular(12)),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          dropdownColor: kCardColor,
          iconEnabledColor: GKColors.inkBlack,
          style: const TextStyle(color: GKColors.parchmentWhite, fontWeight: FontWeight.w900),
          selectedItemBuilder: (context) => items.map((item) {
            return Align(
              alignment: Alignment.centerLeft,
              child: Text(itemLabel(item), style: const TextStyle(color: GKColors.inkBlack, fontWeight: FontWeight.w900)),
            );
          }).toList(),
          items: items.map((item) {
            return DropdownMenuItem<T>(
              value: item,
              child: Text(itemLabel(item), style: const TextStyle(color: GKColors.parchmentWhite, fontWeight: FontWeight.w900)),
            );
          }).toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }



  Widget _starterPlayerCard(Player p) {
    final overall = awardOverall(p);
    final developmentColor = p.devRoom >= 12
        ? GKColors.fieldGreen
        : p.devRoom >= 6
            ? GKColors.kingdomBrass
            : GKColors.fadedInk;

    return Container(
      margin: const EdgeInsets.only(bottom: GKSpace.sm),
      padding: const EdgeInsets.all(GKSpace.md),
      decoration: BoxDecoration(
        color: GKColors.saddleLeather,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: GKColors.kingdomBrass.withOpacity(.28),
        ),
      ),
      child: Row(
        children: [
          PlayerAvatar(
            seed: p.name.hashCode,
            teamColor: widget.team.primary,
            size: 48,
          ),
          const SizedBox(width: GKSpace.sm),
          Container(
            width: 42,
            height: 42,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: GKColors.kingdomBrass.withOpacity(.10),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: GKColors.kingdomBrass.withOpacity(.45),
              ),
            ),
            child: Text(
              p.position,
              style: const TextStyle(
                color: GKColors.kingdomBrass,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          const SizedBox(width: GKSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  p.cleanName.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: GKColors.parchmentWhite,
                    fontSize: 15,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${p.year} · ${p.stars}★ · POT ${p.potential}',
                  style: const TextStyle(
                    color: GKColors.fadedInk,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '${p.devRoom.clamp(0, 99)} DEVELOPMENT ROOM',
                  style: TextStyle(
                    color: developmentColor,
                    fontSize: 8,
                    fontWeight: FontWeight.w900,
                    letterSpacing: .7,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: GKSpace.sm),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '$overall',
                style: const TextStyle(
                  color: GKColors.parchmentWhite,
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                  height: 1,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                'OVR',
                style: TextStyle(
                  color: GKColors.kingdomBrass,
                  fontSize: 8,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _benchGroup(String position, List<Player> players) {
    if (players.isEmpty) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.only(bottom: GKSpace.sm),
      decoration: BoxDecoration(
        color: GKColors.saddleLeather,
        border: Border.all(color: GKColors.fieldGreen),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(
              horizontal: GKSpace.md,
              vertical: GKSpace.sm,
            ),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: GKColors.fieldGreen),
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: GKColors.kingdomBrass.withOpacity(.10),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    position,
                    style: const TextStyle(
                      color: GKColors.kingdomBrass,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                const SizedBox(width: GKSpace.sm),
                Expanded(
                  child: Text(
                    '$position ROOM',
                    style: const TextStyle(
                      color: GKColors.parchmentWhite,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.4,
                    ),
                  ),
                ),
                Text(
                  '${players.length} DEEP',
                  style: const TextStyle(
                    color: GKColors.fadedInk,
                    fontSize: 9,
                    fontWeight: FontWeight.w900,
                    letterSpacing: .7,
                  ),
                ),
              ],
            ),
          ),
          ...players.asMap().entries.map(
            (entry) {
              final player = entry.value;
              return Container(
                padding: const EdgeInsets.all(GKSpace.sm),
                decoration: BoxDecoration(
                  border: entry.key == players.length - 1
                      ? null
                      : const Border(
                          bottom: BorderSide(color: GKColors.stitchLine),
                        ),
                ),
                child: Row(
                  children: [
                    PlayerAvatar(
                      seed: player.name.hashCode,
                      teamColor: widget.team.primary,
                      size: 38,
                    ),
                    const SizedBox(width: GKSpace.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            player.cleanName.toUpperCase(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: GKColors.parchmentWhite,
                              fontSize: 12,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            '${player.year} · ${player.stars}★ · POT ${player.potential}',
                            style: const TextStyle(
                              color: GKColors.fadedInk,
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Text(
                      '${awardOverall(player)}',
                      style: const TextStyle(
                        color: GKColors.parchmentWhite,
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _bigStat(String value, String label, Color color) {
    return Column(children: [
      Text(value, style: TextStyle(color: color, fontSize: 42, fontWeight: FontWeight.w900)),
      const SizedBox(height: 4),
      Text(label, style: const TextStyle(color: GKColors.fadedInk, fontWeight: FontWeight.w900, letterSpacing: 2)),
    ]);
  }

  Widget _smallStat(String value, String label) {
    return Column(children: [
      Text(value, style: const TextStyle(color: GKColors.parchmentWhite, fontSize: 22, fontWeight: FontWeight.w900)),
      const SizedBox(height: 4),
      Text(label, style: const TextStyle(color: GKColors.fadedInk, fontWeight: FontWeight.w900, letterSpacing: 2)),
    ]);
  }

  Widget _verticalRule() => Container(width: 1, height: 78, color: kBorder);

  Widget _miniLogo(CollegeTeam team) => GKTeamBadge(team: team, size: 38);

  Widget _smallLogo(CollegeTeam team) => GKTeamBadge(team: team, size: 48);

  Widget _bigLogo(CollegeTeam team) => GKTeamBadge(team: team, size: 74);

  Widget _newsCard(String title, String body) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(color: kCardColor, borderRadius: BorderRadius.circular(22), border: Border.all(color: kBorder)),
      child: Row(children: [
        const Icon(Icons.flash_on, color: kGold),
        const SizedBox(width: 12),
        Expanded(child: RichText(text: TextSpan(style: const TextStyle(color: GKColors.parchmentWhite, fontSize: 16, height: 1.3), children: [
          TextSpan(text: '$title\n', style: const TextStyle(color: kGold, fontWeight: FontWeight.w900, letterSpacing: 2)),
          TextSpan(text: body),
        ]))),
        const Icon(Icons.chevron_right, color: kGold),
      ]),
    );
  }

  Widget _newsLine(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: kBorder))),
      child: Text('⚡ $text', style: const TextStyle(color: GKColors.parchmentWhite, fontSize: 18, height: 1.35)),
    );
  }

  Widget _secondaryButton(String label, VoidCallback onTap) {
    return ElevatedButton(
      style: ElevatedButton.styleFrom(backgroundColor: GKColors.elevatedLeather, minimumSize: const Size(double.infinity, 56), shape: RoundedRectangleBorder(side: const BorderSide(color: kBorder), borderRadius: BorderRadius.circular(16))),
      onPressed: onTap,
      child: Text(label, style: const TextStyle(color: GKColors.fadedInk, fontSize: 18, fontWeight: FontWeight.w900)),
    );
  }

  Widget _outlineGoldButton(String label, VoidCallback onTap) {
    return OutlinedButton(
      style: OutlinedButton.styleFrom(minimumSize: const Size(double.infinity, 56), side: const BorderSide(color: kGold, width: 2), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
      onPressed: onTap,
      child: Text(label, style: const TextStyle(color: kGold, fontSize: 18, fontWeight: FontWeight.w900)),
    );
  }

  Widget _menuHeader(String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
      child: Text(label, style: const TextStyle(color: GKColors.fadedInk, fontSize: 16, fontWeight: FontWeight.w900, letterSpacing: 4)),
    );
  }

  Widget _menuItem(IconData icon, String label, bool selected, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Container(
        color: selected ? kGold.withOpacity(.14) : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
        child: Row(children: [
          Icon(icon, color: selected ? kGold : GKColors.fadedInk, size: 26),
          const SizedBox(width: 20),
          Text(label, style: TextStyle(color: selected ? kGold : GKColors.fadedInk, fontSize: 20, fontWeight: FontWeight.w900)),
        ]),
      ),
    );
  }
}




class _Phase3Divider extends StatelessWidget {
  const _Phase3Divider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 35,
      color: GKColors.divider,
    );
  }
}


class TrophyRoomScreen extends StatelessWidget {
  final CollegeTeam team;
  final List<TrophyEntry> trophies;

  const TrophyRoomScreen({
    super.key,
    required this.team,
    required this.trophies,
  });

  @override
  Widget build(BuildContext context) {
    final sorted = trophies.toList()..sort((a, b) => b.year.compareTo(a.year));

    return Scaffold(
      backgroundColor: kDark,
      appBar: AppBar(title: const AppTitle('Trophy Room')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            '${team.name.toUpperCase()} TROPHY ROOM',
            style: const TextStyle(color: GKColors.parchmentWhite, fontSize: 30, fontWeight: FontWeight.w900, letterSpacing: 3),
          ),
          const SizedBox(height: 8),
          Text(
            'Career trophies collected across this dynasty.',
            style: TextStyle(color: GKColors.fadedInk, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 20),
          _trophySummary(sorted),
          const SizedBox(height: 20),
          if (sorted.isEmpty)
            _emptyCard('No trophies yet. Win a bowl, conference championship, or national championship to add one here.')
          else
            ...sorted.map(_trophyCard),
        ],
      ),
    );
  }

  Widget _trophySummary(List<TrophyEntry> items) {
    int countType(String type) => items.where((t) => t.type == type).length;

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 18),
      decoration: BoxDecoration(color: kCardColor, border: Border.all(color: kBorder), borderRadius: BorderRadius.circular(20)),
      child: Row(
        children: [
          _summaryStat('${countType('Bowl Win')}', 'BOWLS'),
          _summaryStat('${countType('Conference Championship')}', 'CONF'),
          _summaryStat('${countType('National Championship')}', 'NATTYS'),
        ],
      ),
    );
  }

  Widget _summaryStat(String value, String label) {
    return Expanded(
      child: Column(
        children: [
          Text(value, style: const TextStyle(color: kGold, fontSize: 30, fontWeight: FontWeight.w900)),
          const SizedBox(height: 6),
          Text(label, style: const TextStyle(color: GKColors.fadedInk, fontWeight: FontWeight.w900, letterSpacing: 2)),
        ],
      ),
    );
  }

  Widget _emptyCard(String text) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(color: kCardColor, border: Border.all(color: kBorder), borderRadius: BorderRadius.circular(20)),
      child: Text(text, style: const TextStyle(color: GKColors.fadedInk, fontWeight: FontWeight.bold, height: 1.4)),
    );
  }

  Widget _trophyCard(TrophyEntry trophy) {
    final icon = trophy.type == 'National Championship'
        ? Icons.emoji_events
        : trophy.type == 'Conference Championship'
            ? Icons.workspace_premium
            : Icons.military_tech;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: kCardColor, border: Border.all(color: kBorder), borderRadius: BorderRadius.circular(20)),
      child: Row(
        children: [
          Icon(icon, color: kGold, size: 34),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              '${trophy.title}\n${trophy.year} • vs ${trophy.opponent}',
              style: const TextStyle(color: GKColors.parchmentWhite, fontWeight: FontWeight.bold, height: 1.3),
            ),
          ),
          Text(trophy.type.toUpperCase(), style: const TextStyle(color: GKColors.fadedInk, fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 1.5)),
        ],
      ),
    );
  }
}

class NationalHistoryScreen extends StatelessWidget {
  final List<NationalTitleHistoryEntry> history;

  const NationalHistoryScreen({
    super.key,
    required this.history,
  });

  @override
  Widget build(BuildContext context) {
    final sorted = history.toList()..sort((a, b) => b.year.compareTo(a.year));

    return Scaffold(
      backgroundColor: kDark,
      appBar: AppBar(title: const AppTitle('History')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            'DYNASTY HISTORY',
            style: TextStyle(color: GKColors.parchmentWhite, fontSize: 32, fontWeight: FontWeight.w900, letterSpacing: 3),
          ),
          const SizedBox(height: 8),
          Text(
            'National championship game winners by year.',
            style: TextStyle(color: GKColors.fadedInk, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 20),
          if (sorted.isEmpty)
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(color: kCardColor, border: Border.all(color: kBorder), borderRadius: BorderRadius.circular(20)),
              child: Text(
                'No national championship history yet. Finish a season to add the first result.',
                style: TextStyle(color: GKColors.fadedInk, fontWeight: FontWeight.bold, height: 1.4),
              ),
            )
          else
            ...sorted.map(_historyCard),
        ],
      ),
    );
  }

  Widget _historyCard(NationalTitleHistoryEntry entry) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: kCardColor, border: Border.all(color: kBorder), borderRadius: BorderRadius.circular(20)),
      child: Row(
        children: [
          const Icon(Icons.emoji_events, color: kGold, size: 34),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              'Season ${entry.year}\n${entry.winner} def. ${entry.loser} ${entry.score}',
              style: const TextStyle(color: GKColors.parchmentWhite, fontWeight: FontWeight.bold, height: 1.3),
            ),
          ),
          Text('NATIONAL TITLE', style: TextStyle(color: GKColors.fadedInk, fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 1.5)),
        ],
      ),
    );
  }
}

class ChampionshipCelebrationScreen extends StatefulWidget {
  final String title;
  final String subtitle;
  final CollegeTeam team;
  final String record;
  final bool confetti;

  const ChampionshipCelebrationScreen({
    super.key,
    required this.title,
    required this.subtitle,
    required this.team,
    required this.record,
    required this.confetti,
  });

  @override
  State<ChampionshipCelebrationScreen> createState() => _ChampionshipCelebrationScreenState();
}

class _ChampionshipCelebrationScreenState extends State<ChampionshipCelebrationScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 5),
    );

    if (widget.confetti) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kDark,
      body: Stack(
        children: [
          if (widget.confetti)
            AnimatedBuilder(
              animation: _controller,
              builder: (context, child) {
                return CustomPaint(
                  painter: ConfettiPainter(progress: _controller.value),
                  size: Size.infinite,
                );
              },
            ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(22),
              child: Column(
                children: [
                  const Spacer(),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(26),
                    decoration: BoxDecoration(
                      color: kCardColor.withOpacity(.96),
                      border: Border.all(color: kGold, width: 2),
                      borderRadius: BorderRadius.circular(30),
                      boxShadow: [
                        BoxShadow(
                          color: kGold.withOpacity(.25),
                          blurRadius: 16,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: Column(
                      children: [
                        Icon(
                          widget.confetti ? Icons.emoji_events : Icons.workspace_premium,
                          color: kGold,
                          size: 76,
                        ),
                        const SizedBox(height: 18),
                        Text(
                          widget.title,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: GKColors.parchmentWhite,
                            fontSize: 36,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 4,
                          ),
                        ),
                        const SizedBox(height: 14),
                        Text(
                          widget.team.fullName.toUpperCase(),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: kGold,
                            fontSize: 26,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 3,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          widget.subtitle,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: GKColors.parchmentWhite,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            height: 1.35,
                          ),
                        ),
                        const SizedBox(height: 22),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(.18),
                            border: Border.all(color: GKColors.parchmentWhite.withOpacity(.12)),
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: Text(
                            'FINAL RECORD  ${widget.record}',
                            style: const TextStyle(
                              color: GKColors.parchmentWhite,
                              fontSize: 18,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 2,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  SizedBox(
                    width: double.infinity,
                    height: 58,
                    child: DynastyButton(
                      text: 'CONTINUE',
                      onPressed: () => Navigator.pop(context),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ConfettiPainter extends CustomPainter {
  final double progress;

  ConfettiPainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    const colors = [
      kGold,
      kRed,
      kGreen,
      GKColors.parchmentWhite,
      Color(0xFF4A90E2),
    ];

    for (int i = 0; i < 90; i++) {
      final seed = i * 37;
      final x = ((seed * 17) % max(size.width.toInt(), 1)).toDouble();
      final speed = 0.55 + ((seed % 13) / 20);
      final y = ((progress * size.height * speed) + (seed * 11)) % (size.height + 80) - 80;
      final w = 6 + (seed % 5).toDouble();
      final h = 10 + (seed % 7).toDouble();

      paint.color = colors[i % colors.length].withOpacity(.92);
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate((progress * 6.28) + i);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset.zero, width: w, height: h),
          const Radius.circular(2),
        ),
        paint,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant ConfettiPainter oldDelegate) {
    return oldDelegate.progress != progress;
  }
}

class SelectionResult {
  final String phase;
  final String? bowlName;

  const SelectionResult(
    this.phase, {
    this.bowlName,
  });
}

class SelectionScreen extends StatefulWidget {
  final CollegeTeam team;
  final String record;
  final int wins;
  final int losses;
  final int confWins;
  final int confLosses;
  final int rank;
  final int teamOvr;
  final Map<String, TeamSeasonRecord> teamRecords;
  final bool conferenceChampEligible;
  final bool cfpEligible;
  final bool bowlEligible;
  final String existingAssignedBowlName;
  final ValueChanged<SelectionResult> onContinue;

  const SelectionScreen({
    super.key,
    required this.team,
    required this.record,
    required this.wins,
    required this.losses,
    required this.confWins,
    required this.confLosses,
    required this.rank,
    required this.teamOvr,
    required this.teamRecords,
    required this.conferenceChampEligible,
    required this.cfpEligible,
    required this.bowlEligible,
    this.existingAssignedBowlName = '',
    required this.onContinue,
  });

  @override
  State<SelectionScreen> createState() => _SelectionScreenState();
}

class _SelectionScreenState extends State<SelectionScreen> {
  int revealStep = 0;


  String get selectedBowlName {
    if (widget.existingAssignedBowlName.trim().isNotEmpty) {
      return widget.existingAssignedBowlName;
    }

    final recordKey = widget.wins * 31 +
        widget.losses * 17 +
        widget.team.name.hashCode.abs();

    final List<String> choices;

    if (widget.wins >= 11) {
      choices = const [
        'Grove Bowl',
        'Mission Bowl',
        'Bayfront Bowl',
        'Coastline Bowl',
      ];
    } else if (widget.wins == 10) {
      choices = const [
        'Harmony Bowl',
        'Rio Bowl',
        'Neon Bowl',
        'Riverside Bowl',
      ];
    } else if (widget.wins == 9) {
      choices = const [
        'Heritage Bowl',
        'Solstice Bowl',
        'Empire Bowl',
        'Queen City Bowl',
      ];
    } else if (widget.wins == 8) {
      choices = const [
        'Patriots Bowl',
        'Service Bowl',
        'Ironworks Bowl',
        'Desert Sky Bowl',
      ];
    } else if (widget.wins == 7) {
      choices = const [
        'Frontline Bowl',
        'Metroplex Bowl',
        'Mesa Bowl',
        'Buccaneer Bowl',
      ];
    } else {
      choices = const [
        'Beacon Bowl',
        'Boardwalk Bowl',
        'Bayou Bowl',
        'Magnolia Bowl',
      ];
    }

    return choices[recordKey % choices.length];
  }

  bool get lowRecordConferenceChamp {
    return widget.conferenceChampEligible && widget.wins < 10;
  }
  String get destination {
    if (widget.conferenceChampEligible) return 'Conference Championship';
    if (widget.cfpEligible) return 'Kingdom Football Playoff';
    if (widget.bowlEligible) return selectedBowlName;
    return 'No Bowl';
  }
  String get nextPhase {
    if (widget.conferenceChampEligible) return 'confChamp';
    if (widget.cfpEligible) return 'cfp';
    if (widget.bowlEligible) return 'bowl';
    return 'offseason';
  }
  String get committeeMessage {
    if (widget.conferenceChampEligible) {
      if (lowRecordConferenceChamp) {
        return 'You reached the conference championship, but your overall record is not strong enough for the KP. Win or lose, your postseason path is a bowl game.';
      }
      return 'The committee is watching your championship game. You still need an elite record and ranking to make the KP.';
    }
    if (widget.cfpEligible) {
      return 'Your record and ranking were strong enough. You are officially in the Kingdom Football Playoff.';
    }
    if (widget.bowlEligible) {
      return 'You missed the KP, but your record earned an invitation to the $selectedBowlName.';
    }
    return 'You were left out because you did not reach six wins. You are not bowl eligible.';
  }


  @override
  Widget build(BuildContext context) {
    final showResult = revealStep >= 2;

    return Scaffold(
      backgroundColor: kDark,
      appBar: AppBar(title: const AppTitle('Postseason Reveal')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('POSTSEASON SELECTION SHOW', textAlign: TextAlign.center, style: TextStyle(color: GKColors.parchmentWhite, fontSize: 32, fontWeight: FontWeight.w900, letterSpacing: 4)),
          const SizedBox(height: 10),
          Text('Conference officials, bowl committees, and the KP committee are reviewing your season...', textAlign: TextAlign.center, style: TextStyle(color: GKColors.fadedInk, fontWeight: FontWeight.bold)),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(color: kCardColor, border: Border.all(color: kBorder), borderRadius: BorderRadius.circular(24)),
            child: Column(
              children: [
                Text(widget.team.fullName.toUpperCase(), style: const TextStyle(color: kGold, fontSize: 28, fontWeight: FontWeight.w900, letterSpacing: 2)),
                const SizedBox(height: 18),
                Row(children: [
                  Expanded(child: _stat(widget.record, 'RECORD')),
                  Expanded(child: _stat('${widget.confWins}-${widget.confLosses}', 'CONF')),
                  Expanded(child: _stat('#${widget.rank}', 'RANK')),
                  Expanded(child: _stat('${widget.teamOvr}', 'Overall')),
                ]),
                const Divider(color: kBorder, height: 34),
                if (revealStep == 0)
                  Text('Committee Discussion...', style: TextStyle(color: GKColors.fadedInk, fontSize: 24, fontWeight: FontWeight.w900))
                else if (revealStep == 1)
                  Text('Final Envelope Is In...', style: TextStyle(color: kGold, fontSize: 24, fontWeight: FontWeight.w900))
                else
                  Text(destination.toUpperCase(), textAlign: TextAlign.center, style: TextStyle(color: destination == 'No Bowl' ? kRed : kGold, fontSize: 26, fontWeight: FontWeight.w900, letterSpacing: 2)),
                const SizedBox(height: 14),
                if (showResult) Text(committeeMessage, textAlign: TextAlign.center, style: const TextStyle(color: GKColors.parchmentWhite, height: 1.4, fontSize: 16)),
              ],
            ),
          ),
          const SizedBox(height: 24),
          if (showResult && widget.cfpEligible) _cfpSeeds(),
          if (showResult && widget.bowlEligible && !widget.cfpEligible && !widget.conferenceChampEligible) _bowlCard(),
          if (showResult && lowRecordConferenceChamp) _bowlCard(note: 'Projected bowl if your record keeps you out of the KP after the conference championship.'),
          if (showResult && !widget.bowlEligible && !widget.cfpEligible && !widget.conferenceChampEligible) _noBowlCard(),
          const SizedBox(height: 24),
          DynastyButton(
            text: showResult ? 'Continue' : 'Reveal',
            onPressed: () {
              if (!showResult) {
                setState(() => revealStep++);
              } else {
                widget.onContinue(
                  SelectionResult(
                    nextPhase,
                    bowlName: nextPhase == 'bowl'
                        ? selectedBowlName
                        : null,
                  ),
                );
                Navigator.of(context).pop();
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _stat(String value, String label) {
    return Column(children: [
      Text(value, style: const TextStyle(color: GKColors.parchmentWhite, fontSize: 23, fontWeight: FontWeight.w900)),
      const SizedBox(height: 4),
      Text(label, style: const TextStyle(color: GKColors.fadedInk, fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 1.5)),
    ]);
  }

  List<CollegeTeam> _topTwelve() {
    final teams = g5Teams.toList();
    teams.sort((a, b) {
      final ar = widget.teamRecords[a.name] ?? TeamSeasonRecord();
      final br = widget.teamRecords[b.name] ?? TeamSeasonRecord();

      final pct = br.winPct.compareTo(ar.winPct);
      if (pct != 0) return pct;

      final wins = br.wins.compareTo(ar.wins);
      if (wins != 0) return wins;

      final prestige = b.prestige.compareTo(a.prestige);
      if (prestige != 0) return prestige;

      return a.name.compareTo(b.name);
    });

    return teams.take(12).toList();
  }

  Widget _cfpSeeds() {
    final seeds = _topTwelve();

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(color: kCardColor, border: Border.all(color: kBorder), borderRadius: BorderRadius.circular(22)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('PROJECTED 12-TEAM KP', style: TextStyle(color: kGold, fontWeight: FontWeight.w900, letterSpacing: 3)),
        const SizedBox(height: 14),
        ...List.generate(seeds.length, (i) {
          final seedTeam = seeds[i];
          final isUser = seedTeam.name == widget.team.name;
          final rec = widget.teamRecords[seedTeam.name]?.overallText ?? '0-0';
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              children: [
                SizedBox(
                  width: 34,
                  child: Text('${i + 1}.', style: const TextStyle(color: kGold, fontWeight: FontWeight.w900)),
                ),
                GKTeamBadge(team: seedTeam, size: 30),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    seedTeam.name,
                    style: TextStyle(color: isUser ? kGold : GKColors.parchmentWhite, fontWeight: FontWeight.w900),
                  ),
                ),
                Text(rec, style: const TextStyle(color: GKColors.fadedInk, fontWeight: FontWeight.bold)),
                if (i < 4) Text('  BYE', style: TextStyle(color: kGreen, fontWeight: FontWeight.w900)),
              ],
            ),
          );
        }),
      ]),
    );
  }

  Widget _bowlCard({String? note}) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(color: kGold.withOpacity(.08), border: Border.all(color: kGold.withOpacity(.4)), borderRadius: BorderRadius.circular(22)),
      child: Text('BOWL INVITE: $selectedBowlName\n${note ?? 'Your record earned this bowl slot based on your season resume.'}', style: const TextStyle(color: GKColors.parchmentWhite, height: 1.4, fontWeight: FontWeight.bold)),
    );
  }

  Widget _noBowlCard() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(color: kRed.withOpacity(.08), border: Border.all(color: kRed.withOpacity(.4)), borderRadius: BorderRadius.circular(22)),
      child: Text('NO BOWL INVITE\nYou need at least 6 wins to become bowl eligible.', style: TextStyle(color: GKColors.parchmentWhite, height: 1.4, fontWeight: FontWeight.bold)),
    );
  }
}

class ScheduleScreen extends StatelessWidget {
  final CollegeTeam team;
  final List<CollegeTeam> schedule;
  final int gamesPlayed;

  const ScheduleScreen({super.key, required this.team, required this.schedule, required this.gamesPlayed});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kDark,
      appBar: AppBar(title: const AppTitle('Schedule')),
      body: ListView.builder(
        padding: const EdgeInsets.all(18),
        itemCount: schedule.length,
        itemBuilder: (context, index) {
          final opp = schedule[index];
          final played = index < gamesPlayed;
          return Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: kCardColor, border: Border.all(color: kBorder), borderRadius: BorderRadius.circular(16)),
            child: Row(children: [
              Text('${index + 1}', style: const TextStyle(color: GKColors.fadedInk, fontSize: 22, fontWeight: FontWeight.w900)),
              const SizedBox(width: 16),
              Expanded(child: Text(opp.name, style: const TextStyle(color: GKColors.parchmentWhite, fontSize: 20, fontWeight: FontWeight.w900))),
              Text(played ? 'FINAL' : (index % 2 == 0 ? 'AWAY' : 'HOME'), style: TextStyle(color: played ? kGreen : kGold, fontWeight: FontWeight.w900)),
            ]),
          );
        },
      ),
    );
  }
}


class StandingsScreen extends StatelessWidget {
  final CollegeTeam team;
  final Map<String, TeamSeasonRecord> teamRecords;

  const StandingsScreen({
    super.key,
    required this.team,
    required this.teamRecords,
  });

  @override
  Widget build(BuildContext context) {
    final teams = g5Teams.where((t) => t.conference == team.conference).toList();

    teams.sort((a, b) {
      final ar = teamRecords[a.name] ?? TeamSeasonRecord();
      final br = teamRecords[b.name] ?? TeamSeasonRecord();

      final confPctA = (ar.confWins + ar.confLosses) == 0 ? 0 : ar.confWins / (ar.confWins + ar.confLosses);
      final confPctB = (br.confWins + br.confLosses) == 0 ? 0 : br.confWins / (br.confWins + br.confLosses);

      final confCompare = confPctB.compareTo(confPctA);
      if (confCompare != 0) return confCompare;

      return br.wins.compareTo(ar.wins);
    });

    return Scaffold(
      backgroundColor: kDark,
      appBar: AppBar(title: AppTitle('${team.conference} Standings')),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: teams.map((t) {
          final record = teamRecords[t.name] ?? TeamSeasonRecord();
          return _row(t, record, t.name == team.name);
        }).toList(),
      ),
    );
  }

  Widget _row(CollegeTeam t, TeamSeasonRecord record, bool user) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: user ? kGold.withOpacity(.15) : kCardColor,
        border: Border.all(color: user ? kGold : kBorder),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(children: [
        GKTeamBadge(team: t, size: 38),
        const SizedBox(width: 12),
        Expanded(child: Text(t.name, style: TextStyle(color: user ? kGold : GKColors.parchmentWhite, fontSize: 18, fontWeight: FontWeight.w900))),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(record.confText, style: const TextStyle(color: GKColors.parchmentWhite, fontWeight: FontWeight.w900)),
            Text(record.overallText, style: const TextStyle(color: GKColors.fadedInk, fontWeight: FontWeight.w900)),
          ],
        ),
      ]),
    );
  }
}


class KingdomNetworkScreen extends StatefulWidget {
  final CollegeTeam team;
  final int season;
  final int rank;
  final String record;
  final Map<String, TeamSeasonRecord> teamRecords;
  final List<Player> roster;
  final List<TrophyEntry> trophies;
  final List<NationalTitleHistoryEntry> history;

  const KingdomNetworkScreen({
    super.key,
    required this.team,
    required this.season,
    required this.rank,
    required this.record,
    required this.teamRecords,
    required this.roster,
    required this.trophies,
    required this.history,
  });

  @override
  State<KingdomNetworkScreen> createState() => _KingdomNetworkScreenState();
}

class _KingdomNetworkScreenState extends State<KingdomNetworkScreen> {
  int channel = 0;

  static const _channels = [
    'WIRE',
    'POLL',
    'HEISMAN',
    'CAROUSEL',
    'LEGACY',
    'ARCHIVE',
  ];

  List<CollegeTeam> get _rankedTeams {
    final ranked = g5Teams.toList();
    ranked.sort((a, b) {
      final ar = widget.teamRecords[a.name] ?? TeamSeasonRecord();
      final br = widget.teamRecords[b.name] ?? TeamSeasonRecord();
      final pct = br.winPct.compareTo(ar.winPct);
      if (pct != 0) return pct;
      final wins = br.wins.compareTo(ar.wins);
      if (wins != 0) return wins;
      final prestige = b.prestige.compareTo(a.prestige);
      if (prestige != 0) return prestige;
      return a.name.compareTo(b.name);
    });
    return ranked;
  }

  List<Player> get _awardPool {
    final players = widget.roster.toList();
    if (players.isEmpty) {
      return const [
        Player(
          name: 'National Leader',
          position: 'QB',
          overall: 88,
          potential: 92,
          year: 'JR',
          stars: 4,
        ),
      ];
    }
    players.sort((a, b) => awardOverall(b).compareTo(awardOverall(a)));
    return players;
  }

  int get _userPollRank {
    final index = _rankedTeams.indexWhere((team) => team.name == widget.team.name);
    return index == -1 ? widget.rank : index + 1;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: GKColors.midnight,
      body: GKBackground(
        child: SafeArea(
          child: Column(
            children: [
              _networkHeader(context),
              _breakingTicker(),
              _channelRail(),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 260),
                  child: KeyedSubtree(
                    key: ValueKey(channel),
                    child: _channelBody(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _networkHeader(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(
        GKSpace.sm,
        GKSpace.sm,
        GKSpace.md,
        GKSpace.md,
      ),
      decoration: const BoxDecoration(
        color: GKColors.broadcastNavy,
        border: Border(
          bottom: BorderSide(color: GKColors.divider),
        ),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(
              Icons.arrow_back_rounded,
              color: GKColors.warmWhite,
            ),
          ),
          Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: GKColors.kingdomGold.withOpacity(.14),
              border: Border.all(color: GKColors.kingdomGold),
            ),
            child: const Icon(
              Icons.public_rounded,
              color: GKColors.kingdomGold,
            ),
          ),
          const SizedBox(width: GKSpace.sm),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'KINGDOM NETWORK',
                  style: TextStyle(
                    color: GKColors.warmWhite,
                    fontSize: 19,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 2.2,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'THE NATIONAL COLLEGE FOOTBALL DESK',
                  style: TextStyle(
                    color: GKColors.mutedSilver,
                    fontSize: 9,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.5,
                  ),
                ),
              ],
            ),
          ),
          Text(
            'Y${widget.season}',
            style: const TextStyle(
              color: GKColors.kingdomGold,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  Widget _breakingTicker() {
    final ranked = _rankedTeams;
    final leader = ranked.isEmpty ? widget.team : ranked.first;
    final userRank = _userPollRank;
    final message = userRank <= 25
        ? '${widget.team.displayName} sits at #$userRank as the national race tightens.'
        : '${leader.displayName} controls the top spot while ${widget.team.displayName} chases the poll.';

    return Container(
      height: 38,
      color: GKColors.alertRed,
      child: Row(
        children: [
          Container(
            height: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: GKSpace.sm),
            alignment: Alignment.center,
            color: Colors.black.withOpacity(.22),
            child: Text(
              'BREAKING',
              style: TextStyle(
                color: GKColors.parchmentWhite,
                fontSize: 10,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.5,
              ),
            ),
          ),
          const SizedBox(width: GKSpace.sm),
          Expanded(
            child: Text(
              message,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: GKColors.parchmentWhite,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: GKSpace.sm),
            child: Icon(
              Icons.chevron_right_rounded,
              color: GKColors.parchmentWhite,
              size: 18,
            ),
          ),
        ],
      ),
    );
  }

  Widget _channelRail() {
    return Container(
      height: 50,
      decoration: const BoxDecoration(
        color: GKColors.midnight,
        border: Border(
          bottom: BorderSide(color: GKColors.divider),
        ),
      ),
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: GKSpace.sm),
        scrollDirection: Axis.horizontal,
        itemCount: _channels.length,
        separatorBuilder: (_, _unused) => const SizedBox(width: GKSpace.xs),
        itemBuilder: (context, index) {
          final selected = channel == index;
          return TextButton(
            onPressed: () => setState(() => channel = index),
            style: TextButton.styleFrom(
              foregroundColor: selected
                  ? GKColors.kingdomGold
                  : GKColors.mutedSilver,
              padding: const EdgeInsets.symmetric(horizontal: GKSpace.sm),
              shape: const RoundedRectangleBorder(),
              side: BorderSide(
                color: selected
                    ? GKColors.kingdomGold
                    : Colors.transparent,
                width: 0,
              ),
            ),
            child: Text(
              _channels[index],
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.4,
                decoration: selected
                    ? TextDecoration.underline
                    : TextDecoration.none,
                decorationThickness: 3,
                decorationColor: GKColors.kingdomGold,
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _channelBody() {
    return switch (channel) {
      0 => _wireChannel(),
      1 => _pollChannel(),
      2 => _heismanChannel(),
      3 => _carouselChannel(),
      4 => _legacyChannel(),
      _ => _archiveChannel(),
    };
  }

  Widget _channelScaffold({
    required String eyebrow,
    required String title,
    required String subtitle,
    required List<Widget> children,
  }) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        GKSpace.md,
        GKSpace.lg,
        GKSpace.md,
        GKSpace.xxl,
      ),
      children: [
        Text(
          eyebrow,
          style: GKText.sectionLabel,
        ),
        const SizedBox(height: GKSpace.xs),
        Text(
          title,
          style: GKText.pageTitle,
        ),
        const SizedBox(height: GKSpace.xs),
        Text(
          subtitle,
          style: GKText.body,
        ),
        const SizedBox(height: GKSpace.xl),
        ...children,
      ],
    );
  }

  Widget _wireChannel() {
    final ranked = _rankedTeams;
    final stories = <Map<String, String>>[];

    if (ranked.isNotEmpty) {
      final leader = ranked.first;
      final leaderRecord =
          widget.teamRecords[leader.name] ?? TeamSeasonRecord();
      stories.add({
        'tag': 'NATIONAL',
        'headline': '${leader.displayName} owns the No. 1 position',
        'detail':
            '${leaderRecord.overallText} record keeps the pressure on every contender.',
      });
    }

    stories.add({
      'tag': 'YOUR PROGRAM',
      'headline':
          '${widget.team.displayName} enters the week ${widget.record}',
      'detail': _userPollRank <= 25
          ? 'The program is ranked #$_userPollRank and carrying national expectations.'
          : 'The program remains outside the Top 25 with room to force its way into the conversation.',
    });

    final surprise = ranked.length > 8 ? ranked[8] : widget.team;
    stories.add({
      'tag': 'STOCK RISING',
      'headline': '${surprise.displayName} is building momentum',
      'detail':
          'A strong stretch has turned a quiet season into a national storyline.',
    });

    final hotSeat = g5Teams
        .where((team) => team.name != widget.team.name)
        .toList()
      ..sort((a, b) {
        final ar = widget.teamRecords[a.name] ?? TeamSeasonRecord();
        final br = widget.teamRecords[b.name] ?? TeamSeasonRecord();
        return ar.winPct.compareTo(br.winPct);
      });

    if (hotSeat.isNotEmpty) {
      stories.add({
        'tag': 'HOT SEAT',
        'headline':
            'Pressure grows around ${hotSeat.first.displayName}',
        'detail':
            'Sources say the next two weeks could decide the direction of the program.',
      });
    }

    return _channelScaffold(
      eyebrow: 'KINGDOM WIRE',
      title: 'The sport never stops moving.',
      subtitle:
          'National headlines, program pressure, recruiting noise, and the stories shaping the season.',
      children: [
        ...stories.asMap().entries.map((entry) {
          final featured = entry.key == 0;
          final story = entry.value;
          return _storyStrip(
            tag: story['tag']!,
            headline: story['headline']!,
            detail: story['detail']!,
            featured: featured,
          );
        }),
      ],
    );
  }

  Widget _storyStrip({
    required String tag,
    required String headline,
    required String detail,
    bool featured = false,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: GKSpace.md),
      padding: EdgeInsets.all(featured ? GKSpace.lg : GKSpace.md),
      decoration: BoxDecoration(
        color: featured
            ? GKColors.elevatedPanel
            : GKColors.panel.withOpacity(.78),
        border: Border(
          left: BorderSide(
            color: featured
                ? GKColors.kingdomGold
                : GKColors.crownBlue,
            width: featured ? 5 : 3,
          ),
          bottom: const BorderSide(color: GKColors.divider),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tag,
            style: TextStyle(
              color: featured
                  ? GKColors.kingdomGold
                  : GKColors.crownBlue,
              fontSize: 10,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.6,
            ),
          ),
          const SizedBox(height: GKSpace.xs),
          Text(
            headline,
            style: TextStyle(
              color: GKColors.warmWhite,
              fontSize: featured ? 23 : 17,
              fontWeight: FontWeight.w900,
              height: 1.08,
            ),
          ),
          const SizedBox(height: GKSpace.xs),
          Text(
            detail,
            style: GKText.body.copyWith(fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _pollChannel() {
    final ranked = _rankedTeams.take(25).toList();
    return _channelScaffold(
      eyebrow: 'KINGDOM POLL SHOW',
      title: 'Top 25 Reveal',
      subtitle:
          'The national order, movement indicators, and your place in the playoff race.',
      children: [
        ...ranked.asMap().entries.map((entry) {
          final index = entry.key;
          final team = entry.value;
          final rec = widget.teamRecords[team.name] ?? TeamSeasonRecord();
          final isUser = team.name == widget.team.name;
          final movementSeed =
              (team.name.hashCode.abs() + widget.season + rec.wins) % 5;
          final movement = movementSeed == 0
              ? 'NEW'
              : movementSeed == 1
                  ? '▲${1 + (team.name.hashCode.abs() % 4)}'
                  : movementSeed == 2
                      ? '▼${1 + (team.name.hashCode.abs() % 3)}'
                      : '—';

          return Container(
            margin: const EdgeInsets.only(bottom: 2),
            padding: const EdgeInsets.symmetric(
              horizontal: GKSpace.md,
              vertical: GKSpace.sm,
            ),
            color: isUser
                ? widget.team.primary.withOpacity(.18)
                : index < 4
                    ? GKColors.elevatedPanel
                    : GKColors.panel.withOpacity(.72),
            child: Row(
              children: [
                SizedBox(
                  width: 42,
                  child: Text(
                    '${index + 1}',
                    style: TextStyle(
                      color: index < 4
                          ? GKColors.kingdomGold
                          : GKColors.mutedSilver,
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                GKTeamBadge(team: team, size: 32),
                const SizedBox(width: GKSpace.sm),
                Expanded(
                  child: Text(
                    team.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isUser
                          ? widget.team.primary
                          : GKColors.warmWhite,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                Text(
                  movement,
                  style: TextStyle(
                    color: movement.startsWith('▲') ||
                            movement == 'NEW'
                        ? GKColors.victoryGreen
                        : movement.startsWith('▼')
                            ? GKColors.alertRed
                            : GKColors.mutedSilver,
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(width: GKSpace.sm),
                SizedBox(
                  width: 38,
                  child: Text(
                    rec.overallText,
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      color: GKColors.mutedSilver,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }

  Widget _heismanChannel() {
    final pool = _awardPool.take(5).toList();
    return _channelScaffold(
      eyebrow: 'HEISMAN STUDIO',
      title: 'The five names defining the season.',
      subtitle:
          'Production, team success, position value, and national momentum shape the weekly board.',
      children: [
        ...pool.asMap().entries.map((entry) {
          final index = entry.key;
          final player = entry.value;
          final score = (awardOverall(player) * .62 +
                  player.touchdowns * 1.7 +
                  player.teamWins * 1.2)
              .round();
          final odds = switch (index) {
            0 => '+175',
            1 => '+320',
            2 => '+550',
            3 => '+800',
            _ => '+1200',
          };

          return Container(
            margin: const EdgeInsets.only(bottom: GKSpace.md),
            padding: const EdgeInsets.all(GKSpace.md),
            decoration: BoxDecoration(
              color: index == 0
                  ? GKColors.kingdomGold.withOpacity(.12)
                  : GKColors.panel,
              border: Border(
                left: BorderSide(
                  color: index == 0
                      ? GKColors.kingdomGold
                      : GKColors.divider,
                  width: index == 0 ? 5 : 2,
                ),
                bottom: const BorderSide(color: GKColors.divider),
              ),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 34,
                  child: Text(
                    '${index + 1}',
                    style: TextStyle(
                      color: index == 0
                          ? GKColors.kingdomGold
                          : GKColors.mutedSilver,
                      fontSize: 26,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                PlayerAvatar(
                  seed: player.name.hashCode,
                  teamColor: widget.team.primary,
                  size: 48,
                ),
                const SizedBox(width: GKSpace.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        player.cleanName,
                        style: GKText.cardTitle,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${player.position} · ${player.year} · ${player.awardTeamName}',
                        style: GKText.body.copyWith(fontSize: 11),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${player.touchdowns} TD · ${player.teamWins} team wins · score $score',
                        style: const TextStyle(
                          color: GKColors.mutedSilver,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  odds,
                  style: const TextStyle(
                    color: GKColors.kingdomGold,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }

  Widget _carouselChannel() {
    final openings = g5Teams
        .where((team) => team.name != widget.team.name)
        .toList()
      ..sort((a, b) {
        final ar = widget.teamRecords[a.name] ?? TeamSeasonRecord();
        final br = widget.teamRecords[b.name] ?? TeamSeasonRecord();
        return ar.winPct.compareTo(br.winPct);
      });

    final candidates = openings.take(5).toList();

    return _channelScaffold(
      eyebrow: 'COACHING CAROUSEL',
      title: 'Rumors become interviews. Interviews become offers.',
      subtitle:
          'Open jobs, pressure points, and the national market surrounding your career.',
      children: [
        ...candidates.asMap().entries.map((entry) {
          final index = entry.key;
          final school = entry.value;
          final rec =
              widget.teamRecords[school.name] ?? TeamSeasonRecord();
          final status = switch (index) {
            0 => 'SEARCH OPEN',
            1 => 'INTERVIEWS',
            2 => 'RUMORED OPENING',
            3 => 'COACH ON HOT SEAT',
            _ => 'MONITORING',
          };
          final userMention = index < 2 &&
              (widget.record.startsWith('1') ||
                  widget.rank > 0 && widget.rank <= 25);

          return Container(
            margin: const EdgeInsets.only(bottom: GKSpace.md),
            padding: const EdgeInsets.all(GKSpace.md),
            decoration: const BoxDecoration(
              color: GKColors.panel,
              border: Border(
                bottom: BorderSide(color: GKColors.divider),
              ),
            ),
            child: Row(
              children: [
                GKTeamBadge(team: school, size: 46),
                const SizedBox(width: GKSpace.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        school.displayName,
                        style: GKText.cardTitle,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '$status · ${rec.overallText}',
                        style: const TextStyle(
                          color: GKColors.alertRed,
                          fontSize: 10,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 1,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        userMention
                            ? 'League sources have connected ${widget.coachNameFallback} to the search.'
                            : 'The administration is evaluating fit, cost, and program direction.',
                        style: GKText.body.copyWith(fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }

  Widget _legacyChannel() {
    final titles = widget.history
        .where((entry) => entry.winner == widget.team.name)
        .length;
    final conferenceTitles = widget.trophies
        .where((entry) =>
            entry.type.toLowerCase().contains('conference'))
        .length;
    final bowlWins = widget.trophies
        .where((entry) => entry.type.toLowerCase().contains('bowl'))
        .length;
    final prestige = prestige100(widget.team.prestige);
    final int legendScore = (prestige +
            titles * 12 +
            conferenceTitles * 6 +
            bowlWins * 3 +
            max(0, 26 - _userPollRank))
        .clamp(0, 999)
        .toInt();

    final int fanHappiness =
        (55 + max(0, 25 - _userPollRank) + titles * 8)
            .clamp(0, 100)
            .toInt();
    final int boosterConfidence =
        (prestige - 5 + conferenceTitles * 4)
            .clamp(0, 100)
            .toInt();
    final int nationalRespect =
        (prestige + max(0, 26 - _userPollRank))
            .clamp(0, 100)
            .toInt();
    final int recruitBuzz =
        (prestige - 8 + max(0, 20 - _userPollRank))
            .clamp(0, 100)
            .toInt();

    return _channelScaffold(
      eyebrow: 'PROGRAM LEGACY',
      title: widget.team.displayName,
      subtitle:
          'The program is measured by what it wins, what it builds, and what the sport remembers.',
      children: [
        Container(
          padding: const EdgeInsets.all(GKSpace.lg),
          decoration: BoxDecoration(
            color: widget.team.primary.withOpacity(.14),
            border: Border(
              left: BorderSide(color: widget.team.primary, width: 5),
              bottom: const BorderSide(color: GKColors.divider),
            ),
          ),
          child: Row(
            children: [
              GKTeamBadge(team: widget.team, size: 78),
              const SizedBox(width: GKSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'LEGEND SCORE',
                      style: TextStyle(
                        color: GKColors.mutedSilver,
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.6,
                      ),
                    ),
                    Text(
                      '$legendScore',
                      style: TextStyle(
                        color: widget.team.primary,
                        fontSize: 42,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                prestigeLabel(widget.team.prestige).toUpperCase(),
                style: const TextStyle(
                  color: GKColors.kingdomGold,
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: GKSpace.lg),
        _legacyMetric('NATIONAL TITLES', '$titles'),
        _legacyMetric('CONFERENCE TITLES', '$conferenceTitles'),
        _legacyMetric('BOWL WINS', '$bowlWins'),
        _legacyMetric('CURRENT POLL POSITION',
            _userPollRank <= 25 ? '#$_userPollRank' : 'UNRANKED'),
        const SizedBox(height: GKSpace.xl),
        Text(
          'PROGRAM PULSE',
          style: GKText.sectionLabel,
        ),
        const SizedBox(height: GKSpace.md),
        _pulseBar('Fan Happiness', fanHappiness),
        _pulseBar('Booster Confidence', boosterConfidence),
        _pulseBar('National Respect', nationalRespect),
        _pulseBar('Recruit Buzz', recruitBuzz),
      ],
    );
  }

  Widget _legacyMetric(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: GKSpace.md,
        vertical: GKSpace.sm,
      ),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: GKColors.divider),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                color: GKColors.mutedSilver,
                fontSize: 11,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.1,
              ),
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              color: GKColors.warmWhite,
              fontSize: 18,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }

  Widget _pulseBar(String label, int value) {
    final color = value >= 75
        ? GKColors.victoryGreen
        : value >= 50
            ? GKColors.kingdomGold
            : GKColors.alertRed;
    return Padding(
      padding: const EdgeInsets.only(bottom: GKSpace.md),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    color: GKColors.warmWhite,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Text(
                '$value',
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          const SizedBox(height: GKSpace.xs),
          ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(
              value: value / 100,
              minHeight: 8,
              backgroundColor: GKColors.divider,
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
        ],
      ),
    );
  }

  Widget _archiveChannel() {
    final sorted = widget.history.toList()
      ..sort((a, b) => b.year.compareTo(a.year));

    return _channelScaffold(
      eyebrow: 'HISTORICAL ARCHIVE',
      title: 'Every season leaves evidence.',
      subtitle:
          'Champions, defining games, and the timeline your dynasty creates over time.',
      children: [
        if (sorted.isEmpty)
          Container(
            padding: const EdgeInsets.all(GKSpace.lg),
            decoration: const BoxDecoration(
              color: GKColors.panel,
              border: Border(
                left: BorderSide(
                  color: GKColors.kingdomGold,
                  width: 4,
                ),
              ),
            ),
            child: Text(
              'No completed national championship seasons are in the archive yet.',
              style: GKText.body,
            ),
          )
        else
          ...sorted.map((entry) {
            return Container(
              margin: const EdgeInsets.only(bottom: GKSpace.md),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 58,
                    child: Text(
                      'Y${entry.year}',
                      style: const TextStyle(
                        color: GKColors.kingdomGold,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  Container(
                    width: 12,
                    height: 12,
                    margin: const EdgeInsets.only(top: 4),
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: GKColors.kingdomGold,
                    ),
                  ),
                  const SizedBox(width: GKSpace.sm),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.only(
                        bottom: GKSpace.md,
                      ),
                      decoration: const BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            color: GKColors.divider,
                          ),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment:
                            CrossAxisAlignment.start,
                        children: [
                          Text(
                            entry.winner,
                            style: GKText.cardTitle,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'National Champion · def. ${entry.loser} ${entry.score}',
                            style: GKText.body.copyWith(
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            );
          }),
      ],
    );
  }
}

extension _KingdomNetworkCoachFallback on KingdomNetworkScreen {
  String get coachNameFallback => 'your coaching staff';
}

class RankingsScreen extends StatelessWidget {
  final CollegeTeam team;
  final int rank;
  final String record;
  final Map<String, TeamSeasonRecord> teamRecords;

  const RankingsScreen({
    super.key,
    required this.team,
    required this.rank,
    required this.record,
    required this.teamRecords,
  });

  List<CollegeTeam> _rankedTeams() {
    final ranked = g5Teams.toList();

    ranked.sort((a, b) {
      final ar = teamRecords[a.name] ?? TeamSeasonRecord();
      final br = teamRecords[b.name] ?? TeamSeasonRecord();

      final pct = br.winPct.compareTo(ar.winPct);
      if (pct != 0) return pct;

      final wins = br.wins.compareTo(ar.wins);
      if (wins != 0) return wins;

      final prestige = b.prestige.compareTo(a.prestige);
      if (prestige != 0) return prestige;

      return a.name.compareTo(b.name);
    });

    return ranked;
  }

  @override
  Widget build(BuildContext context) {
    final ranked = _rankedTeams();

    return Scaffold(
      backgroundColor: kDark,
      appBar: AppBar(title: const AppTitle('Rankings')),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: List.generate(min(25, ranked.length), (i) {
          final rankedTeam = ranked[i];
          final rec = teamRecords[rankedTeam.name] ?? TeamSeasonRecord();
          return _rankRow(i + 1, rankedTeam, rec, rankedTeam.name == team.name);
        }),
      ),
    );
  }

  Widget _rankRow(int r, CollegeTeam rankedTeam, TeamSeasonRecord rec, bool user) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: user ? kGold.withOpacity(.16) : kCardColor, border: Border.all(color: user ? kGold : kBorder), borderRadius: BorderRadius.circular(14)),
      child: Row(children: [
        SizedBox(width: 45, child: Text('#$r', style: const TextStyle(color: kGold, fontSize: 18, fontWeight: FontWeight.w900))),
        GKTeamBadge(team: rankedTeam, size: 34),
        const SizedBox(width: 10),
        Expanded(child: Text(rankedTeam.name, style: TextStyle(color: user ? kGold : GKColors.parchmentWhite, fontWeight: FontWeight.w900))),
        Text(rec.overallText, style: const TextStyle(color: GKColors.fadedInk, fontWeight: FontWeight.w900)),
      ]),
    );
  }
}

class CfpPredictionsScreen extends StatelessWidget {
  final CollegeTeam team;
  final int rank;
  final String record;
  final bool cfpEligible;
  final Map<String, TeamSeasonRecord> teamRecords;

  const CfpPredictionsScreen({
    super.key,
    required this.team,
    required this.rank,
    required this.record,
    required this.cfpEligible,
    required this.teamRecords,
  });

  List<CollegeTeam> _topTwelve() {
    final ranked = g5Teams.toList();

    ranked.sort((a, b) {
      final ar = teamRecords[a.name] ?? TeamSeasonRecord();
      final br = teamRecords[b.name] ?? TeamSeasonRecord();

      final pct = br.winPct.compareTo(ar.winPct);
      if (pct != 0) return pct;

      final wins = br.wins.compareTo(ar.wins);
      if (wins != 0) return wins;

      final prestige = b.prestige.compareTo(a.prestige);
      if (prestige != 0) return prestige;

      return a.name.compareTo(b.name);
    });

    return ranked.take(12).toList();
  }

  @override
  Widget build(BuildContext context) {
    final seeds = _topTwelve();
    final userIn = seeds.any((t) => t.name == team.name);

    return Scaffold(
      backgroundColor: kDark,
      appBar: AppBar(title: const AppTitle('KP Predictions')),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          Text(userIn ? 'CURRENTLY IN' : 'OUTSIDE LOOKING IN', style: TextStyle(color: userIn ? kGold : kRed, fontSize: 30, fontWeight: FontWeight.w900, letterSpacing: 3)),
          const SizedBox(height: 10),
          Text('${team.name} · $record · Rank #$rank', style: const TextStyle(color: GKColors.parchmentWhite, fontWeight: FontWeight.bold)),
          const SizedBox(height: 22),
          DynastyButton(
            text: 'View KP Bracket',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => CFPBracketScreen(
                    seeds: seeds,
                    teamRecords: teamRecords,
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 18),
          ...List.generate(seeds.length, (i) {
            final seedTeam = seeds[i];
            final rec = teamRecords[seedTeam.name] ?? TeamSeasonRecord();
            final isUser = seedTeam.name == team.name;
            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: isUser ? kGold.withOpacity(.16) : kCardColor, border: Border.all(color: isUser ? kGold : kBorder), borderRadius: BorderRadius.circular(14)),
              child: Row(children: [
                Text('${i + 1}', style: const TextStyle(color: kGold, fontSize: 20, fontWeight: FontWeight.w900)),
                const SizedBox(width: 14),
                GKTeamBadge(team: seedTeam, size: 34),
                const SizedBox(width: 10),
                Expanded(child: Text(rankedDisplayName(seedTeam, i + 1), style: const TextStyle(color: GKColors.parchmentWhite, fontWeight: FontWeight.w900))),
                Text(rec.overallText, style: const TextStyle(color: GKColors.fadedInk, fontWeight: FontWeight.bold)),
                if (i < 4) Text('  BYE', style: TextStyle(color: kGreen, fontWeight: FontWeight.w900)),
              ]),
            );
          }),
        ],
      ),
    );
  }
}


class CFPBracketScreen extends StatelessWidget {
  final List<CollegeTeam> seeds;
  final Map<String, TeamSeasonRecord> teamRecords;

  const CFPBracketScreen({
    super.key,
    required this.seeds,
    required this.teamRecords,
  });

  String _seedLabel(int index) {
    if (index >= seeds.length) return 'TBD';
    final team = seeds[index];
    final rank = index + 1;
    final record = teamRecords[team.name]?.overallText ?? '0-0';
    return '${rank}. ${rankedDisplayName(team, rank)} • $record';
  }

  Widget _seedCard(String text, {bool bye = false}) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: bye ? kGold.withOpacity(.18) : kCardColor,
        border: Border.all(color: bye ? kGold : kBorder),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: bye ? kGold : GKColors.parchmentWhite,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }

  Widget _gameCard(String title, String top, String bottom) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: kCardColor,
        border: Border.all(color: kBorder),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title.toUpperCase(), style: const TextStyle(color: kGold, fontWeight: FontWeight.w900, letterSpacing: 2)),
          const SizedBox(height: 10),
          Text(top, style: const TextStyle(color: GKColors.parchmentWhite, fontWeight: FontWeight.w900)),
          const SizedBox(height: 6),
          Text('vs', style: TextStyle(color: GKColors.fadedInk, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Text(bottom, style: const TextStyle(color: GKColors.parchmentWhite, fontWeight: FontWeight.w900)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kDark,
      appBar: AppBar(title: const AppTitle('KP Bracket')),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          Text('12-TEAM KP BRACKET', style: TextStyle(color: kGold, fontSize: 24, fontWeight: FontWeight.w900, letterSpacing: 3)),
          const SizedBox(height: 8),
          Text('The field contains the 12 best selected teams, with guaranteed bids for the SEC, Big Ten, ACC, and Big 12 champions. Seeds 1-4 receive a first-round bye.', style: TextStyle(color: GKColors.fadedInk, fontWeight: FontWeight.bold)),
          const SizedBox(height: 18),
          SectionCard(
            title: 'First Round Byes',
            child: Column(children: [
              _seedCard(_seedLabel(0), bye: true),
              _seedCard(_seedLabel(1), bye: true),
              _seedCard(_seedLabel(2), bye: true),
              _seedCard(_seedLabel(3), bye: true),
            ]),
          ),
          SectionCard(
            title: 'First Round',
            child: Column(children: [
              _gameCard('Heritage Bowl · KP First Round', _seedLabel(4), _seedLabel(11)),
              _gameCard('Coastline Bowl · KP First Round', _seedLabel(5), _seedLabel(10)),
              _gameCard('Mission Bowl · KP First Round', _seedLabel(6), _seedLabel(9)),
              _gameCard('Grove Bowl · KP First Round', _seedLabel(7), _seedLabel(8)),
            ]),
          ),
          SectionCard(
            title: 'Quarterfinals',
            child: Column(children: [
              _gameCard('Arroyo Bowl · KP Quarterfinal', _seedLabel(0), 'Winner of Grove Bowl'),
              _gameCard('Cane Bowl · KP Quarterfinal', _seedLabel(1), 'Winner of Mission Bowl'),
              _gameCard('Saguaro Bowl · KP Quarterfinal', _seedLabel(2), 'Winner of Coastline Bowl'),
              _gameCard('Orchard Bowl · KP Quarterfinal', _seedLabel(3), 'Winner of Heritage Bowl'),
            ]),
          ),
          SectionCard(
            title: 'Final Four',
            child: Column(children: [
              _gameCard('Sunshine Bowl · KP Semifinal', 'Arroyo Bowl Winner', 'Orchard Bowl Winner'),
              _gameCard('Prairie Bowl · KP Semifinal', 'Cane Bowl Winner', 'Saguaro Bowl Winner'),
              _gameCard('KP National Championship', 'Sunshine Bowl Winner', 'Prairie Bowl Winner'),
            ]),
          ),
        ],
      ),
    );
  }
}







final List<String> awardNationalSchools = [
  'Tuscaloosa', 'Athens-Clarke', 'Columbus', 'Ann Arbor', 'Austin', 'Eugene', 'University Park', 'South Bend',
  'State College', 'Baton Rouge', 'Tallahassee', 'Blue Ridge', 'Norman', 'Knoxville', 'Coral Gables',
  'Seattle', 'Salt Lake City', 'Yazoo', 'Chattahoochee', 'Madison', 'Westwood', 'Iowa City', 'Gainesville',
  'College Station', 'Manhattan', 'Derby City', 'Chapel Hill', 'Tucson', 'Boise',
  'Crescent City', 'Bluff City', 'Boone', 'Lynchburg', 'Fresno', 'San Diego'
];

String awardPlayerDisplayName(Player player) {
  if (player.name.contains('|')) {
    return player.name.split('|').first;
  }
  return player.cleanName;
}

String awardPlayerSchool(Player player) {
  if (player.name.contains('|')) {
    return player.name.split('|').last;
  }
  return 'Your Team';
}

int awardOverallCapped(Player player) {
  final raw = awardOverall(player);
  if (player.year == 'FR') return raw.clamp(45, 93);
  if (player.year == 'SO') return raw.clamp(45, 96);
  return raw.clamp(45, 99);
}

int realisticAwardScore(Player player) {
  final overall = awardOverallCapped(player);
  final posBoost = switch (player.position) {
    'QB' => 16,
    'HB' => 10,
    'WR' => 8,
    'TE' => 2,
    'DE' => 7,
    'LB' => 6,
    'DB' => 5,
    _ => 0,
  };

  final classBoost = switch (player.year) {
    'SR' => 8,
    'JR' => 6,
    'SO' => 3,
    _ => -5,
  };

  final teamWinEstimate = player.teamWins.clamp(0, 15);
  final statSeed = player.name.hashCode.abs() % 15;

  return (overall * 5 + teamWinEstimate * 4 + posBoost + classBoost + statSeed).round();
}

List<Player> realisticFullAllAmericanTeam(List<Player> players, {required Set<String> usedNames}) {
  final positionNeeds = <String, int>{
    'QB': 1,
    'HB': 1,
    'WR': 2,
    'TE': 1,
    'DE': 2,
    'LB': 2,
    'DB': 3,
  };

  final selected = <Player>[];

  for (final entry in positionNeeds.entries) {
    final candidates = players
        .where((p) => p.position == entry.key && !usedNames.contains(p.name))
        .toList()
      ..sort((a, b) => realisticAwardScore(b).compareTo(realisticAwardScore(a)));

    for (final player in candidates.take(entry.value)) {
      selected.add(player);
      usedNames.add(player.name);
    }
  }

  selected.sort((a, b) => realisticAwardScore(b).compareTo(realisticAwardScore(a)));
  return selected;
}






class SeasonAwardsCard extends StatelessWidget {
  final List<Player> roster;
  final int season;
  final int userWins;
  final String userTeamName;

  const SeasonAwardsCard({
    super.key,
    required this.roster,
    required this.season,
    required this.userWins,
    required this.userTeamName,
  });

  int _stableSeed(String value) {
    var hash = 17;
    for (final unit in value.codeUnits) {
      hash = ((hash * 31) + unit) & 0x7fffffff;
    }
    return hash;
  }

  String _seasonalPlayerName(int index, String school) {
    final firstIndex =
        (season * 47 + index * 13 + _stableSeed(school)) %
            NameGenerator.firstNames.length;
    final lastIndex =
        (season * 71 + index * 29 + _stableSeed('$school-$season')) %
            NameGenerator.lastNames.length;

    return '${NameGenerator.firstNames[firstIndex]} '
        '${NameGenerator.lastNames[lastIndex]}';
  }

  int _seasonWinsForSchool(String school) {
    if (school == userTeamName || school == 'Your Team') {
      return userWins.clamp(0, 15);
    }

    final team = g5Teams.firstWhere(
      (candidate) => candidate.name == school,
      orElse: () => const CollegeTeam(
        name: 'National Program',
        conference: 'Independent',
        prestige: 70,
        primary: Color(0xFF333333),
        secondary: GKColors.parchmentWhite,
      ),
    );

    final tier = prestigeTier(team.prestige);
    final random = Random(
      season * 100003 + _stableSeed(school) * 37,
    );

    final baseWins = switch (tier) {
      5 => 9,
      4 => 8,
      3 => 7,
      2 => 6,
      _ => 4,
    };

    final variation = random.nextInt(7) - 3;
    return (baseWins + variation).clamp(2, 12);
  }

  int _teamWinsForPlayer(Player player) {
    return _seasonWinsForSchool(awardPlayerSchool(player));
  }

  List<Player> _buildPool() {
    final list = <Player>[];

    // Use the actual user roster and this season's user record.
    for (final player in roster) {
      list.add(
        Player(
          name: '${player.cleanName}|$userTeamName',
          position: player.position,
          overall: player.overall,
          potential: player.potential,
          year: player.year,
          stars: player.stars,
        ),
      );
    }

    const positions = [
      'QB',
      'HB',
      'WR',
      'WR',
      'TE',
      'DE',
      'DE',
      'LB',
      'LB',
      'DB',
      'DB',
      'DB',
    ];
    const years = ['SO', 'JR', 'SR', 'JR', 'SR', 'SO', 'JR', 'SR'];

    var playerIndex = 0;

    for (final school in awardNationalSchools) {
      final teamWins = _seasonWinsForSchool(school);
      final team = g5Teams.firstWhere(
        (candidate) => candidate.name == school,
        orElse: () => const CollegeTeam(
          name: 'National Program',
          conference: 'Independent',
          prestige: 70,
          primary: Color(0xFF333333),
          secondary: GKColors.parchmentWhite,
          ),
      );
      final tier = prestigeTier(team.prestige);
      final seasonalRandom = Random(
        season * 200003 + _stableSeed(school) * 53,
      );

      // Better teams usually produce stronger award candidates, but every
      // season has enough variance for different teams and players to rise.
      for (var slot = 0; slot < positions.length; slot++) {
        final position = positions[slot];
        final year = years[(slot + season + seasonalRandom.nextInt(years.length)) %
            years.length];

        final teamStrength = switch (tier) {
          5 => 90,
          4 => 87,
          3 => 84,
          2 => 80,
          _ => 76,
        };

        final recordBoost = max(0, teamWins - 6) ~/ 2;
        final overall =
            (teamStrength + seasonalRandom.nextInt(8) - 3 + recordBoost)
                .clamp(72, 97);

        list.add(
          Player(
            name:
                '${_seasonalPlayerName(playerIndex, school)}|$school',
            position: position,
            year: year,
            overall: overall,
            potential: (overall + 1 + seasonalRandom.nextInt(4))
                .clamp(overall, 99),
            stars: overall >= 92
                ? 5
                : overall >= 84
                    ? 4
                    : 3,
          ),
        );

        playerIndex++;
      }

      // Freshmen are generated separately and remain capped at 93 OVR.
      for (var freshmanSlot = 0; freshmanSlot < 4; freshmanSlot++) {
        final position =
            positions[(freshmanSlot * 3 + season + tier) % positions.length];
        final freshmanOverall =
            (72 + tier * 3 + seasonalRandom.nextInt(9)).clamp(68, 93);

        list.add(
          Player(
            name:
                '${_seasonalPlayerName(playerIndex, school)}|$school',
            position: position,
            year: 'FR',
            overall: freshmanOverall,
            potential:
                (freshmanOverall + 3 + seasonalRandom.nextInt(5))
                    .clamp(freshmanOverall, 98),
            stars: freshmanOverall >= 89
                ? 5
                : freshmanOverall >= 81
                    ? 4
                    : 3,
          ),
        );

        playerIndex++;
      }
    }

    final unique = <String, Player>{};
    for (final player in list) {
      unique[
          '${player.name}-${player.position}-${player.year}'] = player;
    }

    return unique.values.toList();
  }

  int _awardScore(Player player) {
    final overall = awardOverallCapped(player);
    final teamWins = _teamWinsForPlayer(player);

    final positionBonus = switch (player.position) {
      'QB' => 20,
      'HB' => 14,
      'WR' => 11,
      'TE' => 5,
      'DE' => 9,
      'LB' => 8,
      'DB' => 7,
      _ => 0,
    };

    final classBonus = switch (player.year) {
      'SR' => 7,
      'JR' => 6,
      'SO' => 3,
      _ => -5,
    };

    final seasonVariance = Random(
      season * 300007 + _stableSeed(player.name) * 19,
    ).nextInt(22);

    return overall * 6 +
        teamWins * 11 +
        positionBonus +
        classBonus +
        seasonVariance;
  }

  int _heismanScore(Player player) {
    final overall = awardOverallCapped(player);
    final teamWins = _teamWinsForPlayer(player);

    final offensiveProduction = switch (player.position) {
      'QB' => 32,
      'HB' => 25,
      'WR' => 20,
      'TE' => 8,
      _ => -35,
    };

    final recordBonus = teamWins >= 12
        ? 58
        : teamWins == 11
            ? 48
            : teamWins == 10
                ? 36
                : teamWins == 9
                    ? 22
                    : teamWins == 8
                        ? 10
                        : -18;

    final seasonalStats = Random(
      season * 400009 + _stableSeed(player.name) * 23,
    ).nextInt(42);

    return overall * 8 +
        recordBonus +
        offensiveProduction +
        seasonalStats;
  }

  Player _heismanWinner(List<Player> pool) {
    if (pool.isEmpty) {
      return const Player(name: 'No Player', position: 'QB', overall: 0, potential: 0, year: 'JR', stars: 1);
    }

    final candidates = pool.toList()
      ..sort((a, b) => _heismanScore(b).compareTo(_heismanScore(a)));

    return candidates.first;
  }

  List<Player> _allAmericanTeam(List<Player> pool, Set<String> usedNames) {
    final needs = <String, int>{
      'QB': 1,
      'HB': 1,
      'WR': 2,
      'TE': 1,
      'DE': 2,
      'LB': 2,
      'DB': 3,
    };

    final selected = <Player>[];

    for (final entry in needs.entries) {
      final candidates = pool
          .where((p) => p.position == entry.key && !usedNames.contains(p.name))
          .toList()
        ..sort((a, b) => _awardScore(b).compareTo(_awardScore(a)));

      for (final player in candidates.take(entry.value)) {
        selected.add(player);
        usedNames.add(player.name);
      }
    }

    selected.sort((a, b) => _awardScore(b).compareTo(_awardScore(a)));
    return selected;
  }

  List<Player> _firstTeam(List<Player> pool, Player heisman) {
    final used = <String>{heisman.name};
    final first = <Player>[heisman];

    final needs = <String, int>{
      'QB': 1,
      'HB': 1,
      'WR': 2,
      'TE': 1,
      'DE': 2,
      'LB': 2,
      'DB': 3,
    };

    needs[heisman.position] = max(0, (needs[heisman.position] ?? 0) - 1);

    for (final entry in needs.entries) {
      final candidates = pool
          .where((p) => p.position == entry.key && !used.contains(p.name))
          .toList()
        ..sort((a, b) => _awardScore(b).compareTo(_awardScore(a)));

      for (final player in candidates.take(entry.value)) {
        first.add(player);
        used.add(player.name);
      }
    }

    return first;
  }

  List<Player> _freshmanTeam(List<Player> pool) {
    final used = <String>{};
    final freshmen = pool.where((p) => p.year == 'FR').toList();
    return _allAmericanTeam(freshmen, used);
  }

  Player? _bestAt(List<Player> pool, List<String> positions) {
    final choices = pool.where((p) => positions.contains(p.position)).toList();
    if (choices.isEmpty) return null;
    choices.sort((a, b) => _awardScore(b).compareTo(_awardScore(a)));
    return choices.first;
  }

  String _playerLine(Player? p) {
    if (p == null) return 'None';
    return '${awardPlayerDisplayName(p)} • ${p.position} • ${p.year} • ${awardPlayerSchool(p)} • ${awardOverallCapped(p)} OVR';
  }

  Widget _playerRow(Player p, {bool heisman = false}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 7),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
      decoration: BoxDecoration(
        color: heisman ? kGold.withOpacity(.16) : kDark.withOpacity(.50),
        border: Border.all(color: heisman ? kGold : kBorder),
        borderRadius: BorderRadius.circular(13),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${awardPlayerDisplayName(p)} • ${p.position} • ${p.year} • ${awardPlayerSchool(p)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: GKColors.parchmentWhite, fontWeight: FontWeight.w900, fontSize: 12),
            ),
          ),
          Text(
            heisman ? 'HEISMAN' : '${awardOverallCapped(p)} OVR',
            style: TextStyle(color: heisman ? kGold : GKColors.fadedInk, fontWeight: FontWeight.w900, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _block(String title, List<Player> players, {Player? heisman}) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: kCardColor,
        border: Border.all(color: kBorder),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title.toUpperCase(),
            style: const TextStyle(color: kGold, fontSize: 12, fontWeight: FontWeight.w900, letterSpacing: 3),
          ),
          const SizedBox(height: 10),
          if (players.isEmpty)
            Text('No eligible players.', style: TextStyle(color: GKColors.fadedInk, fontWeight: FontWeight.bold)),
          ...players.map((p) => _playerRow(p, heisman: heisman != null && p.name == heisman.name)),
        ],
      ),
    );
  }

  Widget _seasonAwardsBlock(List<Player> pool) {
    final rows = [
      'Offensive Player: ${_playerLine(_bestAt(pool, ['QB', 'HB', 'WR', 'TE']))}',
      'Defensive Player: ${_playerLine(_bestAt(pool, ['DE', 'LB', 'DB']))}',
      'Best QB: ${_playerLine(_bestAt(pool, ['QB']))}',
      'Best RB: ${_playerLine(_bestAt(pool, ['HB']))}',
      'Best WR: ${_playerLine(_bestAt(pool, ['WR']))}',
    ];

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: kCardColor,
        border: Border.all(color: kBorder),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('SEASON AWARDS', style: TextStyle(color: kGold, fontSize: 12, fontWeight: FontWeight.w900, letterSpacing: 3)),
          const SizedBox(height: 10),
          ...rows.map((row) => Padding(
                padding: const EdgeInsets.only(bottom: 7),
                child: Text(row, style: const TextStyle(color: GKColors.parchmentWhite, fontWeight: FontWeight.bold, height: 1.3, fontSize: 12)),
              )),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pool = _buildPool();
    final heisman = _heismanWinner(pool);
    final first = _firstTeam(pool, heisman);
    final used = first.map((p) => p.name).toSet();
    final second = _allAmericanTeam(pool, used);
    final freshmen = _freshmanTeam(pool);

    return Column(
      children: [
        Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 14),
          padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(
            color: kGold.withOpacity(.13),
            border: Border.all(color: kGold),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(
            children: [
              const Icon(Icons.emoji_events, color: kGold, size: 26),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Heisman Trophy: ${awardPlayerDisplayName(heisman)} • ${heisman.position} • ${heisman.year} • ${awardPlayerSchool(heisman)} • ${awardOverallCapped(heisman)} OVR',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: GKColors.parchmentWhite, fontWeight: FontWeight.w900, height: 1.25),
                ),
              ),
            ],
          ),
        ),
        _block('First Team All-American', first, heisman: heisman),
        _block('Second Team All-American', second),
        _block('Freshman All-American Team', freshmen),
        _seasonAwardsBlock(pool),
      ],
    );
  }
}


class MockDraftScreen extends StatelessWidget {
  final List<Player> roster;

  const MockDraftScreen({super.key, required this.roster});

  @override
  Widget build(BuildContext context) {
    final draftables = roster.where((p) => p.year == 'SR' || p.overall >= 75).toList()
      ..sort((a, b) => awardOverall(b).compareTo(awardOverall(a)));

    return Scaffold(
      backgroundColor: kDark,
      appBar: AppBar(title: const AppTitle('Mock Draft')),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          if (draftables.isEmpty)
            Text('No draftable players yet.', style: TextStyle(color: GKColors.parchmentWhite, fontSize: 20, fontWeight: FontWeight.bold)),
          ...draftables.map((p) => Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: kCardColor, border: Border.all(color: kBorder), borderRadius: BorderRadius.circular(14)),
            child: Row(children: [
              PlayerAvatar(seed: p.name.hashCode, teamColor: kGold, size: 42),
              const SizedBox(width: 12),
              Expanded(child: Text('${p.cleanName}\n${p.position} · ${p.year} · ${p.awardTeamName}', style: const TextStyle(color: GKColors.parchmentWhite, fontWeight: FontWeight.bold))),
              Text('${awardOverall(p)}', style: const TextStyle(color: kGold, fontSize: 24, fontWeight: FontWeight.w900)),
            ]),
          )),
        ],
      ),
    );
  }
}


class RecruitProfileScreen extends StatefulWidget {
  final Recruit recruit;
  final int rank;
  final String userSchool;
  final Color userTeamColor;
  final bool recruitingClosed;
  final int recruitingPoints;
  final VoidCallback onScout;
  final VoidCallback onOffer;

  const RecruitProfileScreen({
    super.key,
    required this.recruit,
    required this.rank,
    required this.userSchool,
    this.userTeamColor = GKColors.kingdomGold,
    required this.recruitingClosed,
    required this.recruitingPoints,
    required this.onScout,
    required this.onOffer,
  });

  @override
  State<RecruitProfileScreen> createState() =>
      _RecruitProfileScreenState();
}

class _RecruitProfileScreenState
    extends State<RecruitProfileScreen> {
  int tab = 0;

  Recruit get recruit => widget.recruit;

  Color get _interestColor {
    if (recruit.interest >= 75) return GKColors.victoryGreen;
    if (recruit.interest >= 55) return Color(0xFF4DE7E5);
    return GKColors.alertRed;
  }

  String get _memoryText {
    final seed = recruit.name.hashCode.abs() % 6;

    return switch (seed) {
      0 => 'Your early evaluation made an impression.',
      1 => 'Watching how your offense uses his position.',
      2 => 'Interested in your recent player development.',
      3 => 'Tracking the atmosphere of ranked and rivalry games.',
      4 => 'Needs a believable route to early playing time.',
      _ => 'His family is evaluating the relationship with your staff.',
    };
  }

  String get _visitOutlook {
    if (recruit.committedSchool != null) {
      return recruit.committedSchool == widget.userSchool
          ? 'Committed prospects are preparing to join the class.'
          : 'This prospect is no longer available for a visit.';
    }
    if (!recruit.offered) {
      return 'Extend an offer before prioritizing an official visit.';
    }
    if (recruit.interest >= 70) {
      return 'Priority visitor. A strong home-game atmosphere could close the recruitment.';
    }
    if (recruit.interest >= 55) {
      return 'Visit candidate. Continue building interest before selecting the weekend.';
    }
    return 'The relationship needs more work before an official visit becomes valuable.';
  }

  bool get _canScout {
    return !widget.recruitingClosed &&
        recruit.committedSchool == null &&
        recruit.scouts < 3 &&
        widget.recruitingPoints >= 5;
  }

  bool get _canOffer {
    return !widget.recruitingClosed &&
        recruit.committedSchool == null &&
        !recruit.offered &&
        widget.recruitingPoints >= 10;
  }

  void _scout() {
    if (!_canScout) return;
    widget.onScout();
    setState(() {});
  }

  void _offer() {
    if (!_canOffer) return;
    widget.onOffer();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: GKColors.midnight,
      body: GKBackground(
        child: SafeArea(
          child: Column(
            children: [
              _profileTopBar(context),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(
                    GKSpace.md,
                    GKSpace.sm,
                    GKSpace.md,
                    GKSpace.xxl,
                  ),
                  children: [
                    _heroCard(),
                    const SizedBox(height: GKSpace.md),
                    _tabs(),
                    const SizedBox(height: GKSpace.md),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      child: KeyedSubtree(
                        key: ValueKey(tab),
                        child: switch (tab) {
                          1 => _skillsTab(),
                          2 => _recruitmentTab(),
                          _ => _overviewTab(),
                        },
                      ),
                    ),
                    const SizedBox(height: GKSpace.md),
                    _actionCard(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _profileTopBar(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(
        GKSpace.xs,
        GKSpace.xs,
        GKSpace.md,
        GKSpace.xs,
      ),
      decoration: BoxDecoration(
        color: Color(0xFF09131F),
        border: Border(
          bottom: BorderSide(
            color: Color(0xFF4DE7E5).withOpacity(.28),
          ),
        ),
        boxShadow: [
          BoxShadow(
            color: Color(0xFF4DE7E5).withOpacity(.05),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(
              Icons.arrow_back_ios_new_rounded,
              color: GKColors.warmWhite,
            ),
          ),
          const SizedBox(width: GKSpace.xs),
          const Expanded(
            child: Text(
              'SCOUTING DOSSIER',
              style: TextStyle(
                color: GKColors.warmWhite,
                fontSize: 14,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.4,
              ),
            ),
          ),
          Text(
            '${widget.recruitingPoints} PTS',
            style: const TextStyle(
              color: Color(0xFF4DE7E5),
              fontSize: 11,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }

  Widget _heroCard() {
    final committedToUser =
        recruit.committedSchool == widget.userSchool;
    final commitmentColor = committedToUser
        ? GKColors.victoryGreen
        : GKColors.alertRed;

    return GKCard(
      color: gkDarkenedSchoolColor(widget.userTeamColor, .75),
      borderColor: widget.userTeamColor.withOpacity(.62),
      radius: GKRadius.featured,
      child: Column(
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 9,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: GKColors.midnight.withOpacity(.58),
                  borderRadius:
                      BorderRadius.circular(GKRadius.pill),
                ),
                child: Text(
                  '#${widget.rank} NATIONAL',
                  style: const TextStyle(
                    color: Color(0xFF4DE7E5),
                    fontSize: 9,
                    fontWeight: FontWeight.w900,
                    letterSpacing: .7,
                  ),
                ),
              ),
              const Spacer(),
              Text(
                '${recruit.stars}★ ${recruit.position}',
                style: const TextStyle(
                  color: GKColors.warmWhite,
                  fontSize: 12,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          const SizedBox(height: GKSpace.md),
          PlayerAvatar(
            seed: recruit.name.hashCode,
            teamColor: widget.userTeamColor,
            size: 104,
          ),
          const SizedBox(height: GKSpace.md),
          Text(
            recruit.name.toUpperCase(),
            textAlign: TextAlign.center,
            style: GKText.pageTitle,
          ),
          const SizedBox(height: 5),
          Text(
            '${recruit.heightText} • ${recruit.weight} LBS • '
            '${recruit.archetype.toUpperCase()}',
            textAlign: TextAlign.center,
            style: GKText.body.copyWith(fontSize: 11),
          ),
          const SizedBox(height: 3),
          Text(
            '${recruit.state.toUpperCase()} HIGH SCHOOL',
            style: const TextStyle(
              color: GKColors.mutedSilver,
              fontSize: 9,
              fontWeight: FontWeight.w900,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: GKSpace.md),
          Row(
            children: [
              Expanded(
                child: _heroMetric(
                  recruit.scouts >= 3
                      ? '${recruit.displayedOverall}'
                      : recruit.cardOverallText,
                  'OVERALL',
                ),
              ),
              const _Phase3Divider(),
              Expanded(
                child: _heroMetric(
                  recruit.potentialText.replaceAll('POT ', ''),
                  'POTENTIAL',
                ),
              ),
              const _Phase3Divider(),
              Expanded(
                child: _heroMetric(
                  '${recruit.interest}%',
                  'INTEREST',
                  color: _interestColor,
                ),
              ),
            ],
          ),
          if (recruit.committedSchool != null) ...[
            const SizedBox(height: GKSpace.md),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(GKSpace.sm),
              decoration: BoxDecoration(
                color: commitmentColor.withOpacity(.12),
                border:
                    Border.all(color: commitmentColor.withOpacity(.45)),
                borderRadius:
                    BorderRadius.circular(GKRadius.small),
              ),
              child: Text(
                'COMMITTED TO ${recruit.committedSchool!.toUpperCase()}',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: commitmentColor,
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _heroMetric(
    String value,
    String label, {
    Color color = GKColors.warmWhite,
  }) {
    return Column(
      children: [
        Text(
          value,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: color,
            fontSize: 21,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: GKColors.mutedSilver,
            fontSize: 8,
            fontWeight: FontWeight.w900,
            letterSpacing: .8,
          ),
        ),
      ],
    );
  }

  Widget _tabs() {
    const labels = ['DOSSIER', 'TRAITS', 'DECISION'];

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: GKColors.broadcastNavy,
        border: Border.all(color: GKColors.divider),
        borderRadius: BorderRadius.circular(GKRadius.card),
      ),
      child: Row(
        children: List.generate(labels.length, (index) {
          final selected = tab == index;

          return Expanded(
            child: GestureDetector(
              onTap: () => setState(() => tab = index),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding:
                    const EdgeInsets.symmetric(vertical: GKSpace.sm),
                decoration: BoxDecoration(
                  color: selected
                      ? Color(0xFF4DE7E5)
                      : Colors.transparent,
                  borderRadius:
                      BorderRadius.circular(GKRadius.small),
                ),
                child: Text(
                  labels[index],
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: selected
                        ? GKColors.inkBlack
                        : GKColors.mutedSilver,
                    fontSize: 9,
                    fontWeight: FontWeight.w900,
                    letterSpacing: .6,
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _overviewTab() {
    return Column(
      children: [
        _profileGrid([
          ('${recruit.passYards}', 'PASS YDS'),
          ('${recruit.rushYards}', 'RUSH YDS'),
          ('${recruit.recYards}', 'REC YDS'),
          ('${recruit.tackles}', 'TACKLES'),
          ('${recruit.sacks}', 'SACKS'),
          ('${recruit.interceptions}', 'INT'),
        ]),
        const SizedBox(height: GKSpace.md),
        GKCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('PERSONALITY', style: GKText.sectionLabel),
              const SizedBox(height: GKSpace.xs),
              Text(
                recruit.personality,
                style: GKText.cardTitle,
              ),
              const SizedBox(height: GKSpace.xs),
              Text(
                _memoryText,
                style: GKText.body,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _skillsTab() {
    return Column(
      children: [
        _profileGrid([
          (
            recruit.scouts >= 3
                ? '${recruit.displayedOverall}'
                : recruit.cardOverallText,
            'OVR'
          ),
          (recruit.potentialText.replaceAll('POT ', ''), 'POT'),
          ('${recruit.forty}', '40 TIME'),
          ('${recruit.bench}', 'BENCH'),
          ('${recruit.squat}', 'SQUAT'),
          ('${recruit.vertical}"', 'VERT'),
        ]),
        const SizedBox(height: GKSpace.md),
        GKCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('SCOUTING REPORT', style: GKText.sectionLabel),
              const SizedBox(height: GKSpace.xs),
              Text(
                recruit.scoutingReport,
                style: GKText.body.copyWith(
                  color: GKColors.warmWhite,
                ),
              ),
              if (recruit.scouts >= 2 &&
                  recruit.gemLabel.isNotEmpty) ...[
                const SizedBox(height: GKSpace.sm),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: (recruit.isGem
                            ? GKColors.victoryGreen
                            : GKColors.alertRed)
                        .withOpacity(.12),
                    borderRadius:
                        BorderRadius.circular(GKRadius.pill),
                  ),
                  child: Text(
                    recruit.gemLabel,
                    style: TextStyle(
                      color: recruit.isGem
                          ? GKColors.victoryGreen
                          : GKColors.alertRed,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _recruitmentTab() {
    return Column(
      children: [
        GKCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('RECRUITMENT STATUS', style: GKText.sectionLabel),
              const SizedBox(height: GKSpace.md),
              _recruitmentRow(
                'Interest',
                '${recruit.interest}%',
                color: _interestColor,
              ),
              _recruitmentRow(
                'Offer',
                recruit.offered ? 'Scholarship Offered' : 'No Offer',
              ),
              _recruitmentRow(
                'Scouting',
                '${recruit.scouts}/3 Evaluations',
              ),
              _recruitmentRow(
                'Program Fit',
                recruit.shortFit,
              ),
              _recruitmentRow(
                'Decision',
                recruit.committedSchool ??
                    (recruit.decisionWindow == null
                        ? 'Undecided'
                        : 'Decision Window ${recruit.decisionWindow}'),
              ),
            ],
          ),
        ),
        const SizedBox(height: GKSpace.md),
        GKCard(
          color: Color(0xFF101E2F),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('OFFICIAL VISIT OUTLOOK',
                  style: GKText.sectionLabel),
              const SizedBox(height: GKSpace.xs),
              Text(
                _visitOutlook,
                style: GKText.body.copyWith(
                  color: GKColors.warmWhite,
                ),
              ),
              const SizedBox(height: GKSpace.sm),
              Row(
                children: [
                  const Icon(
                    Icons.stadium_outlined,
                    color: Color(0xFF4DE7E5),
                    size: 18,
                  ),
                  const SizedBox(width: GKSpace.xs),
                  Expanded(
                    child: Text(
                      recruit.interest >= 70
                          ? 'Best fit: rivalry, ranked, or national-TV home game'
                          : 'Build interest before selecting a major home weekend',
                      style: GKText.body.copyWith(fontSize: 10),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _recruitmentRow(
    String label,
    String value, {
    Color color = GKColors.warmWhite,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 11),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: GKColors.divider),
        ),
      ),
      child: Row(
        children: [
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              color: GKColors.mutedSilver,
              fontSize: 9,
              fontWeight: FontWeight.w900,
              letterSpacing: .8,
            ),
          ),
          const Spacer(),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _profileGrid(List<(String, String)> values) {
    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisSpacing: GKSpace.xs,
      mainAxisSpacing: GKSpace.xs,
      childAspectRatio: 1.12,
      children: values.map((entry) {
        return GKCard(
          padding: const EdgeInsets.all(GKSpace.xs),
          radius: GKRadius.small,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                entry.$1,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Color(0xFF4DE7E5),
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                entry.$2,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: GKColors.mutedSilver,
                  fontSize: 8,
                  fontWeight: FontWeight.w900,
                  letterSpacing: .7,
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _actionCard() {
    if (widget.recruitingClosed) {
      return _statusActionCard(
        icon: Icons.lock_rounded,
        title: 'Recruiting Closed',
        detail: 'The final board is locked for this season.',
        color: GKColors.alertRed,
      );
    }

    if (recruit.committedSchool != null) {
      return _statusActionCard(
        icon: recruit.committedSchool == widget.userSchool
            ? Icons.check_circle_rounded
            : Icons.cancel_rounded,
        title: recruit.committedSchool == widget.userSchool
            ? 'Commitment Secured'
            : 'Prospect Committed Elsewhere',
        detail: recruit.committedSchool == widget.userSchool
            ? '${recruit.name} will join your incoming class.'
            : '${recruit.name} selected ${recruit.committedSchool}.',
        color: recruit.committedSchool == widget.userSchool
            ? GKColors.victoryGreen
            : GKColors.alertRed,
      );
    }

    return GKCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('COACHING ACTIONS', style: GKText.sectionLabel),
          const SizedBox(height: GKSpace.sm),
          Row(
            children: [
              Expanded(
                child: GKSecondaryButton(
                  label: recruit.scouts >= 3
                      ? 'Fully Scouted'
                      : 'Scout · 5 PTS',
                  icon: Icons.manage_search_rounded,
                  onPressed: _canScout ? _scout : null,
                ),
              ),
              const SizedBox(width: GKSpace.sm),
              Expanded(
                child: GKPrimaryButton(
                  label: recruit.offered
                      ? 'Offer Sent'
                      : 'Offer · 10 PTS',
                  icon: Icons.mark_email_read_outlined,
                  onPressed: _canOffer ? _offer : null,
                ),
              ),
            ],
          ),
          const SizedBox(height: GKSpace.sm),
          Text(
            recruit.offered
                ? 'The offer is active. Continue advancing recruiting windows while monitoring his interest.'
                : 'An offer begins the decision process and makes the prospect eligible for visit consideration.',
            style: GKText.body.copyWith(fontSize: 10),
          ),
        ],
      ),
    );
  }

  Widget _statusActionCard({
    required IconData icon,
    required String title,
    required String detail,
    required Color color,
  }) {
    return GKCard(
      color: color.withOpacity(.10),
      borderColor: color.withOpacity(.40),
      child: Row(
        children: [
          Icon(icon, color: color, size: 28),
          const SizedBox(width: GKSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title.toUpperCase(),
                  style: TextStyle(
                    color: color,
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                    letterSpacing: .8,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  detail,
                  style: GKText.body.copyWith(fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}


class SeasonAwardWinners {
  final Player heisman;
  final Player offensivePlayer;
  final Player defensivePlayer;
  final Player qb;
  final Player rb;
  final Player wr;
  final Player te;
  final Player lineman;
  final Player db;
  final Player freshman;

  const SeasonAwardWinners({
    required this.heisman,
    required this.offensivePlayer,
    required this.defensivePlayer,
    required this.qb,
    required this.rb,
    required this.wr,
    required this.te,
    required this.lineman,
    required this.db,
    required this.freshman,
  });
}

bool _isOffensivePosition(String pos) => ['QB', 'RB', 'HB', 'WR', 'TE', 'OL'].contains(pos);
bool _isDefensivePosition(String pos) => ['DL', 'DE', 'DT', 'LB', 'CB', 'DB', 'S'].contains(pos);

Player _bestByPosition(List<Player> players, List<String> positions, Player fallback) {
  final pool = players.where((p) => positions.contains(p.position)).toList();
  if (pool.isEmpty) return fallback;
  pool.sort((a, b) => awardOverall(b).compareTo(awardOverall(a)));
  return pool.first;
}

SeasonAwardWinners buildSeasonAwards(List<Player> allPlayers) {
  final players = allPlayers.toList();
  players.sort((a, b) => awardOverall(b).compareTo(awardOverall(a)));
  final fallback = players.isNotEmpty
      ? players.first
      : Player(name: 'No Player', position: 'QB', year: 'FR', overall: 60, potential: 70, stars: 1);

  final offense = players.where((p) => _isOffensivePosition(p.position)).toList()
    ..sort((a, b) => awardOverall(b).compareTo(awardOverall(a)));
  final defense = players.where((p) => _isDefensivePosition(p.position)).toList()
    ..sort((a, b) => awardOverall(b).compareTo(awardOverall(a)));

  final freshman = players.where((p) => p.year == 'FR').toList()
    ..sort((a, b) => awardOverall(b).compareTo(awardOverall(a)));

  final qb = _bestByPosition(players, ['QB'], fallback);
  final rb = _bestByPosition(players, ['RB', 'HB'], fallback);
  final wr = _bestByPosition(players, ['WR'], fallback);
  final te = _bestByPosition(players, ['TE'], fallback);
  final lineman = _bestByPosition(players, ['OL', 'DL', 'DE', 'DT', 'LB'], fallback);
  final db = _bestByPosition(players, ['CB', 'DB', 'S'], fallback);

  // Heisman = best season, not just best raw overall.
  // It favors elite production from QB/HB/WR/TE and gives a small boost for winners.
  final heismanPool = <Player>[...offense];
  if (heismanPool.isEmpty) heismanPool.addAll(players);

  double heismanSeasonScore(Player p) {
    final ovr = awardOverall(p).toDouble();

    final ppg = p.ppg;
    final rush = p.rushYards;
    final pass = p.passYards;
    final rec = p.recYards;
    final td = p.touchdowns;
    final sacks = p.sacks;
    final ints = p.interceptions;

    double production;
    switch (p.position) {
      case 'QB':
        production = (pass / 120.0) + (td * 1.8) + (ppg * 1.2);
        break;
      case 'HB':
      case 'RB':
        production = (rush / 65.0) + (td * 2.0) + (rec / 120.0);
        break;
      case 'WR':
      case 'TE':
        production = (rec / 55.0) + (td * 2.1);
        break;
      default:
        production = (sacks * 2.4) + (ints * 3.0) + (ppg * .6);
        break;
    }

    final teamBoost = p.teamWins >= 10 ? 10 : p.teamWins >= 8 ? 5 : 0;
    final positionBoost = p.position == 'QB'
        ? 6
        : (p.position == 'HB' || p.position == 'RB')
            ? 4
            : (p.position == 'WR' || p.position == 'TE')
                ? 3
                : 0;

    return production + (ovr * .45) + teamBoost + positionBoost;
  }

  heismanPool.sort((a, b) => heismanSeasonScore(b).compareTo(heismanSeasonScore(a)));

  return SeasonAwardWinners(
    heisman: (() {
      final firstTeamSkill = [qb, rb, wr].where((p) => p.name != fallback.name).toList();
      if (firstTeamSkill.isNotEmpty) {
        firstTeamSkill.sort((a, b) => heismanSeasonScore(b).compareTo(heismanSeasonScore(a)));
        return firstTeamSkill.first;
      }
      final firstTeam = [qb, rb, wr, te, lineman, db].where((p) => p.name != fallback.name).toList();
      firstTeam.sort((a, b) => heismanSeasonScore(b).compareTo(heismanSeasonScore(a)));
      return firstTeam.isNotEmpty ? firstTeam.first : heismanPool.first;
    })(),
    offensivePlayer: offense.isNotEmpty ? offense.first : fallback,
    defensivePlayer: defense.isNotEmpty ? defense.first : fallback,
    qb: qb,
    rb: rb,
    wr: wr,
    te: te,
    lineman: lineman,
    db: db,
    freshman: freshman.isNotEmpty ? freshman.first : fallback,
  );
}

class OffseasonScreen extends StatefulWidget {
  final CollegeTeam team;
  final CoachProfile coach;
  final int season;
  final int wins;
  final int losses;
  final int confWins;
  final int confLosses;
  final List<Player> roster;
  final List<Recruit> incomingRecruits;
  final ValueChanged<OffseasonResult> onFinish;

  const OffseasonScreen({
    super.key,
    required this.team,
    required this.coach,
    required this.season,
    required this.wins,
    required this.losses,
    required this.confWins,
    required this.confLosses,
    required this.roster,
    required this.incomingRecruits,
    required this.onFinish,
  });

  @override
  State<OffseasonScreen> createState() => _OffseasonScreenState();
}

class _OffseasonScreenState extends State<OffseasonScreen> {
  List<Recruit> get committedRecruits => widget.incomingRecruits.where((r) => r.committedSchool == widget.team.name).toList();

  CoachTransitionResult? transitionResult;
  List<Recruit> get recruits => committedRecruits;

  int step = 0;
  late CollegeTeam selectedTeam;
  late List<Player> roster;
  late List<JobOffer> jobOffers;
  late int retentionBudget;
  late int retentionSpent;
  late int trainingPoints;
  final retainedPlayerNames = <String>{};
  late List<Player> graduatingPlayers;
  late List<Player> draftEligibleJuniors;
  late List<Player> retentionCandidates;
  final draftedPlayers = <Player>[];
  bool retentionFinalized = false;
  final playerSkillBoosts = <String, Map<String, int>>{};
  final trainingBaseOveralls = <String, int>{};
  late List<TransferTarget> transferTargets;
  final signedTransfers = <TransferTarget>[];
  CollegeTeam? rivalryTeam;
  List<CollegeTeam> customNonConference = [];
  final redshirtedPlayerNames = <String>{};

  final steps = const [
    'Program Review',
    'Coaching Market',
    'Contract Decision',
    'Roster Decisions',
    'Portal Window',
    'Signing Day',
    'Spring Practice',
    'Eligibility Desk',
    'Schedule Reveal',
  ];

  @override
  void initState() {
    super.initState();
    selectedTeam = widget.team;
    graduatingPlayers = widget.roster
        .where((p) => p.year == 'SR')
        .toList()
      ..sort((a, b) => awardOverall(b).compareTo(awardOverall(a)));

    roster = _initialRoster();

    draftEligibleJuniors = roster
        .where(
          (p) =>
              p.year == 'JR' &&
              (awardOverall(p) >= 86 ||
                  (awardOverall(p) >= 82 && p.potential >= 91)),
        )
        .toList()
      ..sort((a, b) => awardOverall(b).compareTo(awardOverall(a)));

    retentionCandidates = roster
        .where(
          (p) =>
              p.year != 'FR' &&
              (p.overall >= 68 ||
                  p.year == 'JR' ||
                  draftEligibleJuniors.any((junior) => junior.name == p.name)),
        )
        .toList()
      ..sort((a, b) {
        final aDraftBonus =
            draftEligibleJuniors.any((junior) => junior.name == a.name) ? 45 : 0;
        final bDraftBonus =
            draftEligibleJuniors.any((junior) => junior.name == b.name) ? 45 : 0;
        final aScore =
            a.overall * 3 + a.potential + (a.year == 'JR' ? 10 : 0) + aDraftBonus;
        final bScore =
            b.overall * 3 + b.potential + (b.year == 'JR' ? 10 : 0) + bDraftBonus;
        return bScore.compareTo(aScore);
      });

    final riskCount = max(
      draftEligibleJuniors.length,
      (2 + widget.losses ~/ 3).clamp(2, 7),
    );
    retentionCandidates = retentionCandidates.take(riskCount).toList();

    jobOffers = _jobOffers();
    retentionBudget = retentionBudgetForSeason(widget.wins, widget.losses, widget.team.prestige);
    retentionSpent = 0;
    trainingPoints = _trainingPoints();
    transferTargets = _generateTransfers();
  }

  String _advancePlayerYear(String year) {
    return switch (year) {
      'FR' => 'SO',
      'SO' => 'JR',
      'JR' => 'SR',
      _ => year,
    };
  }

  List<Player> _initialRoster() {
    // Keep every non-senior player from the user's current roster.
    // Their identity and ratings stay intact; only their class year advances.
    final returning = widget.roster
        .where((player) => player.year != 'SR')
        .map(
          (player) => Player(
            name: player.name,
            position: player.position,
            overall: player.overall,
            potential: player.potential,
            year: _advancePlayerYear(player.year),
            stars: player.stars,
          ),
        )
        .toList();

    // Returning players are never cut automatically to make room.
    // New recruits are added only when an actual roster spot is available.
    final availableRecruitSlots = max(0, 22 - returning.length);

    final incoming = widget.incomingRecruits
        .take(availableRecruitSlots)
        .map(
          (recruit) => Player(
            name: recruit.name,
            position: recruit.position,
            overall:
                (recruit.displayedOverall - 2 + rng.nextInt(5)).clamp(45, 94),
            potential: recruit.truePotential,
            year: 'FR',
            stars: recruit.stars,
          ),
        )
        .toList();

    return [...returning, ...incoming]
      ..sort((a, b) => awardOverall(b).compareTo(awardOverall(a)));
  }

  int _trainingPoints() {
    final base = 70 + widget.wins * 6;
    final lowPrestigeBonus = prestigeTier(widget.team.prestige) <= 2 && widget.wins >= 7 ? 20 : 0;
    return (base + lowPrestigeBonus).clamp(60, 170);
  }

  List<JobOffer> _jobOffers() {
    final expected = prestigeExpectationWins(widget.team.prestige);
    final overExpectation = widget.wins - expected;
    final targets = jobOfferPrestigeTargets(
      currentPrestige: widget.team.prestige,
      wins: widget.wins,
      losses: widget.losses,
      expectedWins: max(4, (prestige100(widget.team.prestige) - 45) ~/ 6),
    );

    final primaryPool = g5Teams
        .where((t) => t.name != widget.team.name)
        .where((t) => targets.any((target) => (prestige100(t.prestige) - target).abs() <= 12))
        .where((t) => widget.wins >= 8 || prestige100(t.prestige) <= prestige100(widget.team.prestige) + 10)
        .toList()
      ..shuffle(rng);

    final teams = <CollegeTeam>[];
    for (final team in primaryPool) {
      if (!teams.any((t) => t.name == team.name)) teams.add(team);
      if (teams.length >= 3) break;
    }

    if (teams.length < 3) {
      final fallback = g5Teams
          .where((t) => t.name != widget.team.name)
          .where((t) => !teams.any((o) => o.name == t.name))
          .toList()
        ..shuffle(rng);

      for (final team in fallback) {
        teams.add(team);
        if (teams.length >= 3) break;
      }
    }

    final count = overExpectation >= 4 || widget.wins >= 10 ? 4 : 3;
    return teams.take(count).map((team) => JobOffer(team: team, years: 2 + rng.nextInt(2))).toList();
  }

  void _retainPlayer(Player p) {
    if (retainedPlayerNames.contains(p.name)) return;

    final baseAsk = playerRetentionAsk(p);
    final ask = _isJuniorDraftCandidate(p)
        ? (baseAsk * 1.65).round()
        : baseAsk;
    if (retentionSpent + ask > retentionBudget) return;

    setState(() {
      retentionSpent += ask;
      retainedPlayerNames.add(p.name);
    });
  }
  Player _baseTrainingPlayer(Player p) {
    final baseOverall = trainingBaseOveralls[p.name] ?? p.overall;
    return Player(
      name: p.name,
      position: p.position,
      overall: baseOverall,
      potential: p.potential,
      year: p.year,
      stars: p.stars,
    );
  }

  int _trainingProjectedOverall(Player p, Map<String, int> boosts) {
    final basePlayer = _baseTrainingPlayer(p);
    final baseSkills = playerSkillRatings(basePlayer);
    final upgradedSkills = {
      for (final entry in baseSkills.entries)
        entry.key: (entry.value + (boosts[entry.key] ?? 0)).clamp(40, 94),
    };

    final newOverall = (upgradedSkills.values.reduce((a, b) => a + b) / upgradedSkills.length).round();
    return max(basePlayer.overall, newOverall).clamp(45, basePlayer.potential);
  }

  void _applyTrainingOverall(Player p) {
    final idx = roster.indexWhere((x) => x.name == p.name);
    if (idx < 0) return;

    final old = roster[idx];
    final boosts = playerSkillBoosts[old.name] ?? {};
    final newOverall = _trainingProjectedOverall(old, boosts);

    roster[idx] = Player(
      name: old.name,
      position: old.position,
      overall: newOverall,
      potential: old.potential,
      year: old.year,
      stars: old.stars,
    );
  }

  void _upgradePlayerSkill(Player p, String skill) {
    if (trainingPoints < 10 || p.overall >= p.potential) return;

    setState(() {
      trainingBaseOveralls.putIfAbsent(p.name, () => p.overall);
      final boosts = playerSkillBoosts.putIfAbsent(p.name, () => {});
      boosts[skill] = (boosts[skill] ?? 0) + 1;
      trainingPoints -= 10;
      _applyTrainingOverall(p);
    });
  }

  void _removePlayerSkill(Player p, String skill) {
    final boosts = playerSkillBoosts[p.name];
    final currentBoost = boosts?[skill] ?? 0;
    if (currentBoost <= 0) return;

    setState(() {
      boosts![skill] = currentBoost - 1;
      if (boosts[skill] == 0) boosts.remove(skill);
      if (boosts.isEmpty) {
        playerSkillBoosts.remove(p.name);
      }

      trainingPoints += 10;
      _applyTrainingOverall(p);
    });
  }


  List<TransferTarget> _generateTransfers() {
    final positions = ['QB', 'HB', 'WR', 'TE', 'DE', 'LB', 'DB'];
    final years = ['SO', 'JR', 'SR'];
    final needs = _positionNeeds();

    final prestige = prestige100(widget.team.prestige);
    final tier = prestigeTier(widget.team.prestige);

    // Portal access by school prestige:
    // 50-59: mostly 1-2★
    // 60-69: mostly 2-3★, no 5★
    // 70-79: 2-4★
    // 80-89: 3-4★, rare 5★
    // 90-100: full portal access
    int maxStars;
    if (prestige >= 90) {
      maxStars = 5;
    } else if (prestige >= 80) {
      maxStars = widget.wins >= 9 ? 5 : 4;
    } else if (prestige >= 70) {
      maxStars = 4;
    } else if (prestige >= 60) {
      maxStars = 3;
    } else {
      maxStars = widget.wins >= 10 ? 3 : 2;
    }

    int rollStars() {
      final roll = rng.nextInt(100);

      if (maxStars <= 2) {
        if (roll < 70) return 1;
        return 2;
      }

      if (maxStars == 3) {
        if (roll < 25) return 1;
        if (roll < 72) return 2;
        return 3;
      }

      if (maxStars == 4) {
        if (roll < 12) return 2;
        if (roll < 52) return 3;
        return 4;
      }

      if (roll < 12) return 3;
      if (roll < 48) return 4;
      return 5;
    }

    int overallForStars(int stars) {
      switch (stars) {
        case 1:
          return 50 + rng.nextInt(11); // 50-60
        case 2:
          return 58 + rng.nextInt(13); // 58-70
        case 3:
          return 66 + rng.nextInt(13); // 66-78
        case 4:
          return 76 + rng.nextInt(11); // 76-86
        default:
          return 86 + rng.nextInt(9);  // 86-94
      }
    }

    int interestFor(int stars, int overall, String position) {
      final needBoost = (needs[position] ?? 0) * 5;
      final seasonBoost = widget.wins >= 9
          ? 12
          : widget.wins >= 7
              ? 6
              : widget.wins <= 4
                  ? -10
                  : 0;

      var interest = 40 + ((prestige - 50) ~/ 2) + seasonBoost + needBoost + rng.nextInt(16);

      if (stars > maxStars) interest -= 45;
      if (stars == maxStars) interest -= 8;
      if (overall >= 88 && prestige < 80) interest -= 35;
      if (overall >= 84 && prestige < 70) interest -= 25;

      return interest.clamp(5, 99);
    }

    final list = <TransferTarget>[];

    for (int i = 0; i < 24; i++) {
      final position = positions[rng.nextInt(positions.length)];
      final stars = rollStars();
      final overall = overallForStars(stars);
      final interest = interestFor(stars, overall, position);

      list.add(
        TransferTarget(
          name: NameGenerator.generate(),
          position: position,
          overall: overall,
          potential: (overall + 4 + rng.nextInt(11)).clamp(overall, 96),
          year: years[rng.nextInt(years.length)],
          stars: stars,
          interest: interest,
        ),
      );
    }

    // Show the most interested players first, not just the highest overall players.
    list.sort((a, b) {
      final byInterest = b.interest.compareTo(a.interest);
      if (byInterest != 0) return byInterest;
      return b.overall.compareTo(a.overall);
    });

    return list.take(18).toList();
  }

  Map<String, int> _positionNeeds() {
    final desired = {
      'QB': 2,
      'HB': 2,
      'WR': 4,
      'TE': 2,
      'DE': 4,
      'LB': 4,
      'DB': 4,
    };

    final counts = <String, int>{};
    for (final p in roster) {
      counts[p.position] = (counts[p.position] ?? 0) + 1;
    }

    final needs = <String, int>{};
    for (final entry in desired.entries) {
      needs[entry.key] = max(0, entry.value - (counts[entry.key] ?? 0));
    }
    return needs;
  }

  void _offerTransfer(TransferTarget transfer) {
    if (transfer.offered || transfer.signed || transfer.declined) return;
    if (roster.length >= 22) return;

    setState(() {
      transfer.offered = true;
      final signChance = (transfer.interest / 240).clamp(.05, .92);
      if (rng.nextDouble() < signChance) {
        transfer.signed = true;
        signedTransfers.add(transfer);

        final signedPlayer = transfer.toPlayer();
        if (!roster.any((player) => player.name == signedPlayer.name)) {
          roster.add(signedPlayer);
          trainingBaseOveralls[signedPlayer.name] = signedPlayer.overall;
          roster.sort(
            (a, b) => awardOverall(b).compareTo(awardOverall(a)),
          );
        }
      } else {
        transfer.declined = true;
      }
    });
  }

  bool _isJuniorDraftCandidate(Player player) {
    return draftEligibleJuniors.any(
      (candidate) => candidate.name == player.name,
    );
  }

  String _draftProjection(Player player) {
    final overall = awardOverall(player);

    if (overall >= 94) return 'ROUND 1';
    if (overall >= 90) return 'ROUNDS 1-2';
    if (overall >= 86) return 'ROUNDS 2-4';
    if (overall >= 80) return 'ROUNDS 4-6';
    return 'ROUND 7 / UDFA';
  }

  String _draftTeam(Player player) {
    const teams = [
      'Arizona',
      'Atlanta',
      'Baltimore',
      'Buffalo',
      'Carolina',
      'Chicago',
      'Cincinnati',
      'Cleveland',
      'Dallas',
      'Denver',
      'Detroit',
      'Green Bay',
      'Houston',
      'Indianapolis',
      'Jacksonville',
      'Kansas City',
      'Las Vegas',
      'Los Angeles',
      'Miami',
      'Minnesota',
      'New England',
      'New Orleans',
      'New York',
      'Philadelphia',
      'Pittsburgh',
      'San Francisco',
      'Seattle',
      'Tampa Bay',
      'Tennessee',
      'Washington',
    ];

    return teams[player.name.hashCode.abs() % teams.length];
  }

  String _projectedTransferDestination(Player player) {
    final options = g5Teams
        .where((team) => team.name != selectedTeam.name)
        .toList();

    if (options.isEmpty) return 'Transfer Portal';

    final index = player.name.hashCode.abs() % options.length;
    return options[index].name;
  }

  void _finalizeRetention() {
    if (retentionFinalized) return;

    draftedPlayers.clear();

    // Seniors who are good enough are drafted after graduating.
    draftedPlayers.addAll(
      graduatingPlayers.where(
        (player) =>
            awardOverall(player) >= 72 ||
            (awardOverall(player) >= 68 && player.stars >= 4),
      ),
    );

    // Elite juniors declare unless the coach successfully retains them with NIL.
    final juniorsLeavingForDraft = draftEligibleJuniors
        .where((player) => !retainedPlayerNames.contains(player.name))
        .toList();

    draftedPlayers.addAll(juniorsLeavingForDraft);

    final transferNames = retentionCandidates
        .where(
          (player) =>
              !retainedPlayerNames.contains(player.name) &&
              !draftEligibleJuniors.any(
                (junior) => junior.name == player.name,
              ),
        )
        .map((player) => player.name)
        .toSet();

    final draftNames = juniorsLeavingForDraft.map((p) => p.name).toSet();

    roster.removeWhere(
      (player) =>
          transferNames.contains(player.name) ||
          draftNames.contains(player.name),
    );

    retentionFinalized = true;
  }

  void _randomizeNonConference() {
    final optionMap = <String, CollegeTeam>{};
    for (final team in g5Teams) {
      if (team.name != widget.team.name && team.conference != widget.team.conference) {
        optionMap[team.name] = team;
      }
    }

    final options = optionMap.values.toList()..shuffle(rng);

    setState(() {
      customNonConference = options.take(3).toList();
    });
  }

  void _finish() {
    final finalRoster = [
      ...(selectedTeam.name == widget.team.name
          ? roster
          : (transitionResult?.playersFollowing ?? <Player>[])),
    ]..sort((a, b) => awardOverall(b).compareTo(awardOverall(a)));

    // Fill genuine open roster spots with walk-ons, but never replace or
    // silently cut a returning player.
    while (finalRoster.length < 22) {
      final walkOn = generateRoster(widget.team.prestige).first;
      if (!finalRoster.any((player) => player.name == walkOn.name)) {
        finalRoster.add(walkOn);
      }
    }

    final changedJobs = selectedTeam.name != widget.team.name;

    widget.onFinish(
      OffseasonResult(
        team: selectedTeam,
        roster: finalRoster,
        rivalry: rivalryTeam,
        customNonConference: customNonConference,
      ),
    );

    if (!changedJobs) {
      Navigator.of(context).pop();
    }
  }

  void _next() {
    if (step >= steps.length - 1) {
      _finish();
      return;
    }

    if (step == 3) {
      setState(() {
        _finalizeRetention();
        step++;
      });
      return;
    }

    setState(() => step++);
  }

  static const List<String> _offseasonStageNames = [
    'Program Review',
    'Coaching Market',
    'Contract Decision',
    'Roster Decisions',
    'Portal Window',
    'Signing Day',
    'Spring Practice',
    'Eligibility Desk',
    'Schedule Reveal',
  ];

  static const List<String> _offseasonStageDays = [
    'DAY 01–03',
    'DAY 04–06',
    'DAY 07',
    'DAY 08–11',
    'DAY 12–16',
    'DAY 17',
    'DAY 18–21',
    'DAY 22',
    'DAY 23–24',
  ];

  static const List<IconData> _offseasonStageIcons = [
    Icons.account_balance_outlined,
    Icons.campaign_outlined,
    Icons.draw_outlined,
    Icons.groups_2_outlined,
    Icons.swap_horiz_rounded,
    Icons.how_to_reg_outlined,
    Icons.sports_football_outlined,
    Icons.fact_check_outlined,
    Icons.calendar_month_outlined,
  ];

  String get _stageName => _offseasonStageNames[step];
  String get _stageDay => _offseasonStageDays[step];

  String _stageDescription(int index) {
    return switch (index) {
      0 => 'The athletic department closes the book on the season and sets the direction of the program.',
      1 => 'Schools move, rumors build, and your name enters the national coaching conversation.',
      2 => 'Review the terms, pressure, and expectations attached to your next season.',
      3 => 'Meet with players, protect the core of the roster, and settle every departure risk.',
      4 => 'The national player market opens. Fill needs without losing sight of roster balance.',
      5 => 'The recruiting class is introduced and the future of the program becomes official.',
      6 => 'Use spring practice to develop the roster and identify the players ready to break out.',
      7 => 'Finalize redshirts and eligibility decisions before the roster is locked.',
      _ => 'Reveal the non-conference slate, establish rivalries, and launch the next season.',
    };
  }

  String _stageEyebrow(int index) {
    return switch (index) {
      0 => 'ATHLETIC DEPARTMENT',
      1 => 'KINGDOM WIRE LIVE',
      2 => 'COACH OFFICE',
      3 => 'ROSTER WAR ROOM',
      4 => 'NATIONAL TRANSACTION DESK',
      5 => 'SIGNING DAY CENTRAL',
      6 => 'SPRING CAMP',
      7 => 'PLAYER SERVICES',
      _ => 'SCHEDULE RELEASE',
    };
  }

  String _stageActionText() {
    if (step == steps.length - 1) return 'BEGIN NEXT SEASON';
    return switch (step) {
      0 => 'ENTER COACHING MARKET',
      1 => 'REVIEW CONTRACT',
      2 => 'OPEN ROSTER MEETINGS',
      3 => 'OPEN TRANSFER WINDOW',
      4 => 'GO TO SIGNING DAY',
      5 => 'BEGIN SPRING PRACTICE',
      6 => 'FINALIZE ELIGIBILITY',
      7 => 'REVEAL SCHEDULE',
      _ => 'CONTINUE',
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: GKColors.midnight,
      body: GKBackground(
        child: SafeArea(
          child: Column(
            children: [
              _offseasonCommandHeader(),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(
                    GKSpace.md,
                    GKSpace.lg,
                    GKSpace.md,
                    132,
                  ),
                  children: [
                    _currentStageHero(),
                    const SizedBox(height: GKSpace.lg),
                    _offseasonCalendar(),
                    const SizedBox(height: GKSpace.xl),
                    _stageWorkspace(),
                  ],
                ),
              ),
              _offseasonCommandDock(),
            ],
          ),
        ),
      ),
    );
  }

  // Repointed from the old neon-cyan command-center palette to the
  // Kingdom's Ledger tokens; every usage in this screen cascades from here.
  static const Color _commandCyan = GKColors.kingdomBrass;
  static const Color _commandTeal = GKColors.fieldGreen;
  static const Color _commandCoral = GKColors.stampRed;
  static const Color _commandPanel = GKColors.saddleLeather;
  static const Color _commandPanelRaised = GKColors.elevatedLeather;
  static const Color _commandText = GKColors.parchmentWhite;
  static const Color _commandMuted = GKColors.fadedInk;
  static const Color _commandLocked = GKColors.fadedInk;

  Widget _offseasonCommandHeader() {
    final completed = step;
    final progress = (step + 1) / steps.length;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(
        GKSpace.md,
        GKSpace.sm,
        GKSpace.md,
        GKSpace.md,
      ),
      decoration: const BoxDecoration(
        color: Color(0xFF09131F),
        border: Border(
          bottom: BorderSide(color: Color(0xFF244153)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _commandCyan.withOpacity(.10),
                  border: Border.all(
                    color: _commandCyan.withOpacity(.75),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: _commandCyan.withOpacity(.14),
                      blurRadius: 8,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: Text(
                  teamMonogram(widget.team.name),
                  style: GoogleFonts.cinzel(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: _commandCyan,
                  ),
                ),
              ),
              const SizedBox(width: GKSpace.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'OFFSEASON COMMAND CENTER',
                      style: TextStyle(
                        color: _commandCyan,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 2.4,
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${widget.team.displayName} · YEAR ${widget.season}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: _commandText,
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: _commandPanelRaised,
                  border: Border.all(
                    color: _commandCyan.withOpacity(.35),
                  ),
                ),
                child: Text(
                  '$completed/${steps.length - 1}',
                  style: const TextStyle(
                    color: _commandCyan,
                    fontWeight: FontWeight.w900,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: GKSpace.sm),
          ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 6,
              backgroundColor: Color(0xFF1A2A38),
              valueColor: const AlwaysStoppedAnimation<Color>(_commandCyan),
            ),
          ),
        ],
      ),
    );
  }

  Widget _currentStageHero() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(GKSpace.lg),
      decoration: BoxDecoration(
        color: _commandPanelRaised,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: _commandCyan.withOpacity(.42),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(.24),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
          BoxShadow(
            color: _commandCyan.withOpacity(.08),
            blurRadius: 14,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _commandCyan.withOpacity(.12),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: _commandCyan.withOpacity(.55),
                  ),
                ),
                child: Icon(
                  _offseasonStageIcons[step],
                  color: _commandCyan,
                  size: 24,
                ),
              ),
              const SizedBox(width: GKSpace.sm),
              Expanded(
                child: Text(
                  '${_stageEyebrow(step)}  •  $_stageDay',
                  style: const TextStyle(
                    color: _commandCyan,
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.6,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 9,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: _commandCyan.withOpacity(.12),
                  borderRadius: BorderRadius.circular(99),
                  border: Border.all(
                    color: _commandCyan.withOpacity(.45),
                  ),
                ),
                child: Text(
                  'IN PROGRESS',
                  style: TextStyle(
                    color: _commandCyan,
                    fontSize: 8,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.1,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: GKSpace.lg),
          Text(
            _stageName.toUpperCase(),
            style: const TextStyle(
              color: _commandText,
              fontSize: 34,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.2,
              height: 1,
            ),
          ),
          const SizedBox(height: GKSpace.sm),
          Text(
            _stageDescription(step),
            style: const TextStyle(
              color: _commandMuted,
              fontSize: 16,
              fontWeight: FontWeight.w700,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }

  Widget _offseasonCalendar() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'COMMAND ROUTE',
          style: TextStyle(
            color: _commandText,
            fontSize: 14,
            fontWeight: FontWeight.w900,
            letterSpacing: 2.2,
          ),
        ),
        const SizedBox(height: GKSpace.md),
        ...List.generate(_offseasonStageNames.length, (index) {
          final isComplete = index < step;
          final isCurrent = index == step;
          final isFuture = index > step;

          final railColor = isComplete
              ? _commandTeal
              : isCurrent
                  ? _commandCyan
                  : Color(0xFF263C4C);

          return IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 34,
                  child: Column(
                    children: [
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 220),
                        width: isCurrent ? 24 : 18,
                        height: isCurrent ? 24 : 18,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(6),
                          color: isComplete
                              ? _commandTeal
                              : isCurrent
                                  ? _commandCyan
                                  : Color(0xFF1E3242),
                          border: Border.all(
                            color: railColor,
                          ),
                          boxShadow: isCurrent
                              ? [
                                  BoxShadow(
                                    color: _commandCyan.withOpacity(.28),
                                    blurRadius: 8,
                                    offset: const Offset(0, 3),
                                  ),
                                ]
                              : null,
                        ),
                        child: isComplete
                            ? const Icon(
                                Icons.check_rounded,
                                size: 13,
                                color: Color(0xFF071416),
                              )
                            : isCurrent
                                ? const Icon(
                                    Icons.bolt_rounded,
                                    size: 14,
                                    color: Color(0xFF071416),
                                  )
                                : null,
                      ),
                      if (index < _offseasonStageNames.length - 1)
                        Expanded(
                          child: Container(
                            width: 3,
                            color: railColor.withOpacity(
                              isFuture ? .55 : .9,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      GKSpace.sm,
                      0,
                      0,
                      index == _offseasonStageNames.length - 1
                          ? 0
                          : GKSpace.sm,
                    ),
                    child: InkWell(
                      onTap: index <= step
                          ? () => setState(() => step = index)
                          : null,
                      borderRadius: BorderRadius.circular(16),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 220),
                        padding: const EdgeInsets.fromLTRB(
                          GKSpace.md,
                          GKSpace.sm,
                          GKSpace.md,
                          GKSpace.sm,
                        ),
                        decoration: BoxDecoration(
                          color: isCurrent
                              ? _commandCyan.withOpacity(.10)
                              : isComplete
                                  ? _commandPanel.withOpacity(.82)
                                  : Colors.transparent,
                          borderRadius: BorderRadius.circular(16),
                          border: isCurrent
                              ? Border.all(
                                  color: _commandCyan.withOpacity(.45),
                                )
                              : null,
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 34,
                              height: 34,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: isCurrent
                                    ? _commandCyan.withOpacity(.12)
                                    : isComplete
                                        ? _commandTeal.withOpacity(.10)
                                        : Color(0xFF132331),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(
                                _offseasonStageIcons[index],
                                size: 19,
                                color: isCurrent
                                    ? _commandCyan
                                    : isComplete
                                        ? _commandTeal
                                        : _commandLocked,
                              ),
                            ),
                            const SizedBox(width: GKSpace.sm),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _offseasonStageDays[index],
                                    style: TextStyle(
                                      color: isCurrent
                                          ? _commandCyan
                                          : isComplete
                                              ? _commandTeal
                                              : _commandLocked,
                                      fontSize: 9,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: 1.3,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    _offseasonStageNames[index],
                                    style: TextStyle(
                                      color: isFuture
                                          ? _commandMuted.withOpacity(.58)
                                          : _commandText,
                                      fontSize: 15,
                                      fontWeight: isCurrent
                                          ? FontWeight.w900
                                          : FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                color: isComplete
                                    ? _commandTeal.withOpacity(.10)
                                    : isCurrent
                                        ? _commandCyan.withOpacity(.10)
                                        : Color(0xFF132331),
                                borderRadius: BorderRadius.circular(99),
                              ),
                              child: Text(
                                isComplete
                                    ? 'DONE'
                                    : isCurrent
                                        ? 'LIVE'
                                        : 'LOCKED',
                                style: TextStyle(
                                  color: isComplete
                                      ? _commandTeal
                                      : isCurrent
                                          ? _commandCyan
                                          : _commandLocked,
                                  fontSize: 8,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 1,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }

  Widget _stageWorkspace() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 5,
              height: 30,
              decoration: BoxDecoration(
                color: _commandCyan,
                borderRadius: BorderRadius.circular(99),
                boxShadow: [
                  BoxShadow(
                    color: _commandCyan.withOpacity(.28),
                    blurRadius: 7,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
            ),
            const SizedBox(width: GKSpace.sm),
            Expanded(
              child: Text(
                '${_stageName.toUpperCase()} WORKSPACE',
                style: const TextStyle(
                  color: _commandText,
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.7,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: GKSpace.md),
        _body(),
      ],
    );
  }

  Widget _offseasonCommandDock() {
    return Container(
      padding: const EdgeInsets.fromLTRB(
        GKSpace.md,
        GKSpace.sm,
        GKSpace.md,
        GKSpace.md,
      ),
      decoration: const BoxDecoration(
        color: Color(0xFF08121D),
        border: Border(
          top: BorderSide(color: Color(0xFF244153)),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: _commandCyan.withOpacity(.10),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    _offseasonStageIcons[step],
                    color: _commandCyan,
                    size: 19,
                  ),
                ),
                const SizedBox(width: GKSpace.sm),
                Expanded(
                  child: Text(
                    'CURRENT: ${_stageName.toUpperCase()}',
                    style: const TextStyle(
                      color: _commandText,
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
                Text(
                  _stageDay,
                  style: const TextStyle(
                    color: _commandCyan,
                    fontSize: 10,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
            const SizedBox(height: GKSpace.sm),
            SizedBox(
              width: double.infinity,
              height: 60,
              child: OutlinedButton(
                onPressed: () {
                  if (step == steps.length - 1) {
                    AdManager.showAd(
                      context,
                      onContinue: _next,
                    );
                    return;
                  }
                  _next();
                },
                style: OutlinedButton.styleFrom(
                  foregroundColor: _commandText,
                  backgroundColor: _commandCyan.withOpacity(.08),
                  side: const BorderSide(
                    color: _commandCyan,
                    width: 1.5,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  elevation: 0,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Flexible(
                      child: Text(
                        _stageActionText(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: _commandText,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ),
                    const SizedBox(width: GKSpace.sm),
                    const Icon(
                      Icons.arrow_forward_rounded,
                      color: _commandCyan,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    return switch (step) {
      0 => _resultsBody(),
      1 => _jobsBody(),
      2 => _contractBody(),
      3 => _retentionBody(),
      4 => _portalBody(),
      5 => _classBody(),
      6 => _trainingBody(),
      7 => _redshirtBody(),
      _ => _scheduleBody(),
    };
  }

  List<Player> _nationalPlayers() {
    final players = <Player>[];
    for (int i = 0; i < 40; i++) {
      final prestige = 2 + rng.nextInt(4);
      players.addAll(generateRoster(prestige).take(2));
    }
    players.sort((a, b) => awardOverall(b).compareTo(awardOverall(a)));
    return players;
  }


  List<Player> _sharedAllAmericanFirstTeam() {
    final pool = <Player>[...roster];
    final teams = g5Teams.toList();
    final positions = ['QB', 'HB', 'WR', 'TE', 'DE', 'LB', 'DB'];
    final first = ['Brady', 'Jalen', 'Connor', 'Logan', 'Marcus', 'Tyler', 'Caleb', 'Jordan', 'Gavin', 'Anthony'];
    final last = ['Adams', 'Scott', 'Thomas', 'Martin', 'Roberts', 'Mitchell', 'Brown', 'Allen', 'Hall', 'Moore'];

    for (var i = 0; i < teams.length && i < 80; i++) {
      final team = teams[i];
      for (var j = 0; j < positions.length; j++) {
        final pos = positions[j];
        final overall = (88 + ((team.prestige + i + j) % 10)).clamp(86, 98);
        pool.add(Player(
          name: NameGenerator.generate(),
          position: pos,
          year: ['SO', 'JR', 'SR'][(i + j) % 3],
          overall: overall,
          potential: (overall + 1 + ((i + j) % 3)).clamp(overall, 99),
          stars: overall >= 90 ? 5 : 4,
        ));
      }
    }

    pool.sort((a, b) => awardOverall(b).compareTo(awardOverall(a)));

    Player best(List<String> positions) {
      final choices = pool.where((p) => positions.contains(p.position)).toList()
        ..sort((a, b) => awardOverall(b).compareTo(awardOverall(a)));
      return choices.isNotEmpty ? choices.first : pool.first;
    }

    return <Player>{
      best(['QB']),
      best(['HB', 'RB']),
      best(['WR']),
      best(['TE']),
      best(['DE', 'DL', 'LB']),
      best(['DB', 'CB', 'S']),
    }.toList();
  }


  Player _heismanFromFirstTeam(List<Player> firstTeam) {
    if (firstTeam.isEmpty) {
      return Player(name: 'No Player', position: 'QB', year: 'JR', overall: 80, potential: 85, stars: 4);
    }

    final skill = firstTeam.where((p) => ['QB', 'HB', 'RB', 'WR'].contains(p.position)).toList();
    final pool = skill.isNotEmpty ? skill : firstTeam.toList();

    double score(Player p) {
      final ovr = awardOverall(p).toDouble();
      final posBoost = p.position == 'QB'
          ? 10
          : (p.position == 'HB' || p.position == 'RB')
              ? 7
              : p.position == 'WR'
                  ? 6
                  : 0;
      return (ovr * 2.0) + p.teamWins + posBoost;
    }

    pool.sort((a, b) => score(b).compareTo(score(a)));
    return pool.first;
  }

  Widget _awardsCard() {
    return SeasonAwardsCard(
      roster: roster,
      season: widget.season,
      userWins: widget.wins,
      userTeamName: widget.team.name,
    );
  }

  Widget _resultsBody() {
    final score = seasonScoreFor(widget.wins, widget.losses, widget.team.prestige);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _awardsCard(),
        _tripleStat([
          ['${widget.wins}-${widget.losses}', 'RECORD'],
          ['${widget.confWins}-${widget.confLosses}', 'CONF'],
          ['$score', 'SEASON SCORE'],
        ]),
        const SizedBox(height: 18),
        _card(
          child: Text(
            widget.wins >= 10
                ? 'Elite year. Bigger programs and donors are watching.'
                : widget.wins >= 8
                    ? 'Strong year. Your program is moving in the right direction.'
                    : widget.wins >= 6
                        ? 'Bowl-level year. Good, but not enough for a major jump.'
                        : 'Tough season. You need more wins to build job security.',
            style: const TextStyle(color: GKColors.parchmentWhite, fontSize: 18, height: 1.4, fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }

  Widget _awardPlayerRow(Player p) {
    return _card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          PlayerAvatar(seed: p.name.hashCode, teamColor: kGold, size: 38),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '${p.cleanName}\n${p.position} · ${p.year} · ${p.awardTeamName}',
              style: const TextStyle(color: GKColors.parchmentWhite, fontWeight: FontWeight.bold, height: 1.3),
            ),
          ),
          Text('${awardOverall(p)}', style: const TextStyle(color: kGold, fontSize: 24, fontWeight: FontWeight.w900)),
        ],
      ),
    );
  }

  Widget _retentionBody() {
    final leavingCount = retentionCandidates
        .where((p) => !retainedPlayerNames.contains(p.name))
        .length;

    final projectedDraftedSeniors = graduatingPlayers
        .where(
          (player) =>
              awardOverall(player) >= 72 ||
              (awardOverall(player) >= 68 && player.stars >= 4),
        )
        .toList();

    final projectedJuniorDeclarations = draftEligibleJuniors
        .where((player) => !retainedPlayerNames.contains(player.name))
        .toList();

    final projectedDraftClass = <Player>[
      ...projectedDraftedSeniors,
      ...projectedJuniorDeclarations,
    ]..sort((a, b) => awardOverall(b).compareTo(awardOverall(a)));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _tripleStat([
          [moneyText(retentionBudget), 'RETENTION NIL'],
          [moneyText(retentionSpent), 'SPENT'],
          [moneyText(max(0, retentionBudget - retentionSpent)), 'LEFT'],
        ]),
        const SizedBox(height: 18),

        _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'GRADUATING PLAYERS',
                style: TextStyle(
                  color: kGold,
                  fontSize: 19,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 2.5,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Seniors have completed their eligibility. Draftable seniors are listed with their projected NFL result.',
                style: TextStyle(
                  color: GKColors.fadedInk,
                  fontWeight: FontWeight.bold,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 12),
              if (graduatingPlayers.isEmpty)
                Text(
                  'No players are graduating this offseason.',
                  style: TextStyle(
                    color: GKColors.parchmentWhite,
                    fontWeight: FontWeight.bold,
                  ),
                )
              else
                ...graduatingPlayers.map(
                  (p) {
                    final drafted = projectedDraftedSeniors.any(
                      (player) => player.name == p.name,
                    );

                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${p.cleanName} · ${p.position} · ${awardOverall(p)} OVR',
                              style: const TextStyle(
                                color: GKColors.parchmentWhite,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          Text(
                            drafted ? _draftProjection(p) : 'UNDRAFTED',
                            style: TextStyle(
                              color: drafted ? kGold : GKColors.fadedInk,
                              fontSize: 11,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
            ],
          ),
        ),

        const SizedBox(height: 18),
        Row(
          children: [
            const Expanded(
              child: Text(
                'PLAYERS CONSIDERING LEAVING',
                style: TextStyle(
                  color: GKColors.parchmentWhite,
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 2,
                ),
              ),
            ),
            Text(
              '$leavingCount AT RISK',
              style: const TextStyle(
                color: kRed,
                fontWeight: FontWeight.w900,
                fontSize: 12,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Use NIL to retain transfer risks and elite juniors considering the NFL Draft. Unretained juniors will declare when you press Next.',
          style: TextStyle(
            color: GKColors.fadedInk,
            fontWeight: FontWeight.bold,
            height: 1.35,
          ),
        ),
        const SizedBox(height: 12),

        if (retentionCandidates.isEmpty)
          _card(
            child: Text(
              'No players are currently considering leaving.',
              style: TextStyle(
                color: GKColors.parchmentWhite,
                fontWeight: FontWeight.bold,
              ),
            ),
          )
        else
          ...retentionCandidates.map((p) => _playerRetentionCard(p)),

        const SizedBox(height: 18),
        _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'PROJECTED DRAFT RESULTS',
                style: TextStyle(
                  color: kGold,
                  fontSize: 19,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 2.5,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'This updates as you retain or lose draft-eligible juniors.',
                style: TextStyle(
                  color: GKColors.fadedInk,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              if (projectedDraftClass.isEmpty)
                Text(
                  'No players from your program are currently projected to be drafted.',
                  style: TextStyle(
                    color: GKColors.parchmentWhite,
                    fontWeight: FontWeight.bold,
                  ),
                )
              else
                ...projectedDraftClass.map(
                  (p) => Container(
                    margin: const EdgeInsets.only(bottom: 9),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: kDark.withOpacity(.55),
                      border: Border.all(color: kBorder),
                      borderRadius: BorderRadius.circular(13),
                    ),
                    child: Row(
                      children: [
                        PlayerAvatar(
                          seed: p.name.hashCode,
                          teamColor: widget.team.primary,
                          size: 38,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            '${p.cleanName}\n${p.position} · ${p.year} · ${awardOverall(p)} OVR',
                            style: const TextStyle(
                              color: GKColors.parchmentWhite,
                              fontWeight: FontWeight.bold,
                              height: 1.25,
                            ),
                          ),
                        ),
                        Text(
                          '${_draftProjection(p)}\n${_draftTeam(p)}',
                          textAlign: TextAlign.right,
                          style: const TextStyle(
                            color: kGold,
                            fontSize: 11,
                            fontWeight: FontWeight.w900,
                            height: 1.25,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _transitionBody() {
    final t = transitionResult;
    if (t == null) return const SizedBox.shrink();

    Widget section(String title, List<dynamic> items, Color color) {
      return _card(
        margin: const EdgeInsets.only(bottom: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: TextStyle(color: color, fontWeight: FontWeight.w900, letterSpacing: 2)),
            const SizedBox(height: 8),
            if (items.isEmpty)
              Text('None', style: TextStyle(color: GKColors.fadedInk, fontWeight: FontWeight.bold))
            else
              ...items.take(8).map((item) {
                final name = item.name;
                final detail = item is Player
                    ? '${item.position} · ${item.year} · ${item.overall} OVR'
                    : '${item.position} · ${item.stars}★ · ${item.cardOverallText} OVR';
                return Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text('$name — $detail', style: const TextStyle(color: GKColors.parchmentWhite, fontWeight: FontWeight.bold)),
                );
              }),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('COACH TRANSITION', style: TextStyle(color: kGold, fontSize: 22, fontWeight: FontWeight.w900, letterSpacing: 3)),
        const SizedBox(height: 10),
        section('PLAYERS FOLLOWING YOU', t.playersFollowing, kGreen),
        section('RECRUITS FOLLOWING YOU', t.recruitsFollowing, kGreen),
        section('RECRUITS STAYING WITH OLD SCHOOL', t.recruitsStayed, GKColors.fadedInk),
        section('RECRUITS REOPENING RECRUITMENT', t.recruitsReopened, kRed),
      ],
    );
  }

  Widget _contractBody() {
    final contractPrestige = selectedTeam.prestige;
    final contractTier = prestigeTier(contractPrestige);
    final contractExpectedWins = realisticExpectedWins(contractPrestige);
    final contractGoal = realisticContractGoal(contractPrestige);
    final contractSecurity = realisticJobSecurityLabel(contractPrestige);

    final tookNewJob = selectedTeam.name != widget.team.name;
    final score = seasonScoreFor(
      widget.wins,
      widget.losses,
      widget.team.prestige,
    );

    final extension = tookNewJob
        ? 0
        : score >= 82
            ? 3
            : score >= 65
                ? 2
                : score >= 48
                    ? 1
                    : 0;

    final headline = tookNewJob
        ? 'NEW CONTRACT SIGNED'
        : extension > 0
            ? 'CONTRACT EXTENDED'
            : score < 35
                ? 'HOT SEAT'
                : 'NO EXTENSION';

    final detail = tookNewJob
        ? 'You accepted the ${selectedTeam.name} job. New coaches are protected during year one.'
        : extension > 0
            ? '+$extension years added'
            : 'Reach next season’s expectation to improve job security.';

    return Column(
      children: [
        if (selectedTeam.name != widget.team.name) _transitionBody(),
        _card(
          child: Column(
            children: [
              Text(
                headline,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: tookNewJob || extension > 0
                      ? kGreen
                      : score < 35
                          ? kRed
                          : GKColors.fadedInk,
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 3,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                detail,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: GKColors.parchmentWhite,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 18),
              _teamLogo(selectedTeam, 74),
              const SizedBox(height: 12),
              Text(
                selectedTeam.name.toUpperCase(),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: GKColors.parchmentWhite,
                  fontSize: 24,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '${prestigeStars(contractPrestige)}  $contractTier-STAR PROGRAM',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: kGold,
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.4,
                ),
              ),
              const SizedBox(height: 18),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: kDark.withOpacity(.55),
                  border: Border.all(color: kBorder),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  children: [
                    _contractInfoRow(
                      'PROGRAM EXPECTATION',
                      contractGoal,
                    ),
                    const Divider(color: kBorder, height: 24),
                    _contractInfoRow(
                      'EXPECTED REGULAR-SEASON WINS',
                      '$contractExpectedWins',
                    ),
                    const Divider(color: kBorder, height: 24),
                    _contractInfoRow(
                      'JOB PRESSURE',
                      contractSecurity,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _contractInfoRow(String label, String value) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: const TextStyle(
              color: GKColors.fadedInk,
              fontSize: 11,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.4,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: const TextStyle(
              color: GKColors.parchmentWhite,
              fontSize: 14,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
      ],
    );
  }

  Widget _classBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _tripleStat([
          ['${widget.incomingRecruits.length}', 'COMMITS'],
          ['${widget.incomingRecruits.isEmpty ? 0 : (widget.incomingRecruits.map((r) => r.displayedOverall).reduce((a, b) => a + b) / widget.incomingRecruits.length).round()}', 'AVG OVR'],
          [widget.incomingRecruits.isEmpty ? '0.0' : (widget.incomingRecruits.map((r) => r.stars).reduce((a, b) => a + b) / widget.incomingRecruits.length).toStringAsFixed(1), 'AVG ★'],
        ]),
        const SizedBox(height: 18),
        ...widget.incomingRecruits.map((r) => _card(
              margin: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  PlayerAvatar(seed: r.name.hashCode, teamColor: kGold, size: 42),
                  const SizedBox(width: 12),
                  Expanded(child: Text('${r.name}\n${r.position} · ${r.state} · ${r.stars}★', style: const TextStyle(color: GKColors.parchmentWhite, fontWeight: FontWeight.bold))),
                  Text('${r.displayedOverall}', style: const TextStyle(color: kGold, fontSize: 24, fontWeight: FontWeight.w900)),
                ],
              ),
            )),
      ],
    );
  }

  CoachTransitionResult _calculateCoachTransition(CollegeTeam newTeam) {
    final playersFollowing = <Player>[];
    final recruitsFollowing = <Recruit>[];
    final recruitsStayed = <Recruit>[];
    final recruitsReopened = <Recruit>[];

    final prestigeDiff = newTeam.prestige - widget.team.prestige;
    final coachPull = coachRecruitingRating(widget.coach) / 100.0;

    for (final player in roster) {
      final youthBoost = player.year == 'FR' || player.year == 'SO' ? .12 : 0.0;
      final starterBoost = player.overall >= 75 ? .06 : 0.0;
      final chance = (.08 + coachPull * .18 + youthBoost + starterBoost + prestigeDiff * .004).clamp(.03, .42);
      if (rng.nextDouble() < chance) playersFollowing.add(player);
    }

    final committedToYou = recruits.where((r) => r.committedSchool == widget.team.name).toList();
    for (final recruit in committedToYou) {
      final starStay = recruit.stars >= 4 ? .10 : 0.0;
      final chanceFollow = (.20 + coachPull * .35 + prestigeDiff * .006 - starStay).clamp(.08, .72);
      final roll = rng.nextDouble();
      if (roll < chanceFollow) {
        recruitsFollowing.add(recruit);
      } else if (roll < chanceFollow + .45) {
        recruitsStayed.add(recruit);
      } else {
        recruitsReopened.add(recruit);
      }
    }

    return CoachTransitionResult(
      playersFollowing: playersFollowing,
      recruitsFollowing: recruitsFollowing,
      recruitsStayed: recruitsStayed,
      recruitsReopened: recruitsReopened,
    );
  }

  Widget _jobsBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _card(
          child: Row(
            children: [
              _teamLogo(widget.team, 48),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Current Job\n${widget.team.name} · ${prestigeStars(widget.team.prestige)} · ${prestigeTier(widget.team.prestige)}-star program',
                  style: const TextStyle(color: GKColors.parchmentWhite, fontWeight: FontWeight.bold, height: 1.35),
                ),
              ),
              if (selectedTeam.name == widget.team.name)
                Text('STAYING', style: TextStyle(color: kGreen, fontWeight: FontWeight.w900)),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (jobOffers.isEmpty)
          _card(child: Text('No outside job offers this year. Keep building your resume.', style: TextStyle(color: GKColors.parchmentWhite, fontWeight: FontWeight.bold, fontSize: 18)))
        else
          ...jobOffers.map((offer) {
            final team = offer.team;
            final accepted = selectedTeam.name == team.name;
            return _card(
              margin: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  _teamLogo(team, 48),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '${team.name}\n${team.conference} · ${prestigeStars(team.prestige)} · ${prestigeTier(team.prestige)}-star program · ${offer.years} years',
                      style: const TextStyle(color: GKColors.parchmentWhite, fontWeight: FontWeight.bold, height: 1.35),
                    ),
                  ),
                  TextButton(
                    onPressed: () => setState(() {
                      selectedTeam = team;
                      transitionResult = team.name == widget.team.name ? null : _calculateCoachTransition(team);
                    }),
                    child: Text(
                      accepted ? 'ACCEPTED' : 'ACCEPT',
                      style: TextStyle(color: accepted ? kGreen : kGold, fontWeight: FontWeight.w900),
                    ),
                  ),
                ],
              ),
            );
          }),
      ],
    );
  }


  void _showTransferProfile(TransferTarget target) {
    showModalBottomSheet(
      context: context,
      backgroundColor: kCardColor,
      isScrollControlled: true,
      builder: (_) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 54,
                    height: 5,
                    decoration: BoxDecoration(
                      color: GKColors.fadedInk.withOpacity(.75),
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                ),
                const SizedBox(height: 22),
                Text(
                  target.name.toUpperCase(),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: GKColors.parchmentWhite,
                    fontSize: 28,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 4,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '${target.position} • ${target.year} • ${'Former school'}',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: GKColors.fadedInk, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(child: _miniStat('OVR', '${target.overall}', kGold)),
                    const SizedBox(width: 10),
                    Expanded(child: _miniStat('POT', '${target.potential}', GKColors.fieldGreen)),
                    const SizedBox(width: 10),
                    Expanded(child: _miniStat('INT', '${target.interest}%', GKColors.parchmentWhite)),
                  ],
                ),
                const SizedBox(height: 14),
                _card(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('LAST SEASON STATS', style: TextStyle(color: kGold, fontWeight: FontWeight.w900, letterSpacing: 2)),
                      const SizedBox(height: 10),
                      Text(target.transferProfileText, style: const TextStyle(color: GKColors.parchmentWhite, fontSize: 18, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      Text(
                        'Wants a strong depth-chart fit and a winning program.',
                        style: TextStyle(color: GKColors.fadedInk),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _miniStat(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(.28),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: GKColors.parchmentWhite.withOpacity(.10)),
      ),
      child: Column(
        children: [
          Text(value, style: TextStyle(color: color, fontSize: 24, fontWeight: FontWeight.w900)),
          const SizedBox(height: 4),
          Text(label, style: TextStyle(color: GKColors.fadedInk.withOpacity(.85), fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 2)),
        ],
      ),
    );
  }




  Widget _profileStatBox(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(.18),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: GKColors.parchmentWhite.withOpacity(.12)),
      ),
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(color: color, fontSize: 26, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(color: GKColors.fadedInk, fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 2),
          ),
        ],
      ),
    );
  }

  Widget _profileSection({required String title, required List<String> lines}) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(.16),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: GKColors.parchmentWhite.withOpacity(.10)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(color: kGold, fontWeight: FontWeight.w900, letterSpacing: 2)),
          const SizedBox(height: 10),
          ...lines.map(
            (line) => Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(line, style: const TextStyle(color: GKColors.parchmentWhite, fontWeight: FontWeight.bold, height: 1.3)),
            ),
          ),
        ],
      ),
    );
  }


  void _cutRosterPlayer(Player player) {
    final positionCount = roster.where((p) => p.position == player.position).length;
    if (roster.length <= 12 || positionCount <= 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: kCardColor,
          content: Text('Cannot cut ${player.cleanName}. You need enough players and at least one ${player.position}.'),
        ),
      );
      return;
    }

    setState(() {
      roster.removeWhere((p) => p.name == player.name && p.position == player.position);
      redshirtedPlayerNames.remove(player.name);
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: kCardColor,
        content: Text('${player.cleanName} was cut from the roster.'),
      ),
    );
  }

  Future<void> _confirmCutRosterPlayer(Player player) async {
    final shouldCut = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: kCardColor,
        title: Text('Cut Player?', style: TextStyle(color: GKColors.parchmentWhite, fontWeight: FontWeight.w900)),
        content: Text(
          'Remove ${player.cleanName} from your roster?\n\n${player.position} · ${player.year} · ${awardOverall(player)} OVR',
          style: const TextStyle(color: GKColors.parchmentWhite, height: 1.35),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('CANCEL', style: TextStyle(color: GKColors.fadedInk, fontWeight: FontWeight.w900)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('CUT', style: TextStyle(color: kRed, fontWeight: FontWeight.w900)),
          ),
        ],
      ),
    );

    if (shouldCut == true) {
      _cutRosterPlayer(player);
    }
  }

  Widget _portalRosterPlayerRow(Player p) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => _confirmCutRosterPlayer(p),
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: kRed.withOpacity(.14),
                border: Border.all(color: kRed),
                borderRadius: BorderRadius.circular(9),
              ),
              child: const Icon(Icons.close, color: kRed, size: 18),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(width: 38, child: Text(p.position, style: const TextStyle(color: kGold, fontWeight: FontWeight.w900))),
          Expanded(child: Text('${p.cleanName} · ${p.year}', overflow: TextOverflow.ellipsis, style: const TextStyle(color: GKColors.parchmentWhite, fontWeight: FontWeight.bold))),
          Text('${awardOverall(p)}', style: const TextStyle(color: GKColors.parchmentWhite, fontWeight: FontWeight.w900)),
        ],
      ),
    );
  }

  Widget _portalBody() {
    final needs = _positionNeeds();
    final openSlots = max(0, 22 - roster.length);
    final sortedRoster = roster.toList()..sort((a, b) => a.position.compareTo(b.position));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _tripleStat([
          ['${transferTargets.length}', 'TARGETS'],
          ['$openSlots', 'OPEN SLOTS'],
          ['${prestige100(selectedTeam.prestige)}', 'PRESTIGE'],
        ]),
        const SizedBox(height: 16),
        _card(child: Text('No NIL offers here. Transfers judge your school by prestige, winning, playing time, and roster need.', style: TextStyle(color: GKColors.parchmentWhite, fontWeight: FontWeight.bold, height: 1.35))),
        const SizedBox(height: 16),
        _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('YOUR ROSTER', style: TextStyle(color: kGold, fontWeight: FontWeight.w900, letterSpacing: 3)),
              const SizedBox(height: 6),
              Text('Tap the red X to cut a player and open a roster spot.', style: TextStyle(color: GKColors.fadedInk, fontSize: 12, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: needs.entries.map((entry) {
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: entry.value > 0 ? kRed.withOpacity(.14) : kGreen.withOpacity(.10),
                      border: Border.all(color: entry.value > 0 ? kRed : kGreen.withOpacity(.45)),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text('${entry.key} need ${entry.value}', style: TextStyle(color: entry.value > 0 ? kRed : kGreen, fontWeight: FontWeight.w900)),
                  );
                }).toList(),
              ),
              const SizedBox(height: 14),
              ...sortedRoster.take(22).map(_portalRosterPlayerRow),
            ],
          ),
        ),
        const SizedBox(height: 20),
        Text('TRANSFER BOARD', style: TextStyle(color: GKColors.parchmentWhite, fontSize: 22, fontWeight: FontWeight.w900, letterSpacing: 3)),
        const SizedBox(height: 10),
        ...transferTargets.map(_transferCard),
      ],
    );
  }

  Widget _transferCard(TransferTarget transfer) {
    final statusColor = transfer.signed
        ? kGreen
        : transfer.declined
            ? kRed
            : kGold;
    final statusFill = transfer.signed
        ? kGreen.withOpacity(.12)
        : transfer.declined
            ? kRed.withOpacity(.12)
            : Colors.transparent;

    final status = transfer.signed
        ? 'SIGNED'
        : transfer.declined
            ? 'DECLINED'
            : transfer.offered
                ? 'WAITING'
                : 'OFFER';
    final color = transfer.signed
        ? kGreen
        : transfer.declined
            ? kRed
            : kGold;

    return GestureDetector(
      onTap: () => _showTransferProfile(transfer),
      child: _card(
      margin: EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          PlayerAvatar(seed: transfer.name.hashCode, teamColor: widget.team.primary, size: 42),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '${transfer.name}\n${transfer.position} · ${transfer.year} · ${transfer.stars}★ · ${transfer.interest}% interest',
              style: TextStyle(color: GKColors.parchmentWhite, fontWeight: FontWeight.bold, height: 1.35),
            ),
          ),
          Text('${transfer.overall}', style: TextStyle(color: statusColor, fontSize: 26, fontWeight: FontWeight.w900)),
          const SizedBox(width: 10),
          GestureDetector(
            onTap: () => _offerTransfer(transfer),
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: statusFill,
                border: Border.all(color: statusColor),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(status, style: TextStyle(color: statusColor, fontWeight: FontWeight.w900)),
            ),
          ),
        ],
      ),
    ),
    );
  }


  final Map<String, int> _pendingUpgrades = {};

  String _upgradeKey(Player p, String stat) => '${p.cleanName}|$stat';

  int _spentOn(Player p, String stat) => _pendingUpgrades[_upgradeKey(p, stat)] ?? 0;

  void _adjustTrainingStat(Player p, String stat, int delta) {
    final key = _upgradeKey(p, stat);
    final current = _pendingUpgrades[key] ?? 0;
    if (delta > 0 && trainingPoints <= 0) return;
    if (delta < 0 && current <= 0) return;

    setState(() {
      _pendingUpgrades[key] = (current + delta).clamp(0, 99);
      trainingPoints -= delta;
      if (_pendingUpgrades[key] == 0) _pendingUpgrades.remove(key);
    });
  }

  Widget _upgradeStepper(Player p, String stat) {
    final spent = _spentOn(p, stat);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          visualDensity: VisualDensity.compact,
          onPressed: spent > 0 ? () => _adjustTrainingStat(p, stat, -1) : null,
          icon: const Icon(Icons.remove_circle_outline, color: GKColors.stampRed),
        ),
        Text('+$spent', style: const TextStyle(color: kGold, fontWeight: FontWeight.w900)),
        IconButton(
          visualDensity: VisualDensity.compact,
          onPressed: trainingPoints > 0 ? () => _adjustTrainingStat(p, stat, 1) : null,
          icon: const Icon(Icons.add_circle_outline, color: GKColors.fieldGreen),
        ),
      ],
    );
  }

  Widget _trainingBody() {
    final sorted = roster.toList()..sort((a, b) => awardOverall(b).compareTo(awardOverall(a)));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _tripleStat([
          ['$trainingPoints', 'POINTS'],
          ['10', 'COST'],
          ['+ / −', 'TRIAL'],
        ]),
        const SizedBox(height: 18),
        ...sorted.map((p) => _trainingPlayerCard(p)),
      ],
    );
  }


  Widget _redshirtBody() {
    final eligible = roster
        .where((p) => p.year == 'FR' || p.year == 'SO')
        .toList()
      ..sort((a, b) {
        final byYear = a.year.compareTo(b.year);
        if (byYear != 0) return byYear;
        return a.overall.compareTo(b.overall);
      });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              Text('REDSHIRT PLAYERS', style: TextStyle(color: kGold, fontSize: 22, fontWeight: FontWeight.w900, letterSpacing: 3)),
              SizedBox(height: 10),
              Text(
                'Choose freshmen or sophomores to redshirt before setting next year’s schedule. Redshirted players are marked and treated as developmental players for the upcoming season.',
                style: TextStyle(color: GKColors.fadedInk, fontWeight: FontWeight.bold, height: 1.35),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _tripleStat([
          ['${redshirtedPlayerNames.length}', 'REDSHIRTS'],
          ['FR / SO', 'ELIGIBLE'],
          ['DEV', 'FOCUS'],
        ]),
        const SizedBox(height: 18),
        if (eligible.isEmpty)
          _card(
            child: Text(
              'No eligible freshmen or sophomores are available to redshirt.',
              style: TextStyle(color: GKColors.fadedInk, fontWeight: FontWeight.bold),
            ),
          )
        else
          ...eligible.map((p) => _redshirtPlayerCard(p)),
      ],
    );
  }

  Widget _redshirtPlayerCard(Player p) {
    final isRedshirted = redshirtedPlayerNames.contains(p.name);
    final canRedshirt = p.year == 'FR' || p.year == 'SO';

    return _card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          PlayerAvatar(seed: p.name.hashCode, teamColor: widget.team.primary, size: 42),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '${p.cleanName}\n${p.position} · ${p.year} · ${awardOverall(p)} OVR · POT ${p.potential}',
              style: const TextStyle(color: GKColors.parchmentWhite, fontWeight: FontWeight.bold, height: 1.25),
            ),
          ),
          GestureDetector(
            onTap: !canRedshirt
                ? null
                : () {
                    setState(() {
                      if (isRedshirted) {
                        redshirtedPlayerNames.remove(p.name);
                      } else {
                        redshirtedPlayerNames.add(p.name);
                      }
                    });
                  },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: isRedshirted ? kGreen.withOpacity(.14) : kGold.withOpacity(.14),
                border: Border.all(color: isRedshirted ? kGreen : kGold),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                isRedshirted ? 'REDSHIRTED' : 'REDSHIRT',
                style: TextStyle(
                  color: isRedshirted ? kGreen : kGold,
                  fontWeight: FontWeight.w900,
                  fontSize: 12,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _scheduleBody() {
    final optionMap = <String, CollegeTeam>{};
    for (final team in g5Teams) {
      if (team.name != widget.team.name) {
        optionMap[team.name] = team;
      }
    }

    final allOptions = optionMap.values.toList()
      ..sort((a, b) => b.prestige.compareTo(a.prestige));

    final nonConferenceOptions = allOptions
        .where((team) => team.conference != widget.team.conference)
        .toList();

    CollegeTeam? teamByName(String? name) {
      if (name == null) return null;
      return optionMap[name];
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('RIVALRY', style: TextStyle(color: kGold, fontWeight: FontWeight.w900, letterSpacing: 3)),
              const SizedBox(height: 12),
              Text(
                rivalryTeam == null ? 'No rivalry selected' : 'Rivalry: ${rivalryTeam!.name}',
                style: const TextStyle(color: GKColors.parchmentWhite, fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              DropdownButton<String>(
                value: rivalryTeam?.name,
                dropdownColor: kCardColor,
                hint: Text('Choose Rivalry', style: TextStyle(color: GKColors.fadedInk)),
                isExpanded: true,
                items: allOptions.take(80).map((team) {
                  return DropdownMenuItem<String>(
                    value: team.name,
                    child: Text('${team.name} · ${team.conference} · P${prestige100(team.prestige)}', style: const TextStyle(color: GKColors.parchmentWhite)),
                  );
                }).toList(),
                onChanged: (name) => setState(() => rivalryTeam = teamByName(name)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('NON-CONFERENCE GAMES', style: TextStyle(color: kGold, fontWeight: FontWeight.w900, letterSpacing: 3)),
              const SizedBox(height: 12),
              DynastyButton(text: 'Randomize 3 Games', onPressed: _randomizeNonConference),
              const SizedBox(height: 12),
              ...List.generate(3, (i) {
                final currentValue = i < customNonConference.length ? customNonConference[i].name : null;

                final usedNames = customNonConference
                    .asMap()
                    .entries
                    .where((entry) => entry.key != i)
                    .map((entry) => entry.value.name)
                    .toSet();

                final menuItems = nonConferenceOptions
                    .where((team) => !usedNames.contains(team.name) || team.name == currentValue)
                    .take(80)
                    .map((team) {
                      return DropdownMenuItem<String>(
                        value: team.name,
                        child: Text('${team.name} · ${team.conference} · P${prestige100(team.prestige)}', style: const TextStyle(color: GKColors.parchmentWhite)),
                      );
                    }).toList();

                final safeValue = currentValue != null && menuItems.any((item) => item.value == currentValue)
                    ? currentValue
                    : null;

                return DropdownButton<String>(
                  value: safeValue,
                  dropdownColor: kCardColor,
                  hint: Text('Game ${i + 1}', style: const TextStyle(color: GKColors.fadedInk)),
                  isExpanded: true,
                  items: menuItems,
                  onChanged: (name) {
                    final team = teamByName(name);
                    if (team == null) return;

                    setState(() {
                      while (customNonConference.length <= i) {
                        final filler = nonConferenceOptions.firstWhere(
                          (candidate) => !customNonConference.any((picked) => picked.name == candidate.name),
                          orElse: () => nonConferenceOptions.first,
                        );
                        customNonConference.add(filler);
                      }
                      customNonConference[i] = team;
                    });
                  },
                );
              }),
            ],
          ),
        ),
      ],
    );
  }

  Widget _playerRetentionCard(Player p) {
    final ask = playerRetentionAsk(p);
    final paid = retainedPlayerNames.contains(p.name);

    return _card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          PlayerAvatar(seed: p.name.hashCode, teamColor: widget.team.primary, size: 42),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '${p.cleanName}\n${p.position} · ${p.year} · ${awardOverall(p)} OVR\n${paid ? 'Returning to ${selectedTeam.name}' : _isJuniorDraftCandidate(p) ? 'Considering NFL Draft · ${_draftProjection(p)}' : 'Projected destination: ${_projectedTransferDestination(p)}'}',
              style: const TextStyle(color: GKColors.parchmentWhite, fontWeight: FontWeight.bold, height: 1.25),
            ),
          ),
          Text(moneyText(ask), style: const TextStyle(color: kGold, fontWeight: FontWeight.w900)),
          const SizedBox(width: 10),
          GestureDetector(
            onTap: () => _retainPlayer(p),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(color: paid ? kGreen.withOpacity(.16) : kGold.withOpacity(.16), border: Border.all(color: paid ? kGreen : kGold), borderRadius: BorderRadius.circular(12)),
              child: Text(paid ? 'KEPT' : 'PAY', style: TextStyle(color: paid ? kGreen : kGold, fontWeight: FontWeight.w900)),
            ),
          ),
        ],
      ),
    );
  }
  Widget _trainingPlayerCard(Player p) {
    final basePlayer = _baseTrainingPlayer(p);
    final baseSkills = playerSkillRatings(basePlayer);
    final boosts = playerSkillBoosts[p.name] ?? {};
    final canUpgrade = trainingPoints >= 10 && p.overall < p.potential;
    final baseOverall = trainingBaseOveralls[p.name] ?? p.overall;
    final overallGain = p.overall - baseOverall;

    return _card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Column(
        children: [
          Row(
            children: [
              PlayerAvatar(seed: p.name.hashCode, teamColor: widget.team.primary, size: 42),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '${p.cleanName}\n${p.position} · ${p.year} · POT ${p.potential}${overallGain > 0 ? ' · +$overallGain OVR' : ''}',
                  style: const TextStyle(color: GKColors.parchmentWhite, fontWeight: FontWeight.bold),
                ),
              ),
              Text('${awardOverall(p)}', style: const TextStyle(color: kGold, fontSize: 26, fontWeight: FontWeight.w900)),
            ],
          ),
          const SizedBox(height: 12),
          ...baseSkills.entries.map((entry) {
            final boost = boosts[entry.key] ?? 0;
            final rating = (entry.value + boost).clamp(40, 94);
            final canRemove = boost > 0;

            return Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      entry.key.toUpperCase(),
                      style: const TextStyle(color: GKColors.fadedInk, fontWeight: FontWeight.w900, letterSpacing: 1.5),
                    ),
                  ),
                  Text(
                    '$rating${boost > 0 ? ' +$boost' : ''}',
                    style: const TextStyle(color: GKColors.parchmentWhite, fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(width: 10),
                  GestureDetector(
                    onTap: canRemove ? () => _removePlayerSkill(p, entry.key) : null,
                    child: Container(
                      width: 38,
                      height: 34,
                      decoration: BoxDecoration(
                        color: canRemove ? kRed.withOpacity(.16) : kBorder,
                        border: Border.all(color: canRemove ? kRed : GKColors.fadedInk.withOpacity(.55)),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(Icons.remove, color: canRemove ? kRed : GKColors.fadedInk, size: 18),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: canUpgrade ? () => _upgradePlayerSkill(p, entry.key) : null,
                    child: Container(
                      width: 44,
                      height: 34,
                      decoration: BoxDecoration(
                        color: canUpgrade ? kGold : kBorder,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Center(
                        child: Text(
                          '+1',
                          style: TextStyle(color: canUpgrade ? GKColors.inkBlack : GKColors.fadedInk, fontWeight: FontWeight.w900),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }


  Widget _tripleStat(List<List<String>> stats) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 18),
      decoration: BoxDecoration(color: kCardColor, border: Border.all(color: kBorder), borderRadius: BorderRadius.circular(20)),
      child: Row(
        children: stats.map((s) => Expanded(
          child: Column(children: [
            Text(s[0], style: const TextStyle(color: kGold, fontSize: 28, fontWeight: FontWeight.w900)),
            const SizedBox(height: 6),
            Text(s[1], style: const TextStyle(color: GKColors.fadedInk, fontWeight: FontWeight.w900, letterSpacing: 2)),
          ]),
        )).toList(),
      ),
    );
  }

  Widget _card({required Widget child, EdgeInsets? margin}) {
    return Container(
      margin: margin,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(color: kCardColor, border: Border.all(color: kBorder), borderRadius: BorderRadius.circular(20)),
      child: child,
    );
  }

  Widget _teamLogo(CollegeTeam team, double size) =>
      GKTeamBadge(team: team, size: size);
}


class GameCompletionResult {
  final bool won;
  final PressConferenceResult pressConference;

  const GameCompletionResult({
    required this.won,
    required this.pressConference,
  });
}


enum _DriveOutcome {
  touchdown,
  fieldGoal,
  turnover,
  explosivePlay,
  threeAndOut,
  punt,
}

/// A yard-line diagram sketched on the ledger page, not a photoreal turf
/// render — hairline yard markers, tinted end zones in each team's own
/// color, and a small brass football marking the ball's synthetic field
/// position for the current drive.
class _FootballFieldPainter extends CustomPainter {
  final double yardPosition; // 0 (home goal line) .. 100 (away goal line)
  final Color homeColor;
  final Color awayColor;
  final String homeAbbr;
  final String awayAbbr;
  final bool possessionIsUser;

  const _FootballFieldPainter({
    required this.yardPosition,
    required this.homeColor,
    required this.awayColor,
    required this.homeAbbr,
    required this.awayAbbr,
    required this.possessionIsUser,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final endzone = size.width * 0.09;
    final fieldLeft = endzone;
    final fieldWidth = size.width - endzone * 2;
    final top = size.height * 0.10;
    final bottom = size.height * 0.90;
    double xFor(double yard) => fieldLeft + fieldWidth * (yard / 100);

    final fieldRect = Rect.fromLTRB(fieldLeft, top, fieldLeft + fieldWidth, bottom);

    // A real green field with each team's own color filling its end zone.
    canvas.drawRect(fieldRect, Paint()..color = GKColors.fieldGreen);
    canvas.drawRect(
      Rect.fromLTRB(0, top, endzone, bottom),
      Paint()..color = homeColor,
    );
    canvas.drawRect(
      Rect.fromLTRB(fieldLeft + fieldWidth, top, size.width, bottom),
      Paint()..color = awayColor,
    );

    final outline = Paint()
      ..color = GKColors.inkBlack.withOpacity(.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    canvas.drawRect(Rect.fromLTRB(0, top, size.width, bottom), outline);
    canvas.drawLine(Offset(fieldLeft, top), Offset(fieldLeft, bottom), outline);
    canvas.drawLine(Offset(fieldLeft + fieldWidth, top),
        Offset(fieldLeft + fieldWidth, bottom), outline);

    // Yard lines every 10, numbered, 50 bolder.
    final line = Paint()
      ..color = GKColors.inkBlack.withOpacity(.32)
      ..strokeWidth = 1;
    final midline = Paint()
      ..color = GKColors.inkBlack.withOpacity(.55)
      ..strokeWidth = 1.6;
    for (var yard = 0; yard <= 100; yard += 10) {
      final x = xFor(yard.toDouble());
      canvas.drawLine(Offset(x, top), Offset(x, bottom), yard == 50 ? midline : line);
      if (yard == 0 || yard == 100) continue;
      final number = yard <= 50 ? yard : 100 - yard;
      final tp = TextPainter(
        text: TextSpan(
          text: '$number',
          style: GoogleFonts.zillaSlab(
            fontSize: size.height * .14,
            fontWeight: FontWeight.w700,
            color: GKColors.inkBlack.withOpacity(.45),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x - tp.width / 2, top + 3));
    }

    // Hash ticks every 5 yards.
    final tick = Paint()
      ..color = GKColors.inkBlack.withOpacity(.28)
      ..strokeWidth = 1;
    for (var yard = 5; yard < 100; yard += 5) {
      if (yard % 10 == 0) continue;
      final x = xFor(yard.toDouble());
      canvas.drawLine(Offset(x, top), Offset(x, top + 6), tick);
      canvas.drawLine(Offset(x, bottom - 6), Offset(x, bottom), tick);
    }

    void endzoneLabel(String text, double cx, Color bg) {
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: GoogleFonts.cinzel(
            fontSize: size.height * .16,
            fontWeight: FontWeight.w700,
            color: gkReadableOn(bg),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      canvas.save();
      canvas.translate(cx, size.height / 2);
      canvas.rotate(-pi / 2);
      tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
      canvas.restore();
    }

    endzoneLabel(homeAbbr, endzone / 2, homeColor);
    endzoneLabel(awayAbbr, size.width - endzone / 2, awayColor);

    // Ball marker with a grounding shadow and a small drive-direction chevron.
    final ballX = xFor(yardPosition.clamp(0, 100));
    final ballY = size.height / 2;
    final shadow = Paint()..color = Colors.black.withOpacity(.25);
    canvas.drawOval(
      Rect.fromCenter(center: Offset(ballX, ballY + 5), width: 13, height: 5),
      shadow,
    );

    final ballPaint = Paint()..color = GKColors.kingdomBrass;
    final ballOutline = Paint()
      ..color = GKColors.inkBlack
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1;
    final ballRect = Rect.fromCenter(center: Offset(ballX, ballY), width: 15, height: 8);
    canvas.drawOval(ballRect, ballPaint);
    canvas.drawOval(ballRect, ballOutline);
    canvas.drawLine(
      Offset(ballX - 4, ballY),
      Offset(ballX + 4, ballY),
      Paint()
        ..color = GKColors.inkBlack
        ..strokeWidth = 1,
    );

    final dir = possessionIsUser ? 1 : -1;
    final chevron = Path()
      ..moveTo(ballX + dir * 11, ballY)
      ..lineTo(ballX + dir * 16, ballY - 4)
      ..moveTo(ballX + dir * 11, ballY)
      ..lineTo(ballX + dir * 16, ballY + 4);
    canvas.drawPath(
      chevron,
      Paint()
        ..color = GKColors.inkBlack.withOpacity(.6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4,
    );
  }

  @override
  bool shouldRepaint(covariant _FootballFieldPainter oldDelegate) =>
      oldDelegate.yardPosition != yardPosition ||
      oldDelegate.possessionIsUser != possessionIsUser ||
      oldDelegate.homeColor != homeColor ||
      oldDelegate.awayColor != awayColor;
}

class GameSimScreen extends StatefulWidget {
  final CollegeTeam team;
  final CollegeTeam opponent;
  final int teamOvr;
  final int opponentOvr;
  final int teamRank;
  final int opponentRank;
  final ValueChanged<GameCompletionResult> onFinished;

  const GameSimScreen({
    super.key,
    required this.team,
    required this.opponent,
    required this.teamOvr,
    required this.opponentOvr,
    this.teamRank = 999,
    this.opponentRank = 999,
    required this.onFinished,
  });

  @override
  State<GameSimScreen> createState() => _GameSimScreenState();
}

class _GameSimScreenState extends State<GameSimScreen>
    with SingleTickerProviderStateMixin {
  // Repointed from the old neon-cyan game-sim palette to the Kingdom's
  // Ledger tokens; every usage in this screen cascades from here.
  static const Color _gameCyan = GKColors.kingdomBrass;
  static const Color _gameTeal = GKColors.fieldGreen;
  static const Color _gameCoral = GKColors.stampRed;
  static const Color _gamePanel = GKColors.saddleLeather;
  static const Color _gamePanelRaised = GKColors.elevatedLeather;
  static const Color _gameText = GKColors.parchmentWhite;
  static const Color _gameMuted = GKColors.fadedInk;
  final List<String> plays = [];

  // Field visualization: the sim resolves whole drives (touchdown, field
  // goal, turnover, explosive play, punt, three-and-out) rather than
  // tracking real per-play yardage, so field position here is a synthetic,
  // display-only reconstruction driven by each drive's outcome — it never
  // feeds back into the score/turnover logic above.
  late final AnimationController _fieldController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 750),
  );
  late final Animation<double> _fieldCurve = CurvedAnimation(
    parent: _fieldController,
    curve: Curves.easeOutCubic,
  );
  double _ballYardFrom = 25;
  double _ballYardTo = 25;
  bool _fieldPossessionIsUser = true;

  double get _ballYard =>
      _ballYardFrom + (_ballYardTo - _ballYardFrom) * _fieldCurve.value;

  void _animateDriveOnField(bool userBall, _DriveOutcome outcome) {
    final start = userBall ? 25.0 : 75.0;
    final dir = userBall ? 1.0 : -1.0;
    double end;
    switch (outcome) {
      case _DriveOutcome.touchdown:
        end = userBall ? 100.0 : 0.0;
      case _DriveOutcome.fieldGoal:
        end = start + dir * (35 + rng.nextDouble() * 15);
      case _DriveOutcome.explosivePlay:
        end = start + dir * (38 + rng.nextDouble() * 20);
      case _DriveOutcome.turnover:
        end = start + dir * (8 + rng.nextDouble() * 12);
      case _DriveOutcome.threeAndOut:
        end = start + dir * (2 + rng.nextDouble() * 6);
      case _DriveOutcome.punt:
        end = start + dir * (28 + rng.nextDouble() * 14);
    }
    _ballYardFrom = _ballYard;
    _ballYardTo = end.clamp(2.0, 98.0);
    _fieldPossessionIsUser = userBall;
    _fieldController.forward(from: 0);
  }

  int teamScore = 0;
  int opponentScore = 0;
  int quarter = 1;
  int drive = 0;
  int teamTouchdowns = 0;
  int opponentTouchdowns = 0;
  int teamFieldGoals = 0;
  int opponentFieldGoals = 0;
  int teamTurnovers = 0;
  int opponentTurnovers = 0;
  int teamBigPlays = 0;
  int opponentBigPlays = 0;

  bool gameStarted = false;
  bool finished = false;
  bool resultSent = false;
  bool autoRunning = false;
  double speed = 1;
  int selectedGameTab = 0;
  double momentum = 0;
  bool halftimeInserted = false;

  String get _broadcastLabel {
    if (widget.teamRank <= 10 || widget.opponentRank <= 10) {
      return 'PRIME WINDOW';
    }
    if (widget.teamRank <= 25 || widget.opponentRank <= 25) {
      return 'NATIONAL WINDOW';
    }
    return 'KINGDOM GAMECAST';
  }

  String get _stakesLabel {
    if (widget.teamRank <= 12 && widget.opponentRank <= 12) {
      return 'PLAYOFF IMPACT';
    }
    if (widget.team.conference == widget.opponent.conference) {
      return 'CONFERENCE GAME';
    }
    if (widget.teamRank <= 25 || widget.opponentRank <= 25) {
      return 'RANKED MATCHUP';
    }
    return 'REGULAR SEASON';
  }

  String get _weatherLabel {
    final value =
        (widget.team.name.length * 7 + widget.opponent.name.length * 11) % 5;

    return switch (value) {
      0 => 'Clear · 68°',
      1 => 'Cloudy · 57°',
      2 => 'Light rain · 52°',
      3 => 'Windy · 49°',
      _ => 'Clear · 74°',
    };
  }

  String get _spreadLabel {
    final raw = (widget.teamOvr - widget.opponentOvr) * .72;
    final rounded = ((raw * 2).round() / 2).clamp(-28, 28);

    if (rounded == 0) return 'PICK';
    return rounded > 0
        ? '${widget.team.name} -${rounded.toStringAsFixed(1)}'
        : '${widget.opponent.name} -${rounded.abs().toStringAsFixed(1)}';
  }

  double get _overUnder {
    final base = 43.5 +
        ((widget.teamOvr + widget.opponentOvr - 140) * .32) +
        ((widget.team.name.length + widget.opponent.name.length) % 5);
    return (base * 2).round() / 2;
  }

  String get _overUnderLabel =>
      'O/U ${_overUnder.toStringAsFixed(1)}';

  String get _venueLabel {
    final stadium = switch (widget.opponent.name.hashCode.abs() % 6) {
      0 => 'Kingdom Field',
      1 => 'Memorial Stadium',
      2 => 'Legends Stadium',
      3 => 'Champions Field',
      4 => 'University Stadium',
      _ => 'National Stadium',
    };
    return '$stadium · ${widget.opponent.name}';
  }

  String get _kickoffLabel {
    return switch (
        (widget.team.name.length + widget.opponent.name.length) % 4) {
      0 => '12:00 PM ET',
      1 => '3:30 PM ET',
      2 => '7:30 PM ET',
      _ => '8:00 PM ET',
    };
  }

  int get _attendance {
    final rankedBoost =
        (widget.teamRank <= 25 || widget.opponentRank <= 25) ? 9000 : 0;
    final conferenceBoost =
        widget.team.conference == widget.opponent.conference ? 5500 : 0;
    return (38500 +
            widget.opponentOvr * 310 +
            rankedBoost +
            conferenceBoost)
        .clamp(42000, 108000);
  }

  String get _crowdLabel {
    if (_attendance >= 90000) return 'HOSTILE SELLOUT';
    if (_attendance >= 70000) return 'PACKED HOUSE';
    return 'STRONG CROWD';
  }

  List<String> get _storylines {
    final stories = <String>[];

    if (widget.teamRank <= 12 && widget.opponentRank <= 12) {
      stories.add('KP ELIMINATION GAME');
    } else if (widget.teamRank <= 25 &&
        widget.opponentRank <= 25) {
      stories.add('TOP 25 MATCHUP');
    }

    if (widget.team.conference == widget.opponent.conference) {
      stories.add('CONFERENCE IMPLICATIONS');
    }

    if ((widget.team.name.hashCode - widget.opponent.name.hashCode)
            .abs() %
        5 ==
        0) {
      stories.add('RIVALRY ENERGY');
    }

    if (_weatherLabel.contains('rain') ||
        _weatherLabel.contains('Windy')) {
      stories.add('WEATHER COULD MATTER');
    }

    if (_broadcastLabel.contains('NATIONAL')) {
      stories.add('NATIONAL TV SPOTLIGHT');
    }

    stories.add(
      widget.teamOvr >= widget.opponentOvr
          ? '${widget.team.name.toUpperCase()} ENTERS FAVORED'
          : '${widget.team.name.toUpperCase()} SEEKS THE UPSET',
    );

    return stories.take(4).toList();
  }

  List<(String, String, String)> get _teamLeaders {
    final seed = widget.team.name.hashCode.abs();
    final first1 =
        NameGenerator.firstNames[seed % NameGenerator.firstNames.length];
    final last1 =
        NameGenerator.lastNames[(seed * 3) % NameGenerator.lastNames.length];
    final first2 = NameGenerator
        .firstNames[(seed + 17) % NameGenerator.firstNames.length];
    final last2 = NameGenerator
        .lastNames[(seed * 5 + 7) % NameGenerator.lastNames.length];
    final first3 = NameGenerator
        .firstNames[(seed + 31) % NameGenerator.firstNames.length];
    final last3 = NameGenerator
        .lastNames[(seed * 7 + 13) % NameGenerator.lastNames.length];

    return [
      ('$first1 $last1', 'QB', '${2650 + widget.teamOvr * 11} YDS · ${18 + widget.teamOvr ~/ 5} TD'),
      ('$first2 $last2', 'HB', '${720 + widget.teamOvr * 6} RUSH YDS'),
      ('$first3 $last3', 'DEF', '${6 + widget.teamOvr ~/ 12} SACKS'),
    ];
  }

  List<String> get _aroundNationScores {
    final teams = g5Teams
        .where(
          (team) =>
              team.name != widget.team.name &&
              team.name != widget.opponent.name,
        )
        .take(6)
        .toList();

    if (teams.length < 6) return const [];

    return [
      '${teams[0].name} ${10 + teams[0].prestige % 24} · ${teams[1].name} ${7 + teams[1].prestige % 20} · HALF',
      '${teams[2].name} ${13 + teams[2].prestige % 21} · ${teams[3].name} ${6 + teams[3].prestige % 18} · 3Q',
      '${teams[4].name} ${17 + teams[4].prestige % 18} · ${teams[5].name} ${10 + teams[5].prestige % 17} · HALF',
    ];
  }

  String get _socialReaction {
    final won = teamScore > opponentScore;
    final margin = (teamScore - opponentScore).abs();

    if (won && widget.opponentRank <= 25) {
      return '@KingdomSaturday · ${widget.team.name} delivers a season-defining ranked win.';
    }
    if (won && margin >= 21) {
      return '@CFBAlerts · ${widget.team.name} makes a statement in dominant fashion.';
    }
    if (won) {
      return '@SaturdayCentral · ${widget.team.name} survives and keeps the season moving.';
    }
    if (margin <= 7) {
      return '@CollegeFootballNow · ${widget.team.name} falls just short in a thriller.';
    }
    return '@GridironReport · ${widget.team.name} must regroup after a difficult result.';
  }

  String get _clockLabel {
    if (finished) return 'FINAL';
    final drivesInQuarter = drive % 7;
    final minutes = max(0, 15 - drivesInQuarter * 2);
    final seconds = (drive * 17) % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  String get _quarterLabel {
    if (finished) return 'FINAL';
    if (!gameStarted) return 'PREGAME';
    return quarter > 4 ? 'OT' : 'Q$quarter';
  }

  bool get _userHasBall => drive % 2 == 0;

  String get _momentumText {
    if (momentum >= .58) return '${widget.team.name} SURGING';
    if (momentum >= .18) return '${widget.team.name} EDGE';
    if (momentum <= -.58) return '${widget.opponent.name} SURGING';
    if (momentum <= -.18) return '${widget.opponent.name} EDGE';
    return 'EVEN';
  }

  Color get _momentumColor {
    if (momentum > .12) return widget.team.primary;
    if (momentum < -.12) return widget.opponent.primary;
    return _gameMuted;
  }

  @override
  void initState() {
    super.initState();
    plays.add(
      '${rankedDisplayName(widget.team, widget.teamRank)} and '
      '${rankedDisplayName(widget.opponent, widget.opponentRank)} '
      'are preparing for kickoff.',
    );
  }

  @override
  void dispose() {
    _fieldController.dispose();
    super.dispose();
  }

  void _beginGame() {
    if (gameStarted || finished) return;

    setState(() {
      gameStarted = true;
      plays.insert(
        0,
        'Kickoff: ${widget.team.name} vs ${widget.opponent.name}.',
      );
    });

    _startAuto();
  }

  Future<void> _startAuto() async {
    if (finished) return;

    if (!gameStarted) {
      setState(() => gameStarted = true);
    }

    setState(() => autoRunning = true);

    while (autoRunning && !finished && mounted) {
      _simPlay();
      final delay = (920 / speed).round();
      await Future.delayed(Duration(milliseconds: delay));
    }
  }

  void _stopAuto() {
    if (!mounted) return;
    setState(() => autoRunning = false);
  }

  void _addPlay(String text, {required bool userPositive}) {
    plays.insert(0, text);

    final shift = userPositive ? .15 : -.15;
    momentum = (momentum * .72 + shift).clamp(-1, 1);
  }

  void _simPlay() {
    if (finished) return;

    final userBall = drive % 2 == 0;
    final offense = userBall ? widget.team.name : widget.opponent.name;
    final offOvr = userBall ? widget.teamOvr : widget.opponentOvr;
    final defOvr = userBall ? widget.opponentOvr : widget.teamOvr;
    final diff = offOvr - defOvr;

    final tdChance = (0.105 + diff * 0.006).clamp(0.018, 0.28);
    final fgChance = (0.078 + diff * 0.0025).clamp(0.020, 0.16);
    final turnoverChance = (0.105 - diff * 0.002).clamp(0.045, 0.22);
    final bigPlayChance = (0.100 + diff * 0.003).clamp(0.035, 0.20);
    final roll = rng.nextDouble();

    setState(() {
      if (roll < tdChance) {
        if (userBall) {
          teamScore += 7;
          teamTouchdowns++;
        } else {
          opponentScore += 7;
          opponentTouchdowns++;
        }

        _addPlay(
          'Q$quarter · TOUCHDOWN — $offense finishes a complete scoring drive. '
          '$teamScore-$opponentScore',
          userPositive: userBall,
        );
        _animateDriveOnField(userBall, _DriveOutcome.touchdown);
      } else if (roll < tdChance + fgChance) {
        if (userBall) {
          teamScore += 3;
          teamFieldGoals++;
        } else {
          opponentScore += 3;
          opponentFieldGoals++;
        }

        _addPlay(
          'Q$quarter · FIELD GOAL — $offense takes the points. '
          '$teamScore-$opponentScore',
          userPositive: userBall,
        );
        _animateDriveOnField(userBall, _DriveOutcome.fieldGoal);
      } else if (roll <
          tdChance + fgChance + turnoverChance) {
        if (userBall) {
          teamTurnovers++;
        } else {
          opponentTurnovers++;
        }

        _addPlay(
          'Q$quarter · TURNOVER — $offense gives the ball away under pressure.',
          userPositive: !userBall,
        );
        _animateDriveOnField(userBall, _DriveOutcome.turnover);
      } else if (roll <
          tdChance + fgChance + turnoverChance + bigPlayChance) {
        if (userBall) {
          teamBigPlays++;
        } else {
          opponentBigPlays++;
        }

        _addPlay(
          'Q$quarter · EXPLOSIVE PLAY — $offense flips the field before the drive stalls.',
          userPositive: userBall,
        );
        _animateDriveOnField(userBall, _DriveOutcome.explosivePlay);
      } else if (diff < -22 && rng.nextDouble() < .48) {
        _addPlay(
          'Q$quarter · THREE-AND-OUT — $offense is overwhelmed at the line.',
          userPositive: !userBall,
        );
        _animateDriveOnField(userBall, _DriveOutcome.threeAndOut);
      } else {
        _addPlay(
          'Q$quarter · PUNT — $offense cannot sustain the drive.',
          userPositive: !userBall,
        );
        _animateDriveOnField(userBall, _DriveOutcome.punt);
      }

      drive++;
      quarter = (drive ~/ 7) + 1;

      if (drive == 14 && !halftimeInserted) {
        halftimeInserted = true;
        plays.insert(
          0,
          'HALFTIME · ${widget.team.name} $teamScore, '
          '${widget.opponent.name} $opponentScore',
        );
        for (final score in _aroundNationScores.reversed) {
          plays.insert(1, 'AROUND THE NATION · $score');
        }
      }

      if (drive >= 28) {
        _finishGameInternal();
      }
    });
  }

  void _simToEnd() {
    if (!gameStarted) {
      setState(() => gameStarted = true);
    }

    setState(() => autoRunning = false);

    while (!finished) {
      _simPlay();
    }
  }

  void _finishGameInternal() {
    if (teamScore == opponentScore) {
      if (rng.nextDouble() < .5) {
        teamScore += 3;
        teamFieldGoals++;
        _addPlay(
          'OVERTIME · ${widget.team.name} wins on a walk-off field goal.',
          userPositive: true,
        );
        _animateDriveOnField(true, _DriveOutcome.fieldGoal);
      } else {
        opponentScore += 3;
        opponentFieldGoals++;
        _addPlay(
          'OVERTIME · ${widget.opponent.name} wins on a walk-off field goal.',
          userPositive: false,
        );
        _animateDriveOnField(false, _DriveOutcome.fieldGoal);
      }
    }

    finished = true;
    autoRunning = false;
    momentum = teamScore > opponentScore ? 1 : -1;

    plays.insert(
      0,
      'FINAL · ${rankedDisplayName(widget.team, widget.teamRank)} '
      '$teamScore, ${rankedDisplayName(widget.opponent, widget.opponentRank)} '
      '$opponentScore',
    );

    // Phase 6.2: the dynasty result is intentionally deferred until the
    // mandatory postgame press conference has been completed.
  }

  String get _resultHeadline {
    final won = teamScore > opponentScore;
    final margin = (teamScore - opponentScore).abs();

    if (won && margin >= 21) {
      return '${widget.team.name} MAKES A STATEMENT';
    }
    if (won && margin <= 7) {
      return '${widget.team.name} SURVIVES A THRILLER';
    }
    if (won) return '${widget.team.name} GETS THE WIN';

    if (margin <= 7) return '${widget.team.name} FALLS JUST SHORT';
    return '${widget.team.name} SUFFERS A TOUGH LOSS';
  }

  String get _turningPoint {
    if (teamTurnovers != opponentTurnovers) {
      final winner = teamTurnovers < opponentTurnovers
          ? widget.team.name
          : widget.opponent.name;
      return '$winner won the turnover battle '
          '$opponentTurnovers-$teamTurnovers.';
    }

    if (teamBigPlays != opponentBigPlays) {
      final winner = teamBigPlays > opponentBigPlays
          ? widget.team.name
          : widget.opponent.name;
      return '$winner created more explosive plays at the decisive moments.';
    }

    final winningTeam =
        teamScore > opponentScore ? widget.team.name : widget.opponent.name;
    return '$winningTeam executed better in scoring territory.';
  }

  String get _playerOfGameName {
    final seed = widget.team.name.length * 31 +
        widget.opponent.name.length * 17 +
        teamScore * 5 +
        opponentScore;

    final first =
        NameGenerator.firstNames[seed % NameGenerator.firstNames.length];
    final last = NameGenerator.lastNames[
        (seed * 7 + 11) % NameGenerator.lastNames.length];

    return '$first $last';
  }

  String get _playerOfGameLine {
    if (teamScore > opponentScore) {
      return '${widget.team.name} QB · '
          '${225 + teamScore * 3} total yards · '
          '${max(1, teamTouchdowns)} TD';
    }

    return '${widget.opponent.name} QB · '
        '${220 + opponentScore * 3} total yards · '
        '${max(1, opponentTouchdowns)} TD';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: GKColors.midnight,
      body: GKBackground(
        child: SafeArea(
          child: Column(
            children: [
              _broadcastTopBar(context),
              _scoreboard(),
              if (!finished) _momentumStrip(),
              Expanded(
                child: finished
                    ? _postgamePresentation()
                    : gameStarted
                        ? _liveGamePresentation()
                        : _pregamePresentation(),
              ),
              _controlDeck(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _broadcastTopBar(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(
        GKSpace.sm,
        GKSpace.xs,
        GKSpace.md,
        GKSpace.xs,
      ),
      decoration: BoxDecoration(
        color: GKColors.midnight.withOpacity(.96),
        border: const Border(
          bottom: BorderSide(color: GKColors.divider),
        ),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed:
                finished ? () => Navigator.of(context).pop() : null,
            icon: Icon(
              Icons.arrow_back_ios_new_rounded,
              color: finished
                  ? _gameText
                  : _gameMuted.withOpacity(.35),
            ),
          ),
          const SizedBox(width: GKSpace.xs),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 10,
              vertical: 6,
            ),
            decoration: BoxDecoration(
              color: _gameCyan.withOpacity(.10),
              borderRadius: BorderRadius.circular(GKRadius.pill),
              border: Border.all(color: _gameCyan.withOpacity(.70)),
              boxShadow: [
                BoxShadow(
                  color: _gameCyan.withOpacity(.14),
                  blurRadius: 7,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Text(
              'GAMECAST',
              style: TextStyle(
                color: _gameCyan,
                fontSize: 9,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.2,
              ),
            ),
          ),
          const SizedBox(width: GKSpace.sm),
          Expanded(
            child: Text(
              '$_broadcastLabel · $_stakesLabel',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: _gameText,
                fontSize: 11,
                fontWeight: FontWeight.w900,
                letterSpacing: .8,
              ),
            ),
          ),
          Text(
            _weatherLabel,
            style: const TextStyle(
              color: _gameMuted,
              fontSize: 10,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  Widget _scoreboard() {
    return Container(
      padding: const EdgeInsets.fromLTRB(
        GKSpace.md,
        GKSpace.sm,
        GKSpace.md,
        GKSpace.md,
      ),
      decoration: BoxDecoration(
        color: _gamePanelRaised.withOpacity(.97),
        border: Border(
          bottom: BorderSide(color: _gameCyan.withOpacity(.30)),
        ),
        boxShadow: [
          BoxShadow(
            color: _gameCyan.withOpacity(.06),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _scoreboardTeam(
                  team: widget.team,
                  ranking: widget.teamRank,
                  score: teamScore,
                  hasBall: gameStarted && !finished && _userHasBall,
                  alignRight: false,
                ),
              ),
              Container(
                width: 84,
                padding: const EdgeInsets.symmetric(vertical: 7),
                decoration: BoxDecoration(
                  color: GKColors.midnight,
                  border: Border.all(color: GKColors.divider),
                  borderRadius: BorderRadius.circular(GKRadius.small),
                ),
                child: Column(
                  children: [
                    Text(
                      _quarterLabel,
                      style: const TextStyle(
                        color: _gameCyan,
                        fontSize: 11,
                        fontWeight: FontWeight.w900,
                        letterSpacing: .8,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _clockLabel,
                      style: const TextStyle(
                        color: _gameText,
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: _scoreboardTeam(
                  team: widget.opponent,
                  ranking: widget.opponentRank,
                  score: opponentScore,
                  hasBall: gameStarted && !finished && !_userHasBall,
                  alignRight: true,
                ),
              ),
            ],
          ),
          const SizedBox(height: GKSpace.sm),
          Row(
            children: [
              const Icon(
                Icons.show_chart_rounded,
                color: _gameCyan,
                size: 15,
              ),
              const SizedBox(width: 5),
              Text(
                _spreadLabel,
                style: const TextStyle(
                  color: _gameText,
                  fontSize: 10,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const Spacer(),
              Text(
                finished
                    ? 'GAME COMPLETE'
                    : gameStarted
                        ? 'DRIVE ${drive + 1}'
                        : 'PREGAME COVERAGE',
                style: const TextStyle(
                  color: _gameMuted,
                  fontSize: 9,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _scoreboardTeam({
    required CollegeTeam team,
    required int ranking,
    required int score,
    required bool hasBall,
    required bool alignRight,
  }) {
    final rankLabel = ranking <= 25 ? '#$ranking ' : '';

    final teamInfo = Expanded(
      child: Column(
        crossAxisAlignment:
            alignRight ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment:
                alignRight ? MainAxisAlignment.end : MainAxisAlignment.start,
            children: [
              if (hasBall && !alignRight)
                const Padding(
                  padding: EdgeInsets.only(right: 4),
                  child: Icon(
                    Icons.sports_football_rounded,
                    color: _gameCyan,
                    size: 12,
                  ),
                ),
              Flexible(
                child: Text(
                  '$rankLabel${team.name}'.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: alignRight ? TextAlign.right : TextAlign.left,
                  style: const TextStyle(
                    color: _gameText,
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              if (hasBall && alignRight)
                const Padding(
                  padding: EdgeInsets.only(left: 4),
                  child: Icon(
                    Icons.sports_football_rounded,
                    color: _gameCyan,
                    size: 12,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            '${team.name == widget.team.name ? widget.teamOvr : widget.opponentOvr} OVR',
            style: const TextStyle(
              color: _gameMuted,
              fontSize: 9,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );

    final scoreText = Text(
      '$score',
      style: const TextStyle(
        color: _gameText,
        fontSize: 35,
        fontWeight: FontWeight.w900,
        height: 1,
      ),
    );

    return Row(
      mainAxisAlignment:
          alignRight ? MainAxisAlignment.end : MainAxisAlignment.start,
      children: alignRight
          ? [
              scoreText,
              const SizedBox(width: GKSpace.xs),
              teamInfo,
              const SizedBox(width: GKSpace.xs),
              GKTeamBadge(team: team, size: 41),
            ]
          : [
              GKTeamBadge(team: team, size: 41),
              const SizedBox(width: GKSpace.xs),
              teamInfo,
              const SizedBox(width: GKSpace.xs),
              scoreText,
            ],
    );
  }

  Widget _momentumStrip() {
    final normalized = (momentum + 1) / 2;

    return Container(
      padding: const EdgeInsets.fromLTRB(
        GKSpace.md,
        GKSpace.xs,
        GKSpace.md,
        GKSpace.xs,
      ),
      color: GKColors.midnight.withOpacity(.92),
      child: Column(
        children: [
          Row(
            children: [
              Text(
                'MOMENTUM',
                style: TextStyle(
                  color: _gameMuted,
                  fontSize: 8,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1,
                ),
              ),
              const Spacer(),
              Text(
                _momentumText,
                style: TextStyle(
                  color: _momentumColor,
                  fontSize: 9,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Stack(
            alignment: Alignment.center,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: normalized,
                  minHeight: 7,
                  backgroundColor: widget.opponent.primary.withOpacity(.8),
                  valueColor: AlwaysStoppedAnimation<Color>(
                    widget.team.primary,
                  ),
                ),
              ),
              Container(
                width: 2,
                height: 11,
                color: _gameText,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _pregamePresentation() {
    return ListView(
      padding: const EdgeInsets.all(GKSpace.md),
      children: [
        GKCard(
          color: gkDarkenedSchoolColor(widget.team.primary, .76),
          borderColor: widget.team.primary.withOpacity(.58),
          radius: GKRadius.featured,
          child: Column(
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: _gameCyan.withOpacity(.10),
                      borderRadius:
                          BorderRadius.circular(GKRadius.pill),
                      border: Border.all(
                        color: _gameCyan.withOpacity(.65),
                      ),
                    ),
                    child: Text(
                      'KINGDOM GAMECAST',
                      style: TextStyle(
                        color: _gameCyan,
                        fontSize: 8,
                        fontWeight: FontWeight.w900,
                        letterSpacing: .8,
                      ),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    _broadcastLabel,
                    style: const TextStyle(
                      color: _gameCyan,
                      fontSize: 9,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: GKSpace.md),
              Text(
                '${rankedDisplayName(widget.team, widget.teamRank)}\n'
                'VS\n${rankedDisplayName(widget.opponent, widget.opponentRank)}',
                textAlign: TextAlign.center,
                style: GKText.pageTitle.copyWith(height: 1.25),
              ),
              const SizedBox(height: GKSpace.sm),
              Text(
                '$_venueLabel · $_kickoffLabel',
                textAlign: TextAlign.center,
                style: GKText.body.copyWith(
                  color: _gameText,
                  fontSize: 11,
                ),
              ),
              const SizedBox(height: GKSpace.md),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: GKSpace.xs,
                runSpacing: GKSpace.xs,
                children: [
                  _pregamePill(Icons.cloud_outlined, _weatherLabel),
                  _pregamePill(Icons.show_chart_rounded, _spreadLabel),
                  _pregamePill(
                    Icons.stacked_line_chart_rounded,
                    _overUnderLabel,
                  ),
                  _pregamePill(Icons.bolt_rounded, _stakesLabel),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: GKSpace.md),
        GKCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('GAME STORYLINES', style: GKText.sectionLabel),
              const SizedBox(height: GKSpace.sm),
              ..._storylines.map(
                (story) => Padding(
                  padding: const EdgeInsets.only(bottom: GKSpace.xs),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.bolt_rounded,
                        color: _gameCyan,
                        size: 17,
                      ),
                      const SizedBox(width: GKSpace.xs),
                      Expanded(
                        child: Text(
                          story,
                          style: const TextStyle(
                            color: _gameText,
                            fontSize: 11,
                            fontWeight: FontWeight.w900,
                            letterSpacing: .5,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const Divider(color: GKColors.divider),
              Row(
                children: [
                  const Icon(
                    Icons.groups_rounded,
                    color: _gameMuted,
                    size: 18,
                  ),
                  const SizedBox(width: GKSpace.xs),
                  Expanded(
                    child: Text(
                      '${_attendance.toString()} EXPECTED · $_crowdLabel',
                      style: GKText.body.copyWith(fontSize: 10),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: GKSpace.md),
        GKCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('TEAM LEADERS', style: GKText.sectionLabel),
              const SizedBox(height: GKSpace.sm),
              ..._teamLeaders.map(
                (leader) => Container(
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  decoration: const BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: GKColors.divider),
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 37,
                        height: 37,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: widget.team.primary.withOpacity(.18),
                          shape: BoxShape.circle,
                        ),
                        child: Text(
                          leader.$2,
                          style: const TextStyle(
                            color: _gameCyan,
                            fontSize: 9,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                      const SizedBox(width: GKSpace.sm),
                      Expanded(
                        child: Text(
                          leader.$1.toUpperCase(),
                          style: const TextStyle(
                            color: _gameText,
                            fontSize: 12,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                      Text(
                        leader.$3,
                        textAlign: TextAlign.right,
                        style: GKText.body.copyWith(fontSize: 9),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: GKSpace.md),
        GKCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('MATCHUP EDGE', style: GKText.sectionLabel),
              const SizedBox(height: GKSpace.md),
              _comparisonRow(
                'Overall',
                widget.teamOvr,
                widget.opponentOvr,
              ),
              _comparisonRow(
                'Offensive firepower',
                widget.teamOvr + (widget.team.name.length % 4),
                widget.opponentOvr +
                    (widget.opponent.name.length % 4),
              ),
              _comparisonRow(
                'Defensive strength',
                widget.teamOvr - (widget.opponent.name.length % 3),
                widget.opponentOvr - (widget.team.name.length % 3),
              ),
            ],
          ),
        ),
        const SizedBox(height: GKSpace.md),
        GKCard(
          color: Color(0xFF201B12),
          borderColor: _gameCyan.withOpacity(.38),
          child: Row(
            children: [
              const Icon(
                Icons.mic_rounded,
                color: _gameCyan,
                size: 29,
              ),
              const SizedBox(width: GKSpace.sm),
              Expanded(
                child: Text(
                  '"We have to establish our identity early and handle the big moments."',
                  style: GKText.body.copyWith(
                    color: _gameText,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _pregamePill(IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: 10,
        vertical: 7,
      ),
      decoration: BoxDecoration(
        color: GKColors.midnight.withOpacity(.58),
        border: Border.all(color: GKColors.divider),
        borderRadius: BorderRadius.circular(GKRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: _gameCyan, size: 14),
          const SizedBox(width: 5),
          Text(
            label,
            style: const TextStyle(
              color: _gameText,
              fontSize: 9,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }

  Widget _comparisonRow(String label, int userValue, int opponentValue) {
    final maxValue = max(1, userValue + opponentValue);
    final userShare = userValue / maxValue;

    return Padding(
      padding: const EdgeInsets.only(bottom: GKSpace.sm),
      child: Column(
        children: [
          Row(
            children: [
              Text(
                '$userValue',
                style: const TextStyle(
                  color: _gameCyan,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const Spacer(),
              Text(
                label.toUpperCase(),
                style: const TextStyle(
                  color: _gameMuted,
                  fontSize: 9,
                  fontWeight: FontWeight.w900,
                  letterSpacing: .8,
                ),
              ),
              const Spacer(),
              Text(
                '$opponentValue',
                style: const TextStyle(
                  color: _gameText,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: userShare,
              minHeight: 6,
              backgroundColor: widget.opponent.primary,
              valueColor: AlwaysStoppedAnimation<Color>(
                widget.team.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _liveGamePresentation() {
    return Column(
      children: [
        Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: GKSpace.sm),
          decoration: const BoxDecoration(
            border: Border(
              bottom: BorderSide(color: GKColors.divider),
            ),
          ),
          child: Row(
            children: [
              _gameTabButton(0, 'GAMECAST'),
              _gameTabButton(1, 'TEAM STATS'),
              _gameTabButton(2, 'BOX SCORE'),
            ],
          ),
        ),
        Expanded(
          child: IndexedStack(
            index: selectedGameTab,
            children: [
              _gamecastFeed(),
              _teamStatsPanel(),
              _boxScorePanel(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _gameTabButton(int index, String label) {
    final selected = selectedGameTab == index;

    return Expanded(
      child: InkWell(
        onTap: () => setState(() => selectedGameTab = index),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              label,
              style: TextStyle(
                color: selected
                    ? _gameCyan
                    : _gameMuted,
                fontSize: 10,
                fontWeight: FontWeight.w900,
                letterSpacing: .8,
              ),
            ),
            const SizedBox(height: 6),
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: selected ? 34 : 0,
              height: 3,
              decoration: BoxDecoration(
                color: _gameCyan,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _fieldVisualization() {
    final possessor = _fieldPossessionIsUser ? widget.team : widget.opponent;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          GKSpace.md, GKSpace.md, GKSpace.md, GKSpace.xs),
      child: GKCard(
        paper: true,
        padding: const EdgeInsets.fromLTRB(
            GKSpace.sm, GKSpace.xs, GKSpace.sm, GKSpace.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.sports_football_rounded,
                    size: 13, color: GKColors.inkBlack.withOpacity(.55)),
                const SizedBox(width: 5),
                Text(
                  '${possessor.name.toUpperCase()} DRIVING',
                  style: GoogleFonts.zillaSlab(
                    color: GKColors.inkBlack.withOpacity(.7),
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.1,
                  ),
                ),
                const Spacer(),
                AnimatedBuilder(
                  animation: _fieldController,
                  builder: (context, _) => Text(
                    _fieldSpotLabel(_ballYard, _fieldPossessionIsUser),
                    style: GoogleFonts.zillaSlab(
                      color: GKColors.inkBlack.withOpacity(.7),
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: .6,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            AspectRatio(
              aspectRatio: 3.1,
              child: AnimatedBuilder(
                animation: _fieldController,
                builder: (context, _) => CustomPaint(
                  painter: _FootballFieldPainter(
                    yardPosition: _ballYard,
                    homeColor: widget.team.primary,
                    awayColor: widget.opponent.primary,
                    homeAbbr: teamMonogram(widget.team.name),
                    awayAbbr: teamMonogram(widget.opponent.name),
                    possessionIsUser: _fieldPossessionIsUser,
                  ),
                  size: Size.infinite,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _fieldSpotLabel(double absoluteYard, bool userBall) {
    final ownYard = userBall ? absoluteYard : 100 - absoluteYard;
    if (ownYard.round() == 50) return 'MIDFIELD';
    if (ownYard < 50) return 'OWN ${ownYard.round()}';
    return 'OPP ${(100 - ownYard).round()}';
  }

  Widget _gamecastFeed() {
    return Column(
      children: [
        _fieldVisualization(),
        Expanded(child: _gamecastList()),
      ],
    );
  }

  Widget _gamecastList() {
    return ListView.separated(
      reverse: false,
      padding: const EdgeInsets.all(GKSpace.md),
      itemCount: plays.length,
      separatorBuilder: (_, _unused) => const SizedBox(height: GKSpace.xs),
      itemBuilder: (context, index) {
        final play = plays[index];
        final major = play.contains('TOUCHDOWN') ||
            play.contains('TURNOVER') ||
            play.contains('FINAL') ||
            play.contains('OVERTIME');

        return GKCard(
          padding: const EdgeInsets.all(GKSpace.sm),
          color: major
              ? Color(0xFF201B12)
              : _gamePanelRaised,
          borderColor: major
              ? _gameCyan.withOpacity(.38)
              : GKColors.divider,
          radius: GKRadius.small,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                major
                    ? Icons.bolt_rounded
                    : Icons.sports_football_rounded,
                color: major
                    ? _gameCyan
                    : _gameMuted,
                size: 17,
              ),
              const SizedBox(width: GKSpace.xs),
              Expanded(
                child: Text(
                  play,
                  style: const TextStyle(
                    color: _gameText,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    height: 1.35,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _teamStatsPanel() {
    final teamYards =
        185 + teamScore * 4 + teamBigPlays * 18 - teamTurnovers * 12;
    final opponentYards = 185 +
        opponentScore * 4 +
        opponentBigPlays * 18 -
        opponentTurnovers * 12;

    return ListView(
      padding: const EdgeInsets.all(GKSpace.md),
      children: [
        GKCard(
          child: Column(
            children: [
              _statComparison(
                'Total yards',
                max(80, teamYards),
                max(80, opponentYards),
              ),
              _statComparison(
                'Touchdowns',
                teamTouchdowns,
                opponentTouchdowns,
              ),
              _statComparison(
                'Field goals',
                teamFieldGoals,
                opponentFieldGoals,
              ),
              _statComparison(
                'Turnovers',
                teamTurnovers,
                opponentTurnovers,
                lowerIsBetter: true,
              ),
              _statComparison(
                'Explosive plays',
                teamBigPlays,
                opponentBigPlays,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _statComparison(
    String label,
    int userValue,
    int opponentValue, {
    bool lowerIsBetter = false,
  }) {
    final userLeading = lowerIsBetter
        ? userValue < opponentValue
        : userValue > opponentValue;
    final opponentLeading = lowerIsBetter
        ? opponentValue < userValue
        : opponentValue > userValue;

    return Container(
      padding: const EdgeInsets.symmetric(vertical: GKSpace.sm),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: GKColors.divider),
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 54,
            child: Text(
              '$userValue',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: userLeading
                    ? _gameCyan
                    : _gameText,
                fontSize: 17,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          Expanded(
            child: Text(
              label.toUpperCase(),
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: _gameMuted,
                fontSize: 9,
                fontWeight: FontWeight.w900,
                letterSpacing: .8,
              ),
            ),
          ),
          SizedBox(
            width: 54,
            child: Text(
              '$opponentValue',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: opponentLeading
                    ? _gameCyan
                    : _gameText,
                fontSize: 17,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _boxScorePanel() {
    final teamQuarterScores = _quarterScores(
      teamScore,
      widget.team.name.length,
    );
    final opponentQuarterScores = _quarterScores(
      opponentScore,
      widget.opponent.name.length,
    );

    return ListView(
      padding: const EdgeInsets.all(GKSpace.md),
      children: [
        GKCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              _boxScoreHeader(),
              _boxScoreTeamRow(
                widget.team,
                widget.teamRank,
                teamQuarterScores,
                teamScore,
              ),
              _boxScoreTeamRow(
                widget.opponent,
                widget.opponentRank,
                opponentQuarterScores,
                opponentScore,
              ),
            ],
          ),
        ),
      ],
    );
  }

  List<int> _quarterScores(int total, int seed) {
    if (total <= 0) return const [0, 0, 0, 0];

    final random = Random(total * 97 + seed * 31);
    final scores = [0, 0, 0, 0];
    var remaining = total;

    while (remaining >= 7) {
      scores[random.nextInt(4)] += 7;
      remaining -= 7;
    }

    if (remaining >= 3) {
      scores[random.nextInt(4)] += 3;
      remaining -= 3;
    }

    if (remaining > 0) {
      scores[random.nextInt(4)] += remaining;
    }

    return scores;
  }

  Widget _boxScoreHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: GKSpace.sm,
        vertical: 10,
      ),
      decoration: const BoxDecoration(
        color: _gamePanelRaised,
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(GKRadius.card),
        ),
      ),
      child: const Row(
        children: [
          Expanded(
            flex: 4,
            child: Text(
              'TEAM',
              style: TextStyle(
                color: _gameMuted,
                fontSize: 9,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          _QuarterHeader('1'),
          _QuarterHeader('2'),
          _QuarterHeader('3'),
          _QuarterHeader('4'),
          _QuarterHeader('T'),
        ],
      ),
    );
  }

  Widget _boxScoreTeamRow(
    CollegeTeam team,
    int rank,
    List<int> quarters,
    int total,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: GKSpace.sm,
        vertical: GKSpace.sm,
      ),
      decoration: const BoxDecoration(
        border: Border(
          top: BorderSide(color: GKColors.divider),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 4,
            child: Row(
              children: [
                GKTeamBadge(team: team, size: 30),
                const SizedBox(width: GKSpace.xs),
                Expanded(
                  child: Text(
                    rank <= 25
                        ? '#$rank ${team.name}'
                        : team.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: _gameText,
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ],
            ),
          ),
          ...quarters.map(
            (score) => _QuarterValue('$score'),
          ),
          _QuarterValue(
            '$total',
            highlighted: true,
          ),
        ],
      ),
    );
  }

  Widget _postgamePresentation() {
    final won = teamScore > opponentScore;

    return ListView(
      padding: const EdgeInsets.all(GKSpace.md),
      children: [
        GKCard(
          color: won
              ? Color(0xFF11271D)
              : Color(0xFF2A1719),
          borderColor: won
              ? GKColors.victoryGreen.withOpacity(.52)
              : _gameCoral.withOpacity(.52),
          radius: GKRadius.featured,
          child: Column(
            children: [
              Icon(
                won
                    ? Icons.emoji_events_rounded
                    : Icons.sports_football_rounded,
                color: won
                    ? GKColors.victoryGreen
                    : _gameCoral,
                size: 42,
              ),
              const SizedBox(height: GKSpace.sm),
              Text(
                _resultHeadline,
                textAlign: TextAlign.center,
                style: GKText.pageTitle,
              ),
              const SizedBox(height: GKSpace.xs),
              Text(
                '${widget.team.name} $teamScore · '
                '${widget.opponent.name} $opponentScore',
                textAlign: TextAlign.center,
                style: GKText.body.copyWith(
                  color: _gameText,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: GKSpace.md),
        GKCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('PLAYER OF THE GAME', style: GKText.sectionLabel),
              const SizedBox(height: GKSpace.sm),
              Row(
                children: [
                  PlayerAvatar(
                    seed: _playerOfGameName.hashCode,
                    teamColor: won
                        ? widget.team.primary
                        : widget.opponent.primary,
                    size: 58,
                  ),
                  const SizedBox(width: GKSpace.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _playerOfGameName.toUpperCase(),
                          style: GKText.cardTitle,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _playerOfGameLine,
                          style: GKText.body.copyWith(fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: GKSpace.md),
        GKCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('TURNING POINT', style: GKText.sectionLabel),
              const SizedBox(height: GKSpace.sm),
              Text(
                _turningPoint,
                style: GKText.body.copyWith(
                  color: _gameText,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: GKSpace.md),
        GKCard(
          color: gkDarkenedSchoolColor(widget.team.primary, .74),
          borderColor: widget.team.primary.withOpacity(.52),
          child: Row(
            children: [
              const Icon(
                Icons.mic_rounded,
                color: _gameCyan,
                size: 27,
              ),
              const SizedBox(width: GKSpace.sm),
              Expanded(
                child: Text(
                  won
                      ? '"Our players answered every challenge. We will enjoy this one, then get back to work."'
                      : '"This result hurts, but it will reveal what kind of program we are building."',
                  style: GKText.body.copyWith(
                    color: _gameText,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: GKSpace.md),
        GKCard(
          color: Color(0xFF101E2F),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('SOCIAL REACTION', style: GKText.sectionLabel),
              const SizedBox(height: GKSpace.sm),
              Text(
                _socialReaction,
                style: GKText.body.copyWith(
                  color: _gameText,
                ),
              ),
              const SizedBox(height: GKSpace.xs),
              Text(
                '@RecruitingWire · Prospects took notice of the atmosphere and result.',
                style: GKText.body.copyWith(fontSize: 10),
              ),
            ],
          ),
        ),
        const SizedBox(height: GKSpace.md),
        _teamStatsPanel(),
      ],
    );
  }



  Future<void> _openMandatoryPressConference() async {
    if (!finished || resultSent) return;

    final response = await Navigator.of(context).push<PressConferenceResult>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => PostgamePressConferenceScreen(
          team: widget.team,
          opponent: widget.opponent,
          teamScore: teamScore,
          opponentScore: opponentScore,
          playerOfGameName: _playerOfGameName,
          playerOfGameLine: _playerOfGameLine,
          turningPoint: _turningPoint,
        ),
      ),
    );

    if (!mounted || response == null || resultSent) return;

    resultSent = true;
    final result = GameCompletionResult(
      won: teamScore > opponentScore,
      pressConference: response,
    );

    // Close this screen before notifying the dashboard. onFinished can
    // trigger its own dialogs (e.g. a recruit commitment popup) — if it ran
    // first, that popup would land on top of this screen and our own pop()
    // below would dismiss it instead of this screen, leaving the game
    // screen stuck on-screen looking like the press conference never ran.
    if (mounted) {
      Navigator.of(context).pop();
    }

    widget.onFinished(result);
  }

  Widget _controlDeck() {
    return Container(
      padding: const EdgeInsets.fromLTRB(
        GKSpace.md,
        GKSpace.sm,
        GKSpace.md,
        GKSpace.md,
      ),
      decoration: BoxDecoration(
        color: GKColors.midnight.withOpacity(.98),
        border: const Border(
          top: BorderSide(color: GKColors.divider),
        ),
      ),
      child: finished
          ? GKPrimaryButton(
              label: 'Continue to Press Conference',
              icon: Icons.mic_rounded,
              onPressed: resultSent
                  ? null
                  : _openMandatoryPressConference,
            )
          : !gameStarted
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    GKPrimaryButton(
                      label: 'Start Broadcast',
                      icon: Icons.play_arrow_rounded,
                      onPressed: _beginGame,
                    ),
                    const SizedBox(height: GKSpace.xs),
                    GKSecondaryButton(
                      label: 'Quick Sim to Final',
                      icon: Icons.fast_forward_rounded,
                      onPressed: _simToEnd,
                    ),
                  ],
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: GKPrimaryButton(
                            label: autoRunning ? 'Pause' : 'Resume',
                            icon: autoRunning
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            onPressed:
                                autoRunning ? _stopAuto : _startAuto,
                          ),
                        ),
                        const SizedBox(width: GKSpace.sm),
                        Expanded(
                          child: GKSecondaryButton(
                            label: 'Sim to End',
                            icon: Icons.fast_forward_rounded,
                            onPressed: _simToEnd,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: GKSpace.xs),
                    Row(
                      children: [
                        Text(
                          'SPEED',
                          style: TextStyle(
                            color: _gameMuted,
                            fontSize: 9,
                            fontWeight: FontWeight.w900,
                            letterSpacing: .8,
                          ),
                        ),
                        Expanded(
                          child: Slider(
                            value: speed,
                            min: .5,
                            max: 4,
                            divisions: 7,
                            activeColor: _gameCyan,
                            inactiveColor: GKColors.divider,
                            label: '${speed.toStringAsFixed(1)}x',
                            onChanged: (value) {
                              setState(() => speed = value);
                            },
                          ),
                        ),
                        SizedBox(
                          width: 38,
                          child: Text(
                            '${speed.toStringAsFixed(1)}x',
                            textAlign: TextAlign.right,
                            style: const TextStyle(
                              color: _gameCyan,
                              fontSize: 10,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
    );
  }
}


class PressConferenceResult {
  final String tone;
  final String quote;
  final String mediaReaction;
  final int mediaDelta;
  final int moraleDelta;
  final int boosterDelta;
  final int recruitingDelta;

  const PressConferenceResult({
    required this.tone,
    required this.quote,
    required this.mediaReaction,
    required this.mediaDelta,
    required this.moraleDelta,
    required this.boosterDelta,
    required this.recruitingDelta,
  });
}

class PostgamePressConferenceScreen extends StatefulWidget {
  final CollegeTeam team;
  final CollegeTeam opponent;
  final int teamScore;
  final int opponentScore;
  final String playerOfGameName;
  final String playerOfGameLine;
  final String turningPoint;

  const PostgamePressConferenceScreen({
    super.key,
    required this.team,
    required this.opponent,
    required this.teamScore,
    required this.opponentScore,
    required this.playerOfGameName,
    required this.playerOfGameLine,
    required this.turningPoint,
  });

  @override
  State<PostgamePressConferenceScreen> createState() =>
      _PostgamePressConferenceScreenState();
}

class _PostgamePressConferenceScreenState
    extends State<PostgamePressConferenceScreen> {
  String? selectedTone;
  String? selectedQuote;
  String? selectedReaction;
  int selectedMediaDelta = 0;
  int selectedMoraleDelta = 0;
  int selectedBoosterDelta = 0;
  int selectedRecruitingDelta = 0;

  bool get won => widget.teamScore > widget.opponentScore;

  String get reporterQuestion {
    final margin = (widget.teamScore - widget.opponentScore).abs();

    if (won && margin >= 21) {
      return 'Coach, your team controlled this game from start to finish. '
          'What impressed you most about the performance?';
    }
    if (won && margin <= 7) {
      return 'Coach, your team survived a close finish. '
          'What allowed the players to deliver under pressure?';
    }
    if (won) {
      return 'Coach, what was the biggest reason your team earned this victory?';
    }
    if (margin <= 7) {
      return 'Coach, your team came up just short. '
          'What is your message to the locker room?';
    }
    return 'Coach, this was a difficult result. '
        'How does your program respond from here?';
  }

  List<
      ({
        String tone,
        String quote,
        String reaction,
        IconData icon,
        int media,
        int morale,
        int boosters,
        int recruiting,
      })> get choices {
    if (won) {
      return const [
        (
          tone: 'Praise Players',
          quote: 'This was all about the players. They earned this moment.',
          reaction: 'Players respond positively, and recruits notice the unity.',
          icon: Icons.groups_rounded,
          media: 1,
          morale: 5,
          boosters: 1,
          recruiting: 3,
        ),
        (
          tone: 'Stay Humble',
          quote: 'We are proud of the result, but there is still work to do.',
          reaction: 'The media praises the disciplined, businesslike response.',
          icon: Icons.self_improvement_rounded,
          media: 4,
          morale: 2,
          boosters: 1,
          recruiting: 1,
        ),
        (
          tone: 'Demand More',
          quote: 'A win does not erase the mistakes. Our standard is higher.',
          reaction: 'Analysts respect the standard, but players feel challenged.',
          icon: Icons.trending_up_rounded,
          media: 2,
          morale: -3,
          boosters: 3,
          recruiting: 1,
        ),
        (
          tone: 'Fire Up Fans',
          quote: 'This program is building something special. Keep believing.',
          reaction: 'Fans and boosters embrace the energy around the program.',
          icon: Icons.campaign_rounded,
          media: 2,
          morale: 2,
          boosters: 5,
          recruiting: 4,
        ),
      ];
    }

    return const [
      (
        tone: 'Defend Players',
        quote: 'Put this result on me. Our players fought for this program.',
        reaction: 'The locker room appreciates the coach accepting responsibility.',
        icon: Icons.shield_rounded,
        media: 1,
        morale: 5,
        boosters: -2,
        recruiting: 0,
      ),
      (
        tone: 'Stay Composed',
        quote: 'We will study it, correct it, and move forward together.',
        reaction: 'The media views the response as calm and professional.',
        icon: Icons.self_improvement_rounded,
        media: 4,
        morale: 1,
        boosters: 0,
        recruiting: 0,
      ),
      (
        tone: 'Challenge Team',
        quote: 'This cannot become acceptable. Everyone must respond.',
        reaction: 'The message creates urgency but adds pressure inside the program.',
        icon: Icons.warning_amber_rounded,
        media: 1,
        morale: -4,
        boosters: 3,
        recruiting: -1,
      ),
      (
        tone: 'Promise a Response',
        quote: 'Our fans will see a different team the next time we take the field.',
        reaction: 'Supporters rally around the promise, while expectations rise.',
        icon: Icons.campaign_rounded,
        media: 2,
        morale: 1,
        boosters: 4,
        recruiting: 2,
      ),
    ];
  }

  Widget _impactChip(String label, int delta) {
    final prefix = delta > 0 ? '+' : '';
    final positive = delta >= 0;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: 7,
        vertical: 4,
      ),
      decoration: BoxDecoration(
        color: positive
            ? GKColors.victoryGreen.withOpacity(.10)
            : GKColors.alertRed.withOpacity(.10),
        borderRadius: BorderRadius.circular(GKRadius.pill),
        border: Border.all(
          color: positive
              ? GKColors.victoryGreen.withOpacity(.35)
              : GKColors.alertRed.withOpacity(.35),
        ),
      ),
      child: Text(
        '$label $prefix$delta',
        style: TextStyle(
          color: positive
              ? GKColors.victoryGreen
              : GKColors.alertRed,
          fontSize: 8,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }

  void _selectChoice(
    ({
      String tone,
      String quote,
      String reaction,
      IconData icon,
      int media,
      int morale,
      int boosters,
      int recruiting,
    }) choice,
  ) {
    setState(() {
      selectedTone = choice.tone;
      selectedQuote = choice.quote;
      selectedReaction = choice.reaction;
      selectedMediaDelta = choice.media;
      selectedMoraleDelta = choice.morale;
      selectedBoosterDelta = choice.boosters;
      selectedRecruitingDelta = choice.recruiting;
    });
  }

  void _continue() {
    if (selectedTone == null ||
        selectedQuote == null ||
        selectedReaction == null) {
      return;
    }

    Navigator.of(context).pop(
      PressConferenceResult(
        tone: selectedTone!,
        quote: selectedQuote!,
        mediaReaction: selectedReaction!,
        mediaDelta: selectedMediaDelta,
        moraleDelta: selectedMoraleDelta,
        boosterDelta: selectedBoosterDelta,
        recruitingDelta: selectedRecruitingDelta,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: GKColors.midnight,
        body: GKBackground(
          child: SafeArea(
            child: Column(
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(
                    GKSpace.md,
                    GKSpace.md,
                    GKSpace.md,
                    GKSpace.sm,
                  ),
                  decoration: const BoxDecoration(
                    color: GKColors.broadcastNavy,
                    border: Border(
                      bottom: BorderSide(color: GKColors.divider),
                    ),
                  ),
                  child: Column(
                    children: [
                      Text(
                        'GRIDIRON KINGDOM MEDIA',
                        style: GKText.sectionLabel,
                      ),
                      const SizedBox(height: 5),
                      Text(
                        'POSTGAME PRESS CONFERENCE',
                        textAlign: TextAlign.center,
                        style: GKText.pageTitle,
                      ),
                      const SizedBox(height: GKSpace.xs),
                      Text(
                        '${widget.team.name} ${widget.teamScore} · '
                        '${widget.opponent.name} ${widget.opponentScore}',
                        textAlign: TextAlign.center,
                        style: GKText.body.copyWith(
                          color: GKColors.warmWhite,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.all(GKSpace.md),
                    children: [
                      GKCard(
                        color: gkDarkenedSchoolColor(
                          widget.team.primary,
                          .76,
                        ),
                        borderColor:
                            widget.team.primary.withOpacity(.55),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  Icons.mic_rounded,
                                  color: GKColors.kingdomGold,
                                  size: 22,
                                ),
                                SizedBox(width: GKSpace.xs),
                                Text(
                                  'REPORTER',
                                  style: GKText.sectionLabel,
                                ),
                              ],
                            ),
                            const SizedBox(height: GKSpace.sm),
                            Text(
                              reporterQuestion,
                              style: GKText.body.copyWith(
                                color: GKColors.warmWhite,
                                fontSize: 15,
                                height: 1.45,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: GKSpace.md),
                      if (selectedTone == null) ...[
                        Text(
                          'SELECT YOUR RESPONSE',
                          style: GKText.sectionLabel,
                        ),
                        const SizedBox(height: GKSpace.sm),
                        ...choices.map(
                          (choice) => Padding(
                            padding: const EdgeInsets.only(
                              bottom: GKSpace.sm,
                            ),
                            child: Material(
                              color: Colors.transparent,
                              child: InkWell(
                                onTap: () => _selectChoice(choice),
                                borderRadius: BorderRadius.circular(
                                  GKRadius.card,
                                ),
                                child: GKCard(
                                  borderColor:
                                      GKColors.divider,
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Container(
                                        width: 44,
                                        height: 44,
                                        decoration: BoxDecoration(
                                          color: GKColors.kingdomGold
                                              .withOpacity(.12),
                                          shape: BoxShape.circle,
                                        ),
                                        child: Icon(
                                          choice.icon,
                                          color:
                                              GKColors.kingdomGold,
                                        ),
                                      ),
                                      const SizedBox(
                                        width: GKSpace.sm,
                                      ),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              choice.tone.toUpperCase(),
                                              style: GKText.cardTitle,
                                            ),
                                            const SizedBox(height: 5),
                                            Text(
                                              '"${choice.quote}"',
                                              style:
                                                  GKText.body.copyWith(
                                                color:
                                                    GKColors.warmWhite,
                                                fontStyle:
                                                    FontStyle.italic,
                                              ),
                                            ),
                                            const SizedBox(height: 8),
                                            Wrap(
                                              spacing: 6,
                                              runSpacing: 6,
                                              children: [
                                                _impactChip(
                                                  'Media',
                                                  choice.media,
                                                ),
                                                _impactChip(
                                                  'Morale',
                                                  choice.morale,
                                                ),
                                                _impactChip(
                                                  'Boosters',
                                                  choice.boosters,
                                                ),
                                                _impactChip(
                                                  'Recruiting',
                                                  choice.recruiting,
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ] else ...[
                        GKCard(
                          color: Color(0xFF201B12),
                          borderColor:
                              GKColors.kingdomGold.withOpacity(.48),
                          child: Column(
                            crossAxisAlignment:
                                CrossAxisAlignment.start,
                            children: [
                              Text(
                                selectedTone!.toUpperCase(),
                                style: GKText.sectionLabel,
                              ),
                              const SizedBox(height: GKSpace.sm),
                              Text(
                                '"$selectedQuote"',
                                style: GKText.body.copyWith(
                                  color: GKColors.warmWhite,
                                  fontSize: 15,
                                  fontStyle: FontStyle.italic,
                                  height: 1.4,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: GKSpace.md),
                        GKCard(
                          color: Color(0xFF101E2F),
                          child: Column(
                            crossAxisAlignment:
                                CrossAxisAlignment.start,
                            children: [
                              Text(
                                'MEDIA REACTION',
                                style: GKText.sectionLabel,
                              ),
                              const SizedBox(height: GKSpace.sm),
                              Text(
                                selectedReaction!,
                                style: GKText.body.copyWith(
                                  color: GKColors.warmWhite,
                                ),
                              ),
                              const SizedBox(height: GKSpace.sm),
                              Text(
                                '@KingdomSaturday · '
                                '${widget.team.name} coach addresses the media after the final.',
                                style:
                                    GKText.body.copyWith(fontSize: 10),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: GKSpace.sm),
                        TextButton.icon(
                          onPressed: () {
                            setState(() {
                              selectedTone = null;
                              selectedQuote = null;
                              selectedReaction = null;
                              selectedMediaDelta = 0;
                              selectedMoraleDelta = 0;
                              selectedBoosterDelta = 0;
                              selectedRecruitingDelta = 0;
                            });
                          },
                          icon: const Icon(
                            Icons.refresh_rounded,
                            color: GKColors.mutedSilver,
                          ),
                          label: Text(
                            'CHANGE RESPONSE',
                            style: TextStyle(
                              color: GKColors.mutedSilver,
                              fontWeight: FontWeight.w900,
                              fontSize: 10,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.all(GKSpace.md),
                  decoration: const BoxDecoration(
                    color: GKColors.midnight,
                    border: Border(
                      top: BorderSide(color: GKColors.divider),
                    ),
                  ),
                  child: GKPrimaryButton(
                    label: selectedTone == null
                        ? 'Select a Response to Continue'
                        : 'Continue to Dynasty',
                    icon: selectedTone == null
                        ? Icons.lock_rounded
                        : Icons.arrow_forward_rounded,
                    onPressed:
                        selectedTone == null ? null : _continue,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _QuarterHeader extends StatelessWidget {
  final String label;

  const _QuarterHeader(this.label);

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: GKColors.mutedSilver,
          fontSize: 9,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class _QuarterValue extends StatelessWidget {
  final String value;
  final bool highlighted;

  const _QuarterValue(
    this.value, {
    this.highlighted = false,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Text(
        value,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: highlighted
              ? GKColors.kingdomGold
              : GKColors.warmWhite,
          fontSize: 12,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}


class PlayerAvatar extends StatelessWidget {
  final int seed;
  final Color teamColor;
  final double size;

  const PlayerAvatar({
    super.key,
    required this.seed,
    required this.teamColor,
    this.size = 48,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(size, size),
      painter: PlayerAvatarPainter(seed: seed, teamColor: teamColor),
    );
  }
}

/// A deterministic, seed-generated player face: every player renders the
/// same face every time (same seed in, same face out), with enough real
/// facial structure (brow, eyes with a catchlight, nose, mouth, ears) and
/// hairstyle/facial-hair variety that a roster doesn't read as one face
/// recolored — the gap this painter used to leave next to the coach
/// portrait's much higher fidelity.
class PlayerAvatarPainter extends CustomPainter {
  final int seed;
  final Color teamColor;

  PlayerAvatarPainter({
    required this.seed,
    required this.teamColor,
  });

  static const _skinColors = [
    Color(0xFFF1C27D),
    Color(0xFFE0AC69),
    Color(0xFFD6A06A),
    Color(0xFFA86B32),
    Color(0xFF7A4B26),
    Color(0xFF5C3317),
  ];

  static const _hairColors = [
    GKColors.inkBlack,
    Color(0xFF3A2417),
    Color(0xFF4E2A14),
    Color(0xFF6B4423),
    Color(0xFFE6C35C),
    Color(0xFF9E2A2B),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final random = Random(seed);
    final w = size.width, h = size.height;
    double px(double v) => w * v;
    double py(double v) => h * v;

    final skin = _skinColors[random.nextInt(_skinColors.length)];
    final hair = _hairColors[random.nextInt(_hairColors.length)];
    final hairType = random.nextInt(6);
    final beardType = random.nextInt(5); // 0-2 = clean, 3 = stubble, 4 = light beard
    final eyeBlack = random.nextDouble() < .22;
    final smile = random.nextDouble() < .35;

    final fill = Paint()..isAntiAlias = true;
    final stroke = Paint()
      ..isAntiAlias = true
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    // Portrait badge background.
    fill.color = kCardColor;
    canvas.drawCircle(Offset(w / 2, h / 2), w / 2, fill);

    // Jersey / shoulders in the team's own color.
    fill.color = teamColor;
    canvas.drawPath(
      Path()
        ..moveTo(px(.12), py(1.02))
        ..quadraticBezierTo(px(.16), py(.80), px(.34), py(.74))
        ..quadraticBezierTo(px(.5), py(.70), px(.66), py(.74))
        ..quadraticBezierTo(px(.84), py(.80), px(.88), py(1.02))
        ..close(),
      fill,
    );

    // Ears.
    fill.color = skin;
    canvas.drawOval(Rect.fromLTWH(px(.17), py(.42), px(.09), py(.14)), fill);
    canvas.drawOval(Rect.fromLTWH(px(.74), py(.42), px(.09), py(.14)), fill);

    // Face.
    final face = Path()
      ..moveTo(px(.30), py(.30))
      ..quadraticBezierTo(px(.5), py(.16), px(.70), py(.30))
      ..quadraticBezierTo(px(.73), py(.48), px(.63), py(.62))
      ..quadraticBezierTo(px(.5), py(.72), px(.37), py(.62))
      ..quadraticBezierTo(px(.27), py(.48), px(.30), py(.30))
      ..close();
    fill.color = skin;
    canvas.drawPath(face, fill);

    // Cheek shading, one side only, for a little dimension without cost.
    fill.color = Color.lerp(skin, GKColors.ledgerBlack, .10) ?? skin;
    canvas.drawPath(
      Path()
        ..moveTo(px(.63), py(.36))
        ..quadraticBezierTo(px(.71), py(.46), px(.63), py(.60))
        ..quadraticBezierTo(px(.58), py(.50), px(.60), py(.40))
        ..close(),
      fill,
    );

    // Hair, six silhouettes.
    fill.color = hair;
    switch (hairType) {
      case 0: // bald — nothing to draw
        break;
      case 1: // buzz / fade cap
        canvas.drawPath(
          Path()
            ..moveTo(px(.29), py(.32))
            ..quadraticBezierTo(px(.5), py(.14), px(.71), py(.32))
            ..quadraticBezierTo(px(.5), py(.24), px(.29), py(.32))
            ..close(),
          fill,
        );
      case 2: // afro
        canvas.drawOval(Rect.fromLTWH(px(.22), py(.10), px(.56), py(.46)), fill);
        fill.color = skin;
        canvas.drawPath(face, fill);
        fill.color = hair;
      case 3: // waves, textured cap
        canvas.drawPath(
          Path()
            ..moveTo(px(.28), py(.34))
            ..quadraticBezierTo(px(.5), py(.13), px(.72), py(.34))
            ..quadraticBezierTo(px(.5), py(.25), px(.28), py(.34))
            ..close(),
          fill,
        );
        stroke
          ..color = Color.lerp(hair, GKColors.parchmentWhite, .25) ?? hair
          ..strokeWidth = w * .012;
        canvas.drawLine(Offset(px(.35), py(.22)), Offset(px(.45), py(.19)), stroke);
        canvas.drawLine(Offset(px(.55), py(.19)), Offset(px(.65), py(.22)), stroke);
      case 4: // mohawk
        canvas.drawPath(
          Path()
            ..moveTo(px(.44), py(.14))
            ..lineTo(px(.56), py(.14))
            ..lineTo(px(.53), py(.34))
            ..lineTo(px(.47), py(.34))
            ..close(),
          fill,
        );
      default: // long / flow, side pieces past the ears
        canvas.drawPath(
          Path()
            ..moveTo(px(.27), py(.34))
            ..quadraticBezierTo(px(.5), py(.13), px(.73), py(.34))
            ..quadraticBezierTo(px(.5), py(.24), px(.27), py(.34))
            ..close(),
          fill,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(px(.20), py(.32), px(.08), py(.24)),
            Radius.circular(w * .03),
          ),
          fill,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(px(.72), py(.32), px(.08), py(.24)),
            Radius.circular(w * .03),
          ),
          fill,
        );
    }

    // Eyebrows.
    stroke
      ..color = Color.lerp(hair, GKColors.ledgerBlack, .1) ?? hair
      ..strokeWidth = w * .018;
    canvas.drawLine(Offset(px(.36), py(.40)), Offset(px(.45), py(.385)), stroke);
    canvas.drawLine(Offset(px(.55), py(.385)), Offset(px(.64), py(.40)), stroke);

    // Eyes: white, iris, pupil, catchlight.
    fill.color = GKColors.parchmentWhite.withOpacity(.95);
    canvas.drawOval(Rect.fromLTWH(px(.365), py(.42), px(.11), py(.06)), fill);
    canvas.drawOval(Rect.fromLTWH(px(.525), py(.42), px(.11), py(.06)), fill);
    fill.color = Color(0xFF4A3928);
    canvas.drawCircle(Offset(px(.42), py(.45)), w * .022, fill);
    canvas.drawCircle(Offset(px(.58), py(.45)), w * .022, fill);
    fill.color = GKColors.inkBlack;
    canvas.drawCircle(Offset(px(.42), py(.45)), w * .011, fill);
    canvas.drawCircle(Offset(px(.58), py(.45)), w * .011, fill);
    fill.color = Colors.white;
    canvas.drawCircle(Offset(px(.412), py(.443)), w * .006, fill);
    canvas.drawCircle(Offset(px(.572), py(.443)), w * .006, fill);

    // Eye-black stripes — an authentic sideline detail, seeded.
    if (eyeBlack) {
      stroke
        ..color = GKColors.inkBlack.withOpacity(.85)
        ..strokeWidth = w * .022;
      canvas.drawLine(Offset(px(.38), py(.505)), Offset(px(.44), py(.49)), stroke);
      canvas.drawLine(Offset(px(.56), py(.49)), Offset(px(.62), py(.505)), stroke);
    }

    // Nose.
    stroke
      ..color = Color.lerp(skin, GKColors.ledgerBlack, .22) ?? skin
      ..strokeWidth = w * .010;
    canvas.drawLine(Offset(px(.5), py(.46)), Offset(px(.48), py(.55)), stroke);

    // Mouth: neutral line or a slight seeded smile.
    stroke
      ..color = Color(0xFF70433D)
      ..strokeWidth = w * .012;
    if (smile) {
      canvas.drawArc(Rect.fromLTWH(px(.42), py(.575), px(.16), py(.07)), .2, 2.7, false, stroke);
    } else {
      canvas.drawLine(Offset(px(.44), py(.60)), Offset(px(.56), py(.60)), stroke);
    }

    // Facial hair: clean, light stubble, or a short beard.
    if (beardType >= 3) {
      fill.color = hair.withOpacity(beardType == 3 ? .35 : .55);
      canvas.drawPath(
        Path()
          ..moveTo(px(.34), py(.50))
          ..quadraticBezierTo(px(.36), py(.65), px(.5), py(.70))
          ..quadraticBezierTo(px(.64), py(.65), px(.66), py(.50))
          ..quadraticBezierTo(px(.58), py(.58), px(.5), py(.59))
          ..quadraticBezierTo(px(.42), py(.58), px(.34), py(.50))
          ..close(),
        fill,
      );
    }
  }

  @override
  bool shouldRepaint(covariant PlayerAvatarPainter oldDelegate) =>
      oldDelegate.seed != seed || oldDelegate.teamColor != teamColor;
}



class CoachAvatarPainter extends CustomPainter {
  final Color skinColor;
  final Color hairColor;
  final String hairStyle;
  final String beard;
  final bool glasses;
  final Color teamColor;

  CoachAvatarPainter({
    required this.skinColor,
    required this.hairColor,
    required this.hairStyle,
    required this.beard,
    this.glasses = false,
    required this.teamColor,
  });

  Color _shade(Color color, double amount) =>
      Color.lerp(color, GKColors.inkBlack, amount) ?? color;

  Color _tint(Color color, double amount) =>
      Color.lerp(color, GKColors.parchmentWhite, amount) ?? color;

  void _drawHairTexture(
    Canvas canvas,
    Paint stroke,
    List<Offset> points,
  ) {
    for (var i = 0; i < points.length - 1; i++) {
      canvas.drawLine(points[i], points[i + 1], stroke);
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 150;
    canvas.save();
    canvas.scale(scale, scale);

    final fill = Paint()..isAntiAlias = true;
    final stroke = Paint()
      ..isAntiAlias = true
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // Background portrait badge.
    fill.color = _shade(teamColor, .78);
    canvas.drawCircle(const Offset(75, 75), 73, fill);

    stroke
      ..color = _tint(teamColor, .18)
      ..strokeWidth = 2;
    canvas.drawCircle(const Offset(75, 75), 71, stroke);

    // Shoulders and coaching quarter-zip.
    fill.color = _shade(teamColor, .10);
    canvas.drawPath(
      Path()
        ..moveTo(14, 150)
        ..quadraticBezierTo(19, 118, 47, 108)
        ..quadraticBezierTo(58, 103, 75, 103)
        ..quadraticBezierTo(92, 103, 103, 108)
        ..quadraticBezierTo(131, 118, 136, 150)
        ..close(),
      fill,
    );

    // Shoulder shadows.
    fill.color = _shade(teamColor, .28);
    canvas.drawPath(
      Path()
        ..moveTo(14, 150)
        ..quadraticBezierTo(21, 124, 45, 115)
        ..lineTo(53, 150)
        ..close(),
      fill,
    );
    canvas.drawPath(
      Path()
        ..moveTo(136, 150)
        ..quadraticBezierTo(129, 124, 105, 115)
        ..lineTo(97, 150)
        ..close(),
      fill,
    );

    // Quarter zip collar.
    fill.color = _tint(teamColor, .13);
    canvas.drawPath(
      Path()
        ..moveTo(51, 108)
        ..lineTo(67, 123)
        ..lineTo(75, 113)
        ..lineTo(83, 123)
        ..lineTo(99, 108)
        ..lineTo(91, 103)
        ..lineTo(59, 103)
        ..close(),
      fill,
    );

    fill.color = _shade(teamColor, .30);
    canvas.drawPath(
      Path()
        ..moveTo(51, 108)
        ..lineTo(67, 123)
        ..lineTo(75, 113)
        ..lineTo(83, 123)
        ..lineTo(99, 108)
        ..lineTo(91, 103)
        ..lineTo(59, 103)
        ..close(),
      fill,
    );

    // Neck.
    fill.color = skinColor;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(59, 84, 32, 29),
        const Radius.circular(10),
      ),
      fill,
    );

    fill.color = _shade(skinColor, .14);
    canvas.drawPath(
      Path()
        ..moveTo(61, 91)
        ..quadraticBezierTo(75, 102, 89, 91)
        ..lineTo(89, 103)
        ..quadraticBezierTo(75, 112, 61, 103)
        ..close(),
      fill,
    );

    // Ears.
    fill.color = skinColor;
    canvas.drawOval(const Rect.fromLTWH(25, 44, 17, 31), fill);
    canvas.drawOval(const Rect.fromLTWH(108, 44, 17, 31), fill);

    stroke
      ..color = _shade(skinColor, .22)
      ..strokeWidth = 1.3;
    canvas.drawArc(
      const Rect.fromLTWH(29, 50, 9, 18),
      4.5,
      3.0,
      false,
      stroke,
    );
    canvas.drawArc(
      const Rect.fromLTWH(112, 50, 9, 18),
      1.8,
      3.0,
      false,
      stroke,
    );

    // Realistic face silhouette.
    final face = Path()
      ..moveTo(42, 30)
      ..quadraticBezierTo(49, 15, 75, 14)
      ..quadraticBezierTo(101, 15, 108, 30)
      ..lineTo(106, 60)
      ..quadraticBezierTo(104, 77, 95, 88)
      ..quadraticBezierTo(87, 98, 75, 101)
      ..quadraticBezierTo(63, 98, 55, 88)
      ..quadraticBezierTo(46, 77, 44, 60)
      ..close();

    fill.color = skinColor;
    canvas.drawPath(face, fill);

    // Facial planes.
    fill.color = _shade(skinColor, .08);
    canvas.drawPath(
      Path()
        ..moveTo(44, 42)
        ..quadraticBezierTo(50, 32, 61, 29)
        ..quadraticBezierTo(56, 51, 58, 67)
        ..quadraticBezierTo(54, 80, 60, 91)
        ..quadraticBezierTo(49, 81, 46, 65)
        ..close(),
      fill,
    );

    fill.color = _tint(skinColor, .07);
    canvas.drawPath(
      Path()
        ..moveTo(76, 25)
        ..quadraticBezierTo(95, 27, 104, 40)
        ..lineTo(102, 63)
        ..quadraticBezierTo(96, 79, 87, 88)
        ..quadraticBezierTo(89, 66, 87, 45)
        ..close(),
      fill,
    );

    stroke
      ..color = _shade(skinColor, .25)
      ..strokeWidth = 1.4;
    canvas.drawPath(face, stroke);

    // Hair base and shape.
    fill.color = hairColor;

    if (hairStyle == 'Bald') {
      stroke
        ..color = _shade(skinColor, .13)
        ..strokeWidth = 1;
      canvas.drawArc(
        const Rect.fromLTWH(47, 15, 56, 22),
        3.28,
        2.75,
        false,
        stroke,
      );
    } else if (hairStyle == 'Buzz Cut') {
      canvas.drawPath(
        Path()
          ..moveTo(43, 34)
          ..quadraticBezierTo(47, 16, 75, 15)
          ..quadraticBezierTo(103, 16, 107, 34)
          ..quadraticBezierTo(91, 28, 75, 28)
          ..quadraticBezierTo(59, 28, 43, 34)
          ..close(),
        fill,
      );
    } else if (hairStyle == 'Fade') {
      canvas.drawPath(
        Path()
          ..moveTo(42, 38)
          ..quadraticBezierTo(45, 16, 75, 14)
          ..quadraticBezierTo(105, 16, 108, 38)
          ..quadraticBezierTo(93, 29, 75, 28)
          ..quadraticBezierTo(57, 29, 42, 38)
          ..close(),
        fill,
      );

      fill.color = _shade(hairColor, .27);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(42, 34, 8, 26),
          const Radius.circular(4),
        ),
        fill,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(100, 34, 8, 26),
          const Radius.circular(4),
        ),
        fill,
      );
    } else if (hairStyle == 'Curly') {
      final curls = <Offset>[
        const Offset(45, 31),
        const Offset(52, 22),
        const Offset(62, 18),
        const Offset(74, 17),
        const Offset(86, 18),
        const Offset(97, 23),
        const Offset(105, 32),
        const Offset(55, 31),
        const Offset(67, 26),
        const Offset(79, 26),
        const Offset(91, 31),
      ];

      for (final curl in curls) {
        canvas.drawCircle(curl, 8.7, fill);
      }
    } else if (hairStyle == 'Waves') {
      canvas.drawPath(
        Path()
          ..moveTo(43, 36)
          ..quadraticBezierTo(47, 16, 75, 15)
          ..quadraticBezierTo(103, 16, 107, 36)
          ..quadraticBezierTo(91, 29, 75, 29)
          ..quadraticBezierTo(59, 29, 43, 36)
          ..close(),
        fill,
      );

      stroke
        ..color = _tint(hairColor, .25)
        ..strokeWidth = 1.1;
      _drawHairTexture(
        canvas,
        stroke,
        const [
          Offset(52, 26),
          Offset(61, 23),
          Offset(70, 25),
          Offset(80, 22),
          Offset(90, 25),
          Offset(98, 23),
        ],
      );
      _drawHairTexture(
        canvas,
        stroke,
        const [
          Offset(55, 31),
          Offset(65, 28),
          Offset(75, 30),
          Offset(85, 27),
          Offset(95, 30),
        ],
      );
    } else if (hairStyle == 'Long') {
      fill.color = hairColor;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(34, 16, 82, 92),
          const Radius.circular(33),
        ),
        fill,
      );

      fill.color = skinColor;
      canvas.drawPath(face, fill);

      fill.color = hairColor;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(34, 39, 14, 65),
          const Radius.circular(8),
        ),
        fill,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(102, 39, 14, 65),
          const Radius.circular(8),
        ),
        fill,
      );
      canvas.drawPath(
        Path()
          ..moveTo(42, 37)
          ..quadraticBezierTo(47, 15, 75, 14)
          ..quadraticBezierTo(103, 15, 108, 37)
          ..quadraticBezierTo(92, 27, 75, 27)
          ..quadraticBezierTo(58, 27, 42, 37)
          ..close(),
        fill,
      );
    } else if (hairStyle == 'Afro') {
      canvas.drawOval(const Rect.fromLTWH(18, 6, 114, 78), fill);
      fill.color = skinColor;
      canvas.drawPath(face, fill);
      fill.color = hairColor;
      const afroRing = [
        Offset(28, 34), Offset(24, 20), Offset(35, 10), Offset(50, 5),
        Offset(65, 4), Offset(75, 3), Offset(85, 4), Offset(100, 5),
        Offset(115, 10), Offset(126, 20), Offset(122, 34), Offset(112, 42),
      ];
      for (final p in afroRing) {
        canvas.drawCircle(p, 11, fill);
      }
    } else if (hairStyle == 'Mohawk') {
      stroke
        ..color = _shade(skinColor, .13)
        ..strokeWidth = 1;
      canvas.drawArc(const Rect.fromLTWH(43, 16, 30, 24), 2.6, 2.2, false, stroke);
      canvas.drawArc(const Rect.fromLTWH(77, 16, 30, 24), .35, 2.2, false, stroke);
      canvas.drawPath(
        Path()
          ..moveTo(66, 12)
          ..lineTo(84, 12)
          ..quadraticBezierTo(80, 40, 78, 52)
          ..lineTo(72, 52)
          ..quadraticBezierTo(70, 40, 66, 12)
          ..close(),
        fill,
      );
    } else if (hairStyle == 'Slick Back') {
      canvas.drawPath(
        Path()
          ..moveTo(42, 40)
          ..quadraticBezierTo(45, 15, 75, 13)
          ..quadraticBezierTo(105, 15, 108, 40)
          ..quadraticBezierTo(97, 22, 75, 20)
          ..quadraticBezierTo(53, 22, 42, 40)
          ..close(),
        fill,
      );
      stroke
        ..color = _tint(hairColor, .35)
        ..strokeWidth = 1.2;
      canvas.drawLine(const Offset(52, 22), const Offset(45, 36), stroke);
      canvas.drawLine(const Offset(98, 22), const Offset(105, 36), stroke);
    } else if (hairStyle == 'Man Bun') {
      canvas.drawPath(
        Path()
          ..moveTo(43, 34)
          ..quadraticBezierTo(47, 16, 75, 15)
          ..quadraticBezierTo(103, 16, 107, 34)
          ..quadraticBezierTo(91, 28, 75, 28)
          ..quadraticBezierTo(59, 28, 43, 34)
          ..close(),
        fill,
      );
      canvas.drawCircle(const Offset(75, 9), 9, fill);
      stroke
        ..color = _shade(hairColor, .2)
        ..strokeWidth = 1;
      canvas.drawCircle(const Offset(75, 9), 9, stroke);
    } else if (hairStyle == 'Dreads') {
      canvas.drawPath(
        Path()
          ..moveTo(43, 30)
          ..quadraticBezierTo(47, 15, 75, 14)
          ..quadraticBezierTo(103, 15, 107, 30)
          ..quadraticBezierTo(91, 24, 75, 24)
          ..quadraticBezierTo(59, 24, 43, 30)
          ..close(),
        fill,
      );
      const strandX = [38.0, 48.0, 58.0, 92.0, 102.0, 112.0];
      for (final x in strandX) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x, 20, 7, 55),
            const Radius.circular(3.5),
          ),
          fill,
        );
      }
    } else {
      // Short / side-part.
      canvas.drawPath(
        Path()
          ..moveTo(42, 38)
          ..quadraticBezierTo(46, 16, 75, 14)
          ..quadraticBezierTo(103, 16, 108, 36)
          ..quadraticBezierTo(94, 29, 81, 27)
          ..lineTo(67, 32)
          ..quadraticBezierTo(55, 29, 42, 38)
          ..close(),
        fill,
      );

      stroke
        ..color = _tint(hairColor, .20)
        ..strokeWidth = 1.1;
      canvas.drawLine(const Offset(68, 20), const Offset(67, 31), stroke);
    }

    // Eyebrows.
    stroke
      ..color = _shade(hairColor, .12)
      ..strokeWidth = 3;
    canvas.drawLine(const Offset(51, 47), const Offset(64, 45), stroke);
    canvas.drawLine(const Offset(86, 45), const Offset(99, 47), stroke);

    // Eyes.
    fill.color = GKColors.parchmentWhite.withOpacity(.93);
    canvas.drawOval(const Rect.fromLTWH(50, 50, 16, 8), fill);
    canvas.drawOval(const Rect.fromLTWH(84, 50, 16, 8), fill);

    fill.color = Color(0xFF4A3928);
    canvas.drawCircle(const Offset(58, 54), 3, fill);
    canvas.drawCircle(const Offset(92, 54), 3, fill);

    fill.color = GKColors.inkBlack;
    canvas.drawCircle(const Offset(58, 54), 1.4, fill);
    canvas.drawCircle(const Offset(92, 54), 1.4, fill);

    fill.color = GKColors.parchmentWhite;
    canvas.drawCircle(const Offset(57, 53), .8, fill);
    canvas.drawCircle(const Offset(91, 53), .8, fill);

    // Nose bridge and nostrils.
    stroke
      ..color = _shade(skinColor, .23)
      ..strokeWidth = 1.5;
    canvas.drawPath(
      Path()
        ..moveTo(75, 52)
        ..quadraticBezierTo(72, 65, 72, 69)
        ..quadraticBezierTo(75, 72, 80, 69),
      stroke,
    );
    canvas.drawLine(const Offset(69, 71), const Offset(73, 72), stroke);
    canvas.drawLine(const Offset(78, 72), const Offset(82, 71), stroke);

    // Cheek definition.
    stroke
      ..color = _shade(skinColor, .13)
      ..strokeWidth = 1;
    canvas.drawArc(
      const Rect.fromLTWH(47, 58, 22, 18),
      .4,
      1.4,
      false,
      stroke,
    );
    canvas.drawArc(
      const Rect.fromLTWH(81, 58, 22, 18),
      1.35,
      1.4,
      false,
      stroke,
    );

    // Facial hair.
    if (beard == 'Goatee') {
      fill.color = _shade(hairColor, .08);

      canvas.drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(65, 75, 20, 4),
          const Radius.circular(2),
        ),
        fill,
      );
      canvas.drawPath(
        Path()
          ..moveTo(68, 81)
          ..quadraticBezierTo(75, 85, 82, 81)
          ..lineTo(80, 93)
          ..quadraticBezierTo(75, 97, 70, 93)
          ..close(),
        fill,
      );
    } else if (beard == 'Mustache') {
      fill.color = _shade(hairColor, .08);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(64, 74, 22, 5),
          const Radius.circular(2.5),
        ),
        fill,
      );
    } else if (beard == 'Soul Patch') {
      fill.color = _shade(hairColor, .08);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(72, 88, 6, 7),
          const Radius.circular(2),
        ),
        fill,
      );
    } else if (beard == 'Chin Strap') {
      stroke
        ..color = _shade(hairColor, .05)
        ..strokeWidth = 4;
      canvas.drawPath(
        Path()
          ..moveTo(46, 65)
          ..quadraticBezierTo(50, 82, 62, 92)
          ..quadraticBezierTo(75, 100, 88, 92)
          ..quadraticBezierTo(100, 82, 104, 65),
        stroke,
      );
    } else if (beard == 'Stubble') {
      fill.color = hairColor.withOpacity(.32);
      final random = Random(hairColor.toARGB32());
      for (var i = 0; i < 70; i++) {
        final dx = 47 + random.nextDouble() * 56;
        final dy = 68 + random.nextDouble() * 30;
        // Keep the stipple inside the jaw/chin silhouette roughly.
        if ((dx - 75).abs() > (dy - 68) * .95 + 8) continue;
        canvas.drawCircle(Offset(dx, dy), .55, fill);
      }
    } else if (beard == 'Full Beard') {
      fill.color = _shade(hairColor, .10);

      canvas.drawPath(
        Path()
          ..moveTo(46, 67)
          ..quadraticBezierTo(48, 84, 60, 94)
          ..quadraticBezierTo(75, 105, 90, 94)
          ..quadraticBezierTo(102, 84, 104, 67)
          ..quadraticBezierTo(94, 74, 87, 77)
          ..quadraticBezierTo(75, 82, 63, 77)
          ..quadraticBezierTo(56, 74, 46, 67)
          ..close(),
        fill,
      );

      fill.color = skinColor;
      canvas.drawOval(const Rect.fromLTWH(62, 72, 26, 13), fill);
    }

    // Mouth.
    stroke
      ..color = Color(0xFF70433D)
      ..strokeWidth = 1.8;
    canvas.drawArc(
      const Rect.fromLTWH(64, 76, 22, 11),
      .15,
      2.8,
      false,
      stroke,
    );

    // Glasses — sideline sunglasses, drawn over the eyes.
    if (glasses) {
      fill.color = GKColors.ledgerBlack.withOpacity(.55);
      final leftLens = RRect.fromRectAndRadius(
        const Rect.fromLTWH(47, 47, 22, 13),
        const Radius.circular(4),
      );
      final rightLens = RRect.fromRectAndRadius(
        const Rect.fromLTWH(81, 47, 22, 13),
        const Radius.circular(4),
      );
      canvas.drawRRect(leftLens, fill);
      canvas.drawRRect(rightLens, fill);

      stroke
        ..color = GKColors.inkBlack
        ..strokeWidth = 2;
      canvas.drawRRect(leftLens, stroke);
      canvas.drawRRect(rightLens, stroke);
      canvas.drawLine(const Offset(69, 52), const Offset(81, 52), stroke);
      canvas.drawLine(const Offset(47, 52), const Offset(38, 49), stroke);
      canvas.drawLine(const Offset(103, 52), const Offset(112, 49), stroke);
    }

    // Headset.
    stroke
      ..color = Color(0xFF1D1D1D)
      ..strokeWidth = 3.5;
    canvas.drawArc(
      const Rect.fromLTWH(32, 22, 86, 80),
      3.4,
      2.6,
      false,
      stroke,
    );

    fill.color = Color(0xFF202020);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(26, 53, 10, 24),
        const Radius.circular(4),
      ),
      fill,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(114, 53, 10, 24),
        const Radius.circular(4),
      ),
      fill,
    );

    stroke
      ..color = Color(0xFF2B2B2B)
      ..strokeWidth = 2.5;
    canvas.drawPath(
      Path()
        ..moveTo(116, 70)
        ..quadraticBezierTo(124, 78, 116, 86)
        ..lineTo(96, 88),
      stroke,
    );

    fill.color = kRed;
    canvas.drawCircle(const Offset(95, 88), 3.2, fill);

    // Quarter-zip seam.
    stroke
      ..color = GKColors.parchmentWhite.withOpacity(.75)
      ..strokeWidth = 1.5;
    canvas.drawLine(const Offset(75, 113), const Offset(75, 144), stroke);

    fill.color = kRed;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(66, 123, 18, 5),
        const Radius.circular(3),
      ),
      fill,
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CoachAvatarPainter oldDelegate) {
    return oldDelegate.skinColor != skinColor ||
        oldDelegate.hairColor != hairColor ||
        oldDelegate.hairStyle != hairStyle ||
        oldDelegate.beard != beard ||
        oldDelegate.glasses != glasses ||
        oldDelegate.teamColor != teamColor;
  }
}
