import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../local/database.dart';
import '../sync/cloud_sync.dart';
import 'ad_rules.dart';
import 'pro_manager.dart';

/// The approved ad placements (FR-ADS-04). Every other screen shows no ads.
enum AdPlacement { todayBanner, statsBanner, rewarded }

/// The ad layer. Screens never call the ad SDK for decisions; they ask this
/// service whether a placement is allowed.
class AdService extends ChangeNotifier {
  AdService({AppDatabase? db, this._cloud, this._checkIns})
      : _db = db,
        pro = ProManager(db) {
    pro.addListener(_proChanged);
  }

  final AppDatabase? _db;
  final CloudSync? _cloud;
  final Listenable? _checkIns;
  final ProManager pro;

  // Real IDs come from --dart-define. Debug and profile builds fall back to
  // Google's test ads; a release build without IDs shows no ads.
  static const _unitIds = {
    AdPlacement.todayBanner: String.fromEnvironment('ADMOB_TODAY_BANNER'),
    AdPlacement.statsBanner: String.fromEnvironment('ADMOB_STATS_BANNER'),
    AdPlacement.rewarded: String.fromEnvironment('ADMOB_REWARDED'),
  };
  static const _testIds = {
    AdPlacement.todayBanner: 'ca-app-pub-3940256099942544/9214589741',
    AdPlacement.statsBanner: 'ca-app-pub-3940256099942544/9214589741',
    AdPlacement.rewarded: 'ca-app-pub-3940256099942544/5224354917',
  };

  /// The ad unit for [p], or null when this build has none.
  String? unitFor(AdPlacement p) {
    final id = _unitIds[p]!;
    if (id.isNotEmpty) return id;
    return kReleaseMode ? null : _testIds[p];
  }

  // shortcut: Android only, the platform the SRS covers. iOS also needs the
  // App Tracking Transparency prompt before ads can go there.
  static bool get supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static const _configKey = 'ads.config';
  static const _bucketKey = 'ads.bucket';
  static const _firstSeenKey = 'ads.firstSeen';
  static const _ledgerKey = 'ads.rewards';

  AdConfig config = const AdConfig();
  int _bucket = 99;
  DateTime _firstSeen = DateTime.now();
  RewardLedger _ledger = RewardLedger();
  DateTime _quietUntil = DateTime(0);
  bool _started = false;

  /// True once UMP allows ad requests and the SDK is initialized.
  bool consentOk = false;

