import 'package:flutter/foundation.dart';

/// Account and cloud backup. The store talks to this; the screens read it
/// through the store.
abstract class CloudSync extends ChangeNotifier {
  /// False when this build has no cloud backend set up.
  bool get available => true;
  bool get signedIn;
  String get accountEmail;

  /// When everything on this phone was last confirmed in the cloud.
  DateTime? get lastBackup;

  /// Set by the store. Called after cloud changes were saved to the local
  /// database, so the store can reload them.
  Future<void> Function()? onRemoteChange;

  /// Starts sign-in. With a browser-based sign-in, [signedIn] turns true
  /// later, when the user comes back to the app.
  Future<void> signIn();

  /// Uploads what is left, then signs out. Data stays on the phone. Throws,
  /// staying signed in, if the upload failed.
  Future<void> signOut();

  /// Deletes the account and its cloud data, then signs out. Does nothing
  /// when not signed in. Throws if the server refused.
  Future<void> deleteAccount();

  /// Uploads local changes and downloads remote ones. Returns false if the
  /// sync could not finish (offline, not signed in, server error).
  Future<bool> syncNow();

  /// Called after every local change. Implementations should batch these.
  void requestSync();
}

/// Used when no cloud backend is configured. Data stays on the phone.
class LocalOnlyCloudSync extends CloudSync {
  @override
  bool get available => false;
  @override
  bool get signedIn => false;
  @override
  String get accountEmail => '';
  @override
  DateTime? get lastBackup => null;
  @override
  Future<void> signIn() async {}
  @override
  Future<void> signOut() async {}
  @override
  Future<void> deleteAccount() async {}
  @override
  Future<bool> syncNow() async => false;
  @override
  void requestSync() {}
}
