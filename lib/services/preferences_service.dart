import 'package:shared_preferences/shared_preferences.dart';

import '../models/audiobook.dart';
import '../models/availability_filter_state.dart';

/// Read-only snapshot of all settings, loaded in a single batch.
class SettingsSnapshot {
  final String? libraryPath;
  final bool? analyticsConsent;
  final String? themeMode;
  final bool metadataEnrichment;
  final bool autoRewind;
  final int skipInterval;
  final ({String id, String name, bool isShared})? driveRootFolder;
  final bool removeWhenFinished;
  final bool refreshOnStartup;
  final bool driveProgressSync;
  final ({String id, String name})? driveBackupFolder;

  const SettingsSnapshot({
    required this.libraryPath,
    required this.analyticsConsent,
    required this.themeMode,
    required this.metadataEnrichment,
    required this.autoRewind,
    required this.skipInterval,
    required this.driveRootFolder,
    required this.removeWhenFinished,
    required this.refreshOnStartup,
    required this.driveProgressSync,
    required this.driveBackupFolder,
  });
}

class PreferencesService {
  PreferencesService();

  static const _libraryPathKey = 'library_path';
  static const _analyticsConsentKey = 'analytics_consent';
  static const _themeModeKey = 'theme_mode';
  static const _metadataEnrichmentKey = 'metadata_enrichment';
  static const _autoRewindKey = 'auto_rewind';
  static const _skipIntervalKey = 'skip_interval_seconds';
  static const _driveRootFolderIdKey = 'drive_root_folder_id';
  static const _driveRootFolderNameKey = 'drive_root_folder_name';
  static const _driveRootIsSharedKey = 'drive_root_is_shared';
  static const _removeWhenFinishedKey = 'drive_remove_when_finished';
  static const _refreshOnStartupKey = 'refresh_on_startup';
  static const _librarySortKey = 'library_sort';
  static const _driveProgressSyncKey = 'drive_progress_sync';
  static const _driveBackupFolderIdKey = 'drive_backup_folder_id';
  static const _driveBackupFolderNameKey = 'drive_backup_folder_name';
  static const _availabilityFilterKey = 'availability_filter';
  static const _statusFilterKey = 'status_filter';

  SharedPreferences? _prefs;

  Future<SharedPreferences> get _sp async =>
      _prefs ??= await SharedPreferences.getInstance();

  /// Loads all settings in a single batch. Use this instead of calling
  /// individual getters when you need many values at once (e.g. Settings
  /// screen init).
  Future<SettingsSnapshot> getSettingsSnapshot() async {
    final prefs = await _sp;

    // Drive root folder
    final driveRootId = prefs.getString(_driveRootFolderIdKey);
    final driveRootName = prefs.getString(_driveRootFolderNameKey);
    final driveRoot = (driveRootId != null && driveRootName != null)
        ? (
            id: driveRootId,
            name: driveRootName,
            isShared: prefs.getBool(_driveRootIsSharedKey) ?? false,
          )
        : null;

    // Drive backup folder
    final backupId = prefs.getString(_driveBackupFolderIdKey);
    final backupName = prefs.getString(_driveBackupFolderNameKey);
    final driveBackup = (backupId != null && backupName != null)
        ? (id: backupId, name: backupName)
        : null;

    return SettingsSnapshot(
      libraryPath: prefs.getString(_libraryPathKey),
      analyticsConsent: prefs.containsKey(_analyticsConsentKey)
          ? prefs.getBool(_analyticsConsentKey)
          : null,
      themeMode: prefs.getString(_themeModeKey),
      metadataEnrichment: prefs.getBool(_metadataEnrichmentKey) ?? true,
      autoRewind: prefs.getBool(_autoRewindKey) ?? true,
      skipInterval: prefs.getInt(_skipIntervalKey) ?? 30,
      driveRootFolder: driveRoot,
      removeWhenFinished: prefs.getBool(_removeWhenFinishedKey) ?? false,
      refreshOnStartup: prefs.getBool(_refreshOnStartupKey) ?? false,
      driveProgressSync: prefs.getBool(_driveProgressSyncKey) ?? false,
      driveBackupFolder: driveBackup,
    );
  }

  Future<String?> getLibraryPath() async {
    return (await _sp).getString(_libraryPathKey);
  }

  Future<void> setLibraryPath(String path) async {
    await (await _sp).setString(_libraryPathKey, path);
  }

  Future<void> clearLibraryPath() async {
    await (await _sp).remove(_libraryPathKey);
  }

  /// Returns null if the user has not yet been asked, true/false if they have.
  Future<bool?> getAnalyticsConsent() async {
    final prefs = await _sp;
    if (!prefs.containsKey(_analyticsConsentKey)) return null;
    return prefs.getBool(_analyticsConsentKey);
  }

  Future<void> setAnalyticsConsent(bool value) async {
    await (await _sp).setBool(_analyticsConsentKey, value);
  }

  /// Returns null if no preference has been stored (treat as 'system').
  Future<String?> getThemeMode() async {
    return (await _sp).getString(_themeModeKey);
  }

  Future<void> setThemeMode(String value) async {
    await (await _sp).setString(_themeModeKey, value);
  }

  Future<bool> getMetadataEnrichment() async {
    return (await _sp).getBool(_metadataEnrichmentKey) ?? true; // default on
  }

  Future<void> setMetadataEnrichment(bool value) async {
    await (await _sp).setBool(_metadataEnrichmentKey, value);
  }

