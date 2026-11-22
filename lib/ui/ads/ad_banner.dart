import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../../app/app_scope.dart';
import '../../data/ads/ad_service.dart';

/// An AdMob adaptive banner for the end of a screen's list (FR-ADS-01).
///
/// - Takes no space until an ad has loaded, and collapses when it fails (01.3).
/// - Loads after the first frame, never delaying the screen (01.2), and not
///   within 3 seconds of a check-in (SRS 4, rule 2).
/// - Stays hidden while its tab is in the background, a dialog or sheet is
///   open, or the keyboard is up (01.4).
/// - Sits 24dp below the content above it (01.1); the lists keep at least
///   24dp between it and the bottom navigation bar.
// shortcut: AdMob refreshes loaded banners itself. Set the refresh rate of
// both banner units to 60 seconds or more in the AdMob console.
class AdBanner extends StatefulWidget {
  const AdBanner({super.key, required this.placement});

  final AdPlacement placement;

  @override
  State<AdBanner> createState() => _AdBannerState();
}

class _AdBannerState extends State<AdBanner> {
  BannerAd? _ad;
  bool _loaded = false;
  bool _loading = false;
  DateTime _lastRequest = DateTime(0);
  Timer? _wait;

  /// Failed requests are retried no sooner than this.
  static const _retryAfter = Duration(seconds: 60);

  @override
  Widget build(BuildContext context) {
    final ads = context.ads;
    if (!ads.bannerAllowed(widget.placement)) {
      _drop();
      return const SizedBox.shrink();
    }
    final visible = TickerMode.valuesOf(context).enabled &&
        (ModalRoute.of(context)?.isCurrent ?? true) &&
        MediaQuery.viewInsetsOf(context).bottom == 0;
    if (visible) _scheduleLoad(ads);

    final ad = _ad;
    if (ad == null || !_loaded) return const SizedBox.shrink();
    final c = context.colors;
    return Visibility(
      visible: visible,
      maintainState: true,
      child: Padding(
        padding: const EdgeInsets.only(top: 24),
        child: Column(
          children: [
            // Marked as an ad and set apart from the app's cards (SRS 4, rule 4).
            Text(context.l10n.adLabel, style: TextStyle(fontSize: 11, color: c.textSecondary)),
            const SizedBox(height: 4),
            SizedBox(width: ad.size.width.toDouble(), height: ad.size.height.toDouble(), child: AdWidget(ad: ad)),
          ],
        ),
      ),
    );
  }

  void _scheduleLoad(AdService ads) {
    if (_ad != null || _loading || (_wait?.isActive ?? false)) return;
    final now = DateTime.now();
    final until = [ads.quietUntil, _lastRequest.add(_retryAfter)].reduce((a, b) => a.isAfter(b) ? a : b);
    if (until.isAfter(now)) {
      _wait = Timer(until.difference(now), () {
        if (mounted) setState(() {});
      });
      return;
    }
    _loading = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(ads));
  }

  Future<void> _load(AdService ads) async {
    final unit = ads.unitFor(widget.placement);
    if (!mounted || unit == null) {
      _loading = false;
      return;
    }
    // The list has 16dp side padding.
    final width = (MediaQuery.sizeOf(context).width - 32).truncate();
    final size = await AdSize.getLargeAnchoredAdaptiveBannerAdSize(width);
    if (!mounted || size == null) {
      _loading = false;
      return;
    }
    _lastRequest = DateTime.now();
    final ad = BannerAd(
      adUnitId: unit,
      size: size,
      request: const AdRequest(),
      listener: BannerAdListener(
        onAdLoaded: (_) {
          if (mounted) setState(() => _loaded = true);
        },
        onAdFailedToLoad: (ad, e) {
          // Never shown to the user (FR-ADS-07); the slot just stays collapsed.
          debugPrint('Banner failed to load: ${e.message}');
          ad.dispose();
          if (!mounted) return;
          setState(() {
            _ad = null;
            _loaded = false;
          });
        },
      ),
    );
    _ad = ad;
    _loading = false;
    await ad.load();
  }

  /// Frees the ad, e.g. when ads become disallowed (Pro bought).
  void _drop() {
    _wait?.cancel();
    _ad?.dispose();
    _ad = null;
    _loaded = false;
  }

  @override
  void dispose() {
    _drop();
    super.dispose();
  }
}