  /// Whether Settings must offer the UMP privacy options (FR-ADS-09.1).
  bool privacyOptionsRequired = false;
  bool _initializing = false;
  AppLifecycleListener? _lifecycle;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    final db = _db;
    if (db != null) {
      final cached = await db.readValue(_configKey);
      if (cached != null) config = AdConfig.fromJson(jsonDecode(cached) as Map<String, dynamic>);
      final bucket = int.tryParse(await db.readValue(_bucketKey) ?? '');
      _bucket = bucket ?? math.Random.secure().nextInt(100);
      if (bucket == null) await db.writeValue(_bucketKey, '$_bucket');
      final seen = int.tryParse(await db.readValue(_firstSeenKey) ?? '');
      if (seen == null) {
        await db.writeValue(_firstSeenKey, '${_firstSeen.millisecondsSinceEpoch}');
      } else {
        _firstSeen = DateTime.fromMillisecondsSinceEpoch(seen);
      }
      final ledger = await db.readValue(_ledgerKey);
      if (ledger != null) _ledger = RewardLedger.fromJson(jsonDecode(ledger) as Map<String, dynamic>);
    }
    _ledger.clock(DateTime.now());
    notifyListeners();
    unawaited(pro.start());
    _checkIns?.addListener(_quietAfterChange);
    if (!supported) return;
    _cloud?.addListener(_syncFirstSeen);
    _lifecycle = AppLifecycleListener(onResume: _refresh);
    await _refresh();
    unawaited(_syncFirstSeen());
  }

  Future<void> _refresh() async {
    final remote = await _cloud?.fetchAdConfig();
    if (remote != null) {
      config = AdConfig.fromJson(remote);
      await _db?.writeValue(_configKey, jsonEncode(config.toJson()));
      notifyListeners();
    }
    await _saveLedger();
    await _initSdkIfAllowed();
  }

  /// The account whose first launch was already synced. The cloud notifies
  /// on every sync, but this needs to run once per sign-in.
  String? _firstSeenSyncedFor;

  Future<void> _syncFirstSeen() async {
    final cloud = _cloud;
    if (cloud == null || !cloud.signedIn) {
      _firstSeenSyncedFor = null;
      return;
    }
    if (_firstSeenSyncedFor == cloud.accountEmail) return;
    // Set before waiting, so overlapping calls don't repeat the request.
    // If it fails, it is tried again at the next sign-in or app start.
    _firstSeenSyncedFor = cloud.accountEmail;
    final remote = await cloud.syncFirstSeen(_firstSeen);
    if (remote == null || !remote.isBefore(_firstSeen)) return;
    _firstSeen = remote;
    await _db?.writeValue(_firstSeenKey, '${remote.millisecondsSinceEpoch}');
    notifyListeners();
  }

  /// The first reason ads are blocked right now, before visibility and limits.
  AdBlock? _block({bool? consent}) => adBlock(
        config: config,
        bucket: _bucket,
        consentOk: consent ?? consentOk,
        pro: pro.active,
        now: DateTime.now(),
        firstSeen: _firstSeen,
      );

  /// Runs Google UMP, then starts the ad SDK only if UMP allows ad requests
  /// (FR-ADS-09). Skipped while ads are off, for Pro users and during the
  /// grace period, so those users never see a consent form.
  Future<void> _initSdkIfAllowed() async {
    if (!supported || consentOk || _initializing || _block(consent: true) != null) return;
    if (AdPlacement.values.every((p) => unitFor(p) == null)) return;
    _initializing = true;
    try {
      final info = ConsentInformation.instance;
      final updated = Completer<void>();
      info.requestConsentInfoUpdate(
        ConsentRequestParameters(),
        updated.complete,
        (e) {
          // Offline: an earlier consent may still allow requests.
          debugPrint('Consent update failed: ${e.message}');
          updated.complete();
        },
      );
      await updated.future;
      await ConsentForm.loadAndShowConsentFormIfRequired((e) {
        if (e != null) debugPrint('Consent form: ${e.message}');
      });
      await _readConsent();
      if (consentOk) {
        // The app is for adults (SRS 6.1): no child or teen treatment.
        await MobileAds.instance.updateRequestConfiguration(
          RequestConfiguration(ageRestrictedTreatment: AgeRestrictedTreatment.unspecified),
        );
        await MobileAds.instance.initialize();
      }
    } catch (e, s) {
      debugPrint('Ads unavailable: $e\n$s');
      consentOk = false;
    } finally {
      _initializing = false;
      notifyListeners();
    }
  }

  Future<void> _readConsent() async {
    final info = ConsentInformation.instance;
    consentOk = await info.canRequestAds();
    privacyOptionsRequired =
        await info.getPrivacyOptionsRequirementStatus() == PrivacyOptionsRequirementStatus.required;
  }

  /// Shows the UMP privacy options form from Settings.
  Future<void> showPrivacyOptions() async {
    final wasOk = consentOk;
    await ConsentForm.showPrivacyOptionsForm((e) {
      if (e != null) debugPrint('Privacy options: ${e.message}');
    });
    await _readConsent();
    notifyListeners();
    if (!wasOk && consentOk) await MobileAds.instance.initialize();
  }

  void _proChanged() {
    if (pro.active) disposeRewarded();
    notifyListeners();
  }

  // ---- Banners ----

  /// Whether the banner at [p] may load now (SRS 2.1 steps 1 to 4). The
  /// banner itself checks that it is visible.
  bool bannerAllowed(AdPlacement p) => supported && unitFor(p) != null && _block() == null;

  /// Banners don't load until this time, so a check-in's animation and
  /// haptic play undisturbed (SRS 4, rule 2).
  DateTime get quietUntil => _quietUntil;

  void _quietAfterChange() => _quietUntil = DateTime.now().add(const Duration(seconds: 3));

  // ---- Rewards ----

  /// Whether the Rewards screen and its entry are shown at all.
  bool get rewardsAvailable =>
      ProManager.supported && unitFor(AdPlacement.rewarded) != null && _block() == null;

  DateTime get _now => _ledger.clock(DateTime.now());

  int get watchedToday => _ledger.watchedOn(_now);
  int get totalViews => _ledger.totalViews;
  bool get canWatchReward => _ledger.canWatch(_now, config);

  /// Whether the premium widget styles (accent theme, gradient background)
  /// may be picked: with Pro, an active reward, or where Pro isn't sold.
  bool get premiumStylesUnlocked => !ProManager.supported || pro.active || _ledger.unlocked(_now);

  /// When the reward unlock ends, or null when none is active or it is permanent.
  DateTime? get rewardUntil => !_ledger.permanent && _ledger.unlocked(_now)
      ? DateTime.fromMillisecondsSinceEpoch(_ledger.until)
      : null;
  bool get rewardPermanent => _ledger.permanent;

  RewardedAd? _rewarded;
  bool rewardedLoading = false;
  bool rewardedFailed = false;
  bool get rewardedReady => _rewarded != null;

  /// Preloads a rewarded video. The Rewards screen calls this when it opens.
  void loadRewarded() {
    if (!rewardsAvailable || !consentOk || !canWatchReward || _rewarded != null || rewardedLoading) return;
    rewardedLoading = true;
    rewardedFailed = false;
    notifyListeners();
    RewardedAd.load(
      adUnitId: unitFor(AdPlacement.rewarded)!,
      request: const AdRequest(),
      rewardedAdLoadCallback: RewardedAdLoadCallback(
        onAdLoaded: (ad) {
          rewardedLoading = false;
          _rewarded = ad;
          notifyListeners();
        },
        onAdFailedToLoad: (e) {
          debugPrint('Rewarded ad failed to load: ${e.message}');
          rewardedLoading = false;
          rewardedFailed = true;
          notifyListeners();
        },
      ),
    );
  }

  /// Shows the loaded video. Completes with true when the reward was granted,
  /// which happens only once the SDK reports it earned (FR-ADS-02.2).
  // shortcut: the reward is saved on the phone right away; a kill in the
  // instant between earning and saving loses it. Upgrade with AdMob
  // server-side verification to a Supabase function.
  Future<bool> watchRewarded() async {
    final ad = _rewarded;
    if (ad == null || !canWatchReward) return false;
    _rewarded = null;
    final closed = Completer<bool>();
    var earned = false;
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (ad) {
        ad.dispose();
        if (!closed.isCompleted) closed.complete(earned);
      },
      onAdFailedToShowFullScreenContent: (ad, e) {
        debugPrint('Rewarded ad failed to show: ${e.message}');
        ad.dispose();
        if (!closed.isCompleted) closed.complete(false);
      },
    );
    await ad.show(onUserEarnedReward: (_, _) {
      earned = true;
      _ledger.grant(_now, config);
      _saveLedger();
      notifyListeners();
    });
    final granted = await closed.future;
    notifyListeners();
    loadRewarded();
    return granted;
  }

  /// Frees the preloaded video, e.g. when the Rewards screen closes.
  void disposeRewarded() {
    _rewarded?.dispose();
    _rewarded = null;
  }

  Future<void> _saveLedger() async => _db?.writeValue(_ledgerKey, jsonEncode(_ledger.toJson()));

  @override
  void dispose() {
    _checkIns?.removeListener(_quietAfterChange);
    _cloud?.removeListener(_syncFirstSeen);
    pro.removeListener(_proChanged);
    _lifecycle?.dispose();
    disposeRewarded();
    pro.dispose();
    super.dispose();
  }
}