  Future<bool> getAutoRewind() async {
    return (await _sp).getBool(_autoRewindKey) ?? true; // default on
  }

  Future<void> setAutoRewind(bool value) async {
    await (await _sp).setBool(_autoRewindKey, value);
  }

  /// Skip interval in seconds used by rewind and fast-forward. Default: 30.
  ///
  /// The stored value is read straight into `Duration(seconds: …)` and then
  /// into clampedRewind/clampedForward, so it is range-checked on the way out
  /// as well as on the way in: a persisted 0 makes both buttons silent no-ops
  /// and a persisted negative makes the REWIND button fast-forward, because
  /// `position - (-30s)` moves forward.
  Future<int> getSkipInterval() async {
    final stored = (await _sp).getInt(_skipIntervalKey) ?? defaultSkipInterval;
    return _clampSkipInterval(stored);
  }

  /// Accepted range for the skip interval, in seconds.
  static const int minSkipInterval = 5;
  static const int maxSkipInterval = 300;
  static const int defaultSkipInterval = 30;

  static int _clampSkipInterval(int seconds) => seconds < minSkipInterval
      ? minSkipInterval
      : seconds > maxSkipInterval
          ? maxSkipInterval
          : seconds;

  Future<void> setSkipInterval(int seconds) async {
    await (await _sp).setInt(_skipIntervalKey, _clampSkipInterval(seconds));
  }

  /// Library sort order. Stored as the enum name. Default: `lastPlayed`.
  Future<String?> getLibrarySort() async {
    return (await _sp).getString(_librarySortKey);
  }

  Future<void> setLibrarySort(String value) async {
    await (await _sp).setString(_librarySortKey, value);
  }

  Future<({String id, String name, bool isShared})?> getDriveRootFolder() async {
    final prefs = await _sp;
    final id = prefs.getString(_driveRootFolderIdKey);
    final name = prefs.getString(_driveRootFolderNameKey);
    if (id == null || name == null) return null;
    return (id: id, name: name, isShared: prefs.getBool(_driveRootIsSharedKey) ?? false);
  }

  Future<void> setDriveRootFolder(String id, String name, {bool isShared = false}) async {
    final prefs = await _sp;
    await prefs.setString(_driveRootFolderIdKey, id);
    await prefs.setString(_driveRootFolderNameKey, name);
    await prefs.setBool(_driveRootIsSharedKey, isShared);
  }

  Future<void> clearDriveRootFolder() async {
    final prefs = await _sp;
    await prefs.remove(_driveRootFolderIdKey);
    await prefs.remove(_driveRootFolderNameKey);
    await prefs.remove(_driveRootIsSharedKey);
  }

  Future<bool> getRemoveWhenFinished() async {
    return (await _sp).getBool(_removeWhenFinishedKey) ?? false;
  }

  Future<void> setRemoveWhenFinished(bool value) async {
    await (await _sp).setBool(_removeWhenFinishedKey, value);
  }

  Future<bool> getRefreshOnStartup() async {
    return (await _sp).getBool(_refreshOnStartupKey) ?? false; // default off
  }

  Future<void> setRefreshOnStartup(bool value) async {
    await (await _sp).setBool(_refreshOnStartupKey, value);
  }

  Future<bool> getDriveProgressSync() async {
    return (await _sp).getBool(_driveProgressSyncKey) ?? false;
  }

  Future<void> setDriveProgressSync(bool value) async {
    await (await _sp).setBool(_driveProgressSyncKey, value);
  }

  Future<({String id, String name})?> getDriveBackupFolder() async {
    final prefs = await _sp;
    final id = prefs.getString(_driveBackupFolderIdKey);
    final name = prefs.getString(_driveBackupFolderNameKey);
    if (id == null || name == null) return null;
    return (id: id, name: name);
  }

  Future<void> setDriveBackupFolder(String id, String name) async {
    final prefs = await _sp;
    await prefs.setString(_driveBackupFolderIdKey, id);
    await prefs.setString(_driveBackupFolderNameKey, name);
  }

  Future<void> clearDriveBackupFolder() async {
    final prefs = await _sp;
    await prefs.remove(_driveBackupFolderIdKey);
    await prefs.remove(_driveBackupFolderNameKey);
  }

  Future<AvailabilityFilterState> getAvailabilityFilter() async {
    final name = (await _sp).getString(_availabilityFilterKey);
    return AvailabilityFilterState.values.firstWhere(
      (v) => v.name == name,
      orElse: () => AvailabilityFilterState.all,
    );
  }

  Future<void> setAvailabilityFilter(AvailabilityFilterState value) async {
    await (await _sp).setString(_availabilityFilterKey, value.name);
  }


  /// Persisted library status filter (progress pills). Returns null when the
  /// user is showing all statuses.
  Future<BookStatus?> getStatusFilter() async {
    final name = (await _sp).getString(_statusFilterKey);
    if (name == null) return null;
    for (final s in BookStatus.values) {
      if (s.name == name) return s;
    }
    return null;
  }

  Future<void> setStatusFilter(BookStatus? status) async {
    final prefs = await _sp;
    if (status == null) {
      await prefs.remove(_statusFilterKey);
    } else {
      await prefs.setString(_statusFilterKey, status.name);
    }
  }

  static const _viewModeKey = 'view_mode';

  /// Persisted library layout. Defaults to grid; unknown values fall back.
  Future<String> getViewMode() async {
    return (await _sp).getString(_viewModeKey) ?? 'grid';
  }

  Future<void> setViewMode(String value) async {
    await (await _sp).setString(_viewModeKey, value);
  }
}
