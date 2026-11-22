import 'package:flutter_test/flutter_test.dart';
import 'package:ovvas/data/ads/ad_service.dart';

import 'fake_cloud_sync.dart';

class _CountingCloud extends FakeCloudSync {
  int firstSeenCalls = 0;

  @override
  Future<DateTime?> syncFirstSeen(DateTime local) async {
    firstSeenCalls++;
    return DateTime(2026);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('first launch is synced once per sign-in, not on every sync', () async {
    final cloud = _CountingCloud();
    final ads = AdService(cloud: cloud);
    await ads.start();
    await pumpEventQueue();
    for (var i = 0; i < 3; i++) {
      await cloud.syncNow();
    }
    await pumpEventQueue();
    expect(cloud.firstSeenCalls, 1);

    await cloud.signOut();
    await cloud.signIn();
    await pumpEventQueue();
    expect(cloud.firstSeenCalls, 2);
  });
}
