import 'package:flutter_test/flutter_test.dart';
import 'package:ovvas/data/ads/ad_rules.dart';

void main() {
  final now = DateTime(2026, 11, 23, 10);
  const on = AdConfig(enabled: true, rolloutPercent: 95);

  AdBlock? check({
    AdConfig config = on,
    int bucket = 10,
    bool consentOk = true,
    bool pro = false,
    Duration age = const Duration(days: 2),
    bool visible = true,
    bool underLimit = true,
  }) =>
      adBlock(
        config: config,
        bucket: bucket,
        consentOk: consentOk,
        pro: pro,
        now: now,
        firstSeen: now.subtract(age),
        visible: visible,
        underLimit: underLimit,
      );

  group('eligibility (SRS 2.1)', () {
    test('passes when every check passes', () => expect(check(), isNull));

    test('the remote switch and rollout cohort come first', () {
      expect(check(config: const AdConfig()), AdBlock.remoteOff, reason: 'ads off by default');
      expect(check(bucket: 95, pro: true), AdBlock.remoteOff, reason: 'control cohort');
    });

    test('then consent, Pro, grace period, visibility and limits, in order', () {
      expect(check(consentOk: false, pro: true), AdBlock.noConsent);
      expect(check(pro: true, age: Duration.zero), AdBlock.pro);
      expect(check(age: const Duration(hours: 23, minutes: 59), visible: false), AdBlock.grace);
      expect(check(visible: false, underLimit: false), AdBlock.hidden);
      expect(check(underLimit: false), AdBlock.limit);
    });
  });

  test('server values are kept in safe ranges', () {
    final c = AdConfig.fromJson({
      'enabled': true,
      'rollout_percent': 250,
      'rewarded_daily_limit': 50,
      'reward_hours': 1,
      'grace_hours': 'oops',
    });
    expect(
      (c.enabled, c.rolloutPercent, c.rewardedDailyLimit, c.rewardHours, c.graceHours),
      (true, 100, 5, 24, 24),
    );
    expect(AdConfig.fromJson({}).enabled, isFalse);
  });

  group('rewards (FR-ADS-11)', () {
    const config = AdConfig(rewardHours: 24, viewsForPermanent: 7);

    test('five videos a day, reset at local midnight', () {
      final ledger = RewardLedger();
      for (var i = 0; i < 5; i++) {
        expect(ledger.canWatch(now, config), isTrue);
        ledger.grant(now, config);
      }
      expect(ledger.canWatch(now, config), isFalse);
      expect(ledger.canWatch(DateTime(2026, 11, 24, 0, 1), config), isTrue);
    });

    test('an unlock lasts the configured time and does not stack', () {
      final ledger = RewardLedger()..grant(now, config);
      ledger.grant(now.add(const Duration(hours: 1)), config);
      expect(ledger.unlocked(now.add(const Duration(hours: 24, minutes: 30))), isTrue);
      expect(ledger.unlocked(now.add(const Duration(hours: 25, minutes: 1))), isFalse);
    });

    test('turning the clock back does not extend the unlock or reset the count', () {
      final ledger = RewardLedger();
      ledger.grant(ledger.clock(now), config);
      // A day passes, then the user sets the clock back by a day.
      ledger.clock(now.add(const Duration(hours: 25)));
      final faked = ledger.clock(now);
      expect(ledger.unlocked(faked), isFalse);
    });

    test('enough videos unlock for good', () {
      final ledger = RewardLedger();
      for (var d = 0; d < 7; d++) {
        ledger.grant(now.add(Duration(days: d * 10)), config);
      }
      expect(ledger.unlocked(now.add(const Duration(days: 999))), isTrue);
      expect(RewardLedger.fromJson(ledger.toJson()).permanent, isTrue);
    });
  });
}
