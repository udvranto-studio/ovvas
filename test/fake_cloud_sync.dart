import 'package:ovvas/data/sync/cloud_sync.dart';

/// Pretends every change is backed up instantly.
class FakeCloudSync extends CloudSync {
  FakeCloudSync({DateTime Function()? clock, this._signedIn = true}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  bool _signedIn;
  DateTime? _lastBackup;

  @override
  bool get signedIn => _signedIn;
  @override
  String get accountEmail => 'nabila@example.com';
  @override
  DateTime? get lastBackup => _lastBackup;

  @override
  Future<void> signIn() async {
    _signedIn = true;
    _lastBackup = _clock();
    notifyListeners();
  }

  @override
  Future<void> signOut({bool force = false}) async {
    _signedIn = false;
    _lastBackup = null;
    notifyListeners();
  }

  @override
  Future<void> deleteAccount() => signOut();

  @override
  Future<bool> syncNow() async {
    if (!_signedIn) return false;
    _lastBackup = _clock();
    notifyListeners();
    return true;
  }

  @override
  void requestSync() {
    // The store notifies listeners right after this, so no notify here.
    if (_signedIn) _lastBackup = _clock();
  }
}
