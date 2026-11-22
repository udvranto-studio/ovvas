import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../core/theme/habit_palette.dart';
import '../../data/ads/ad_service.dart';
import '../../data/ads/pro_manager.dart';
import '../common/components.dart';

Future<void> openRewards(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RewardsScreen()));

/// Optional rewarded videos that unlock premium widget styles (FR-ADS-02,
/// FR-ADS-03). A video plays only after the user taps the button.
class RewardsScreen extends StatefulWidget {
  const RewardsScreen({super.key});

  @override
  State<RewardsScreen> createState() => _RewardsScreenState();
}

class _RewardsScreenState extends State<RewardsScreen> {
  late AdService _ads;
  bool _preloaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ads = context.ads;
    if (_preloaded) return;
    _preloaded = true;
    // Preload once so the video starts right away when tapped. After a
    // failure the user retries with the button.
    WidgetsBinding.instance.addPostFrameCallback((_) => _ads.loadRewarded());
  }

  @override
  void dispose() {
    _ads.disposeRewarded();
    super.dispose();
  }

  Future<void> _watch() async {
    final granted = await _ads.watchRewarded();
    if (granted && mounted) context.showSnack(context.l10n.rewardGranted);
  }

  @override
  Widget build(BuildContext context) {
    final ads = context.ads;
    final l = context.l10n;
    final c = context.colors;
    final until = ads.rewardUntil;
    final status = ads.rewardPermanent
        ? l.rewardUnlockedForever
        : until != null
            ? l.rewardUnlockedUntil(
                '${MaterialLocalizations.of(context).formatShortMonthDay(until)}, '
                '${TimeOfDay.fromDateTime(until).format(context)}',
              )
            : null;

    return Scaffold(
      appBar: AppBar(title: Text(l.rewardsTitle)),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 8, 16, MediaQuery.paddingOf(context).bottom + 24),
        children: [
          Text(l.rewardsIntro, style: TextStyle(color: c.textSecondary)),
          const SizedBox(height: 16),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const IconBadge(Icons.palette_outlined, Accent.violet),
                    const SizedBox(width: 12),
                    Expanded(child: Text(l.rewardStylesTitle, style: Theme.of(context).textTheme.titleMedium)),
                  ],
                ),
                const SizedBox(height: 12),
                // The reward and its length, before the user chooses to watch (FR-ADS-02.1).
                Text(l.rewardStylesBody(ads.config.rewardHours)),
                if (status != null) ...[
                  const SizedBox(height: 8),
                  Text(status, style: TextStyle(color: c.primary, fontWeight: FontWeight.w600)),
                ],
                if (!ads.rewardPermanent) ...[
                  const SizedBox(height: 8),
                  Text(
                    l.rewardProgress(ads.totalViews, ads.config.viewsForPermanent),
                    style: TextStyle(color: c.textSecondary, fontSize: 13),
                  ),
                  const SizedBox(height: 16),
                  _WatchButton(onWatch: _watch),
                ],
              ],
            ),
          ),
          const SizedBox(height: 24),
          const ProCard(),
        ],
      ),
    );
  }
}

class _WatchButton extends StatelessWidget {
  const _WatchButton({required this.onWatch});

  final VoidCallback onWatch;

  @override
  Widget build(BuildContext context) {
    final ads = context.ads;
    final l = context.l10n;
    final c = context.colors;
    if (!ads.rewardsAvailable) return const SizedBox.shrink();
    if (!ads.canWatchReward) return Text(l.dailyLimitReached, style: TextStyle(color: c.textSecondary));
    if (ads.rewardedReady) {
      final left = ads.config.rewardedDailyLimit - ads.watchedToday;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton.icon(
            onPressed: onWatch,
            icon: const Icon(Icons.play_circle_outline_rounded),
            label: Text(l.watchVideo),
          ),
          const SizedBox(height: 6),
          Text(l.videosLeftToday(left), textAlign: TextAlign.center, style: TextStyle(color: c.textSecondary, fontSize: 12)),
        ],
      );
    }
    if (ads.rewardedFailed) {
      // No technical details (FR-ADS-02.3, FR-ADS-07).
      return Row(
        children: [
          Expanded(child: Text(l.adNotAvailable, style: TextStyle(color: c.textSecondary))),
          TextButton(onPressed: ads.loadRewarded, child: Text(l.retry)),
        ],
      );
    }
    return const Center(child: SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2.5)));
  }
}

/// The Ovvas Pro offer, shown in Settings and on the Rewards screen.
class ProCard extends StatelessWidget {
  const ProCard({super.key});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final c = context.colors;
    final pro = context.ads.pro;
    return AppCard(
      color: c.mint,
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.asset('assets/brand/logo_mark.png', width: 44, height: 44, excludeFromSemantics: true),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l.proTitle, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16, color: c.onMint)),
                const SizedBox(height: 2),
                Text(pro.active ? l.proActive : l.proBody, style: TextStyle(color: c.onMint, fontSize: 14)),
              ],
            ),
          ),
          // Flexible so large text wraps instead of overflowing on narrow phones.
          Flexible(
            child: TextButton(
              onPressed: () => showProSheet(context),
              child: Text(pro.active ? l.learnMore : l.getPro, textAlign: TextAlign.center),
            ),
          ),
        ],
      ),
    );
  }
}

/// Buy Ovvas Pro or restore an earlier purchase (FR-ADS-08).
Future<void> showProSheet(BuildContext context) async {
  final l = context.l10n;
  if (!ProManager.supported) {
    context.showSnack(l.storeUnavailable);
    return;
  }
  final pro = context.ads.pro;
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheet) => ListenableBuilder(
      listenable: pro,
      builder: (sheet, _) {
        if (pro.takePurchaseFailed()) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (context.mounted) context.showSnack(l.purchaseFailed);
          });
        }
        final c = sheet.colors;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(l.proTitle, style: Theme.of(sheet).textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(pro.active ? l.proActive : l.proBody, style: TextStyle(color: c.textSecondary)),
                const SizedBox(height: 16),
                if (!pro.active) ...[
                  if (pro.products.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(l.storeUnavailable, style: TextStyle(color: c.textSecondary)),
                    ),
                  for (final p in pro.products)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: FilledButton(
                        onPressed: pro.buying ? null : () => pro.buy(p),
                        child: Text('${p.id == 'ovvas_pro_yearly' ? l.proYearly : l.proOneTime} · ${p.price}'),
                      ),
                    ),
                ],
                TextButton(
                  onPressed: () async {
                    final ok = await pro.refresh();
                    if (!context.mounted) return;
                    context.showSnack(!ok ? l.storeUnavailable : pro.active ? l.restoreDone : l.restoreNone);
                  },
                  child: Text(l.restorePurchases),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}
