import 'dart:math' as math;

import '../local/records.dart' show dayKey;

/// Ad values the server can change without an app update (FR-ADS-10,
/// FR-ADS-10.2). The defaults are used until the server answers, and keep
/// ads off.
class AdConfig {
  const AdConfig({
    this.enabled = false,
    this.rolloutPercent = 0,
    this.graceHours = 24,
    this.rewardedDailyLimit = 5,
    this.rewardHours = 24,
    this.viewsForPermanent = 10,
  });

  /// Reads the server's values, keeping each one in a safe range.
  factory AdConfig.fromJson(Map<String, dynamic> m) {
    int read(String key, int fallback, int min, int max) =>
        m[key] is num ? (m[key] as num).toInt().clamp(min, max) : fallback;
    const d = AdConfig();
    return AdConfig(
      enabled: m['enabled'] == true,
      rolloutPercent: read('rollout_percent', d.rolloutPercent, 0, 100),
      graceHours: read('grace_hours', d.graceHours, 0, 24 * 30),
      rewardedDailyLimit: read('rewarded_daily_limit', d.rewardedDailyLimit, 0, 5),
      rewardHours: read('reward_hours', d.rewardHours, 24, 24 * 7),
      viewsForPermanent: read('reward_views_for_permanent', d.viewsForPermanent, 1, 1000),
    );
  }

  /// Global ad switch.
  final bool enabled;

  /// Users whose cohort bucket (0–99) is below this see ads. The rest are the
  /// ad-free control group.
  final int rolloutPercent;

  /// No ads for this long after the first launch.
  final int graceHours;

  /// Rewarded videos per day, reset at local midnight. Never more than 5.
  final int rewardedDailyLimit;

  /// How long one rewarded video unlocks premium styles (24 hours to 7 days).
  final int rewardHours;

  /// Rewarded videos after which premium styles stay unlocked for good.
  final int viewsForPermanent;

  Map<String, Object?> toJson() => {
        'enabled': enabled,
        'rollout_percent': rolloutPercent,
        'grace_hours': graceHours,
        'rewarded_daily_limit': rewardedDailyLimit,
        'reward_hours': rewardHours,
        'reward_views_for_permanent': viewsForPermanent,
      };
}

/// Why an ad may not be shown, in the order the checks run (SRS 2.1).
enum AdBlock { remoteOff, noConsent, pro, grace, hidden, limit }

/// The first reason an ad may not be requested, or null when it may.
AdBlock? adBlock({
  required AdConfig config,
  required int bucket,
  required bool consentOk,
  required bool pro,
  required DateTime now,
  required DateTime firstSeen,
  bool visible = true,
  bool underLimit = true,
}) {
  if (!config.enabled || bucket >= config.rolloutPercent) return AdBlock.remoteOff;
  if (!consentOk) return AdBlock.noConsent;
  if (pro) return AdBlock.pro;
  if (now.difference(firstSeen) < Duration(hours: config.graceHours)) return AdBlock.grace;
  if (!visible) return AdBlock.hidden;
  if (!underLimit) return AdBlock.limit;
  return null;
}

/// Rewarded videos watched and what they unlocked (premium widget styles).
class RewardLedger {
  RewardLedger({
    this.lastSeen = 0,
    this.day = '',
    this.watchedToday = 0,
    this.totalViews = 0,
    this.until = 0,
    this.permanent = false,
  });

  factory RewardLedger.fromJson(Map<String, dynamic> m) => RewardLedger(
        lastSeen: m['lastSeen'] as int? ?? 0,
        day: m['day'] as String? ?? '',
        watchedToday: m['watchedToday'] as int? ?? 0,
        totalViews: m['totalViews'] as int? ?? 0,
        until: m['until'] as int? ?? 0,
        permanent: m['permanent'] as bool? ?? false,
      );

  /// Latest device time seen, in ms since epoch.
  int lastSeen;

  /// The day [watchedToday] counts, as "yyyy-mm-dd".
  String day;
  int watchedToday;
  int totalViews;

  /// When the temporary unlock ends, in ms since epoch.
  int until;
  bool permanent;

  Map<String, Object?> toJson() => {
        'lastSeen': lastSeen,
        'day': day,
        'watchedToday': watchedToday,
        'totalViews': totalViews,
        'until': until,
        'permanent': permanent,
      };

  /// The device time, never earlier than a time already seen, so turning the
  /// clock back can't extend a reward or reset the daily count.
  // shortcut: a clock that was set far ahead and then corrected freezes the
  // daily count until real time catches up. Upgrade with server time.
  DateTime clock(DateTime deviceNow) {
    lastSeen = math.max(deviceNow.millisecondsSinceEpoch, lastSeen);
    return DateTime.fromMillisecondsSinceEpoch(lastSeen);
  }

  int watchedOn(DateTime now) => day == dayKey(now) ? watchedToday : 0;

  bool canWatch(DateTime now, AdConfig config) => watchedOn(now) < config.rewardedDailyLimit;

  bool unlocked(DateTime now) => permanent || now.millisecondsSinceEpoch < until;

  /// Records one completed video.
  void grant(DateTime now, AdConfig config) {
    watchedToday = watchedOn(now) + 1;
    day = dayKey(now);
    totalViews++;
    // Watching again while unlocked does not stack time.
    until = math.max(until, now.add(Duration(hours: config.rewardHours)).millisecondsSinceEpoch);
    if (totalViews >= config.viewsForPermanent) permanent = true;
  }
}
