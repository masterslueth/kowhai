import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/drive_library_service.dart';
import '../services/drive_service.dart';
import '../services/enrichment_service.dart';
import '../services/position_backup_service.dart';
import '../widgets/audio_handler_scope.dart';
import '../widgets/drive_folder_picker.dart';
import '../services/preferences_service.dart';
import '../services/telemetry_service.dart';
import '../locator.dart';
import 'about_screen.dart';

class SettingsScreen extends StatefulWidget {
  /// Called immediately when the audiobooks folder is changed.
  final VoidCallback? onFolderChanged;

  /// Called when a Drive rescan completes (library should reload Drive books).
  final VoidCallback? onDriveRescanned;

  const SettingsScreen({super.key, this.onFolderChanged, this.onDriveRescanned});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String? _folderPath;
  bool _telemetryEnabled = false;
  bool _metadataEnrichment = true;
  bool _pickingFolder = false;
  String _themeMode = 'system';
  bool _autoRewind = true;
  int _skipInterval = 30;

  // Drive
  bool _driveAvailable = false;
  GoogleSignInAccount? _driveAccount;
  String? _driveFolderName;
  bool _driveRescanning = false;
  bool _removeWhenFinished = false;
  bool _refreshOnStartup = false;
  bool _driveProgressSync = false;
  String? _driveBackupFolderName;
  String _driveRescanStatus = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = locator<PreferencesService>();
    final driveService = locator<DriveService>();

    final snap = await prefs.getSettingsSnapshot();
    final driveAvail = await driveService.isAvailable();

    GoogleSignInAccount? driveAccount;
    if (driveAvail) {
      driveAccount = driveService.currentAccount;
    }

    if (!mounted) return;
    setState(() {
      _folderPath = snap.libraryPath;
      _telemetryEnabled = snap.analyticsConsent ?? false;
      _themeMode = snap.themeMode ?? 'system';
      _metadataEnrichment = snap.metadataEnrichment;
      _autoRewind = snap.autoRewind;
      _skipInterval = snap.skipInterval;
      _driveAvailable = driveAvail;
      _driveAccount = driveAccount;
      _driveFolderName = snap.driveRootFolder?.name;
      _removeWhenFinished = snap.removeWhenFinished;
      _refreshOnStartup = snap.refreshOnStartup;
      _driveProgressSync = snap.driveProgressSync;
      _driveBackupFolderName = snap.driveBackupFolder?.name;
    });
  }

  Future<void> _selectFolder() async {
    setState(() => _pickingFolder = true);
    try {
      if (Platform.isAndroid) {
        final status = await Permission.manageExternalStorage.status;
        if (!status.isGranted) {
          final result = await Permission.manageExternalStorage.request();
          if (!result.isGranted) {
            if (result.isPermanentlyDenied) await openAppSettings();
            return;
          }
        }
      }
      final result = await FilePicker.getDirectoryPath(
        dialogTitle: 'Select your audiobooks folder',
      );
      // A native folder picker can stay open for minutes, during which the
      // user is free to navigate back and dispose this screen.
      if (!mounted) return;
      if (result != null && result != _folderPath) {
        await locator<PreferencesService>().setLibraryPath(result);
        if (!mounted) return;
        setState(() => _folderPath = result);
        widget.onFolderChanged?.call();
      }
    } finally {
      // `finally` runs on every exit path, so the guard is required here too.
      if (mounted) setState(() => _pickingFolder = false);
    }
  }

  Future<void> _setThemeMode(String value) async {
    await locator<PreferencesService>().setThemeMode(value);
    if (!mounted) return;
    ThemeMode themeMode;
    switch (value) {
      case 'light':
        themeMode = ThemeMode.light;
        break;
      case 'dark':
        themeMode = ThemeMode.dark;
        break;
      default:
        themeMode = ThemeMode.system;
    }
    AudioHandlerScope.of(context).themeModeNotifier.value = themeMode;
    setState(() => _themeMode = value);
  }

  Future<void> _setMetadataEnrichment(bool value) async {
    await locator<PreferencesService>().setMetadataEnrichment(value);
    if (!value) locator<EnrichmentService>().cancel();
    if (!mounted) return;
    setState(() => _metadataEnrichment = value);
  }

  Future<void> _setAutoRewind(bool value) async {
    final handler = AudioHandlerScope.of(context).audioHandler;
    await locator<PreferencesService>().setAutoRewind(value);
    handler.updateAutoRewind(value);
    if (!mounted) return;
    setState(() => _autoRewind = value);
  }

  Future<void> _setSkipInterval(int seconds) async {
    final handler = AudioHandlerScope.of(context).audioHandler;
    await locator<PreferencesService>().setSkipInterval(seconds);
    handler.updateSkipInterval(seconds);
    if (!mounted) return;
    setState(() => _skipInterval = seconds);
  }

  void _showSkipIntervalDialog() {
    showDialog<void>(
      context: context,
      builder: (context) => _SkipIntervalDialog(
        current: _skipInterval,
        onSelected: (value) {
          Navigator.pop(context);
          _setSkipInterval(value);
        },
      ),
    );
  }

  Future<void> _setTelemetry(bool value) async {
    await locator<PreferencesService>().setAnalyticsConsent(value);
    await TelemetryService.applyConsent(value);
    if (value) {
      TelemetryService.enableCrashHandler();
    } else {
      TelemetryService.disableCrashHandler();
    }
    if (!mounted) return;
    setState(() => _telemetryEnabled = value);
  }

  void _showColorModeDialog() {
    showDialog<void>(
      context: context,
      builder: (context) => _ColorModeDialog(
        current: _themeMode,
        onSelected: (value) {
          Navigator.pop(context);
          _setThemeMode(value);
        },
      ),
    );
  }

  Future<void> _connectDrive() async {
    final driveService = locator<DriveService>();
    final account = await driveService.signIn();
    if (!mounted) return;
    setState(() => _driveAccount = account);
  }

  Future<void> _disconnectDrive() async {
    await locator<DriveService>().signOut();
    await locator<DriveLibraryService>().removeUndownloadedBooks();
    if (!mounted) return;
    setState(() => _driveAccount = null);
    widget.onDriveRescanned?.call();
  }

  Future<void> _pickDriveFolder() async {
    final driveService = locator<DriveService>();
    final folder = await showDriveFolderPicker(context, driveService);
    if (folder == null || !mounted) return;
    await locator<PreferencesService>().setDriveRootFolder(
      folder.id,
      folder.name,
      isShared: folder.isShared,
    );
    if (!mounted) return;
    setState(() => _driveFolderName = folder.name);
    if (!mounted) return;
    await _rescanDrive();
  }

  Future<void> _setRemoveWhenFinished(bool value) async {
    await locator<PreferencesService>().setRemoveWhenFinished(value);
    if (!mounted) return;
    setState(() => _removeWhenFinished = value);
  }

  Future<void> _setDriveProgressSync(bool value) async {
    if (!value) {
      await locator<PreferencesService>().setDriveProgressSync(false);
      if (!mounted) return;
      setState(() => _driveProgressSync = false);
      return;
    }

    // Turning on: request write scope first.
    final driveService = locator<DriveService>();
    final granted = await driveService.requestWriteScope();
    if (!granted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text(
                  'Drive write access is required to sync progress.')),
        );
      }
      return;
    }

    // If the configured Drive folder is shared, we need a writable folder.
    final prefs = locator<PreferencesService>();
    final rootFolder = await prefs.getDriveRootFolder();
    final needFolderPick = rootFolder?.isShared ?? true;

    // Check if we already have a backup folder cached.
    final existing = await prefs.getDriveBackupFolder();
    if (existing != null && !needFolderPick) {
      await prefs.setDriveProgressSync(true);
      if (!mounted) return;
      setState(() => _driveProgressSync = true);
      return;
    }

    // Pick a writable folder.
    if (!mounted) return;
    final folder = await showDriveFolderPicker(context, driveService);
    if (folder == null || !mounted) {
      // User cancelled — leave toggle off.
      return;
    }

    if (folder.isShared) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text(
                  'Please choose a folder in your own Drive, not a shared folder.')),
        );
      }
      return;
    }

    // Try creating the Kōwhai subfolder to verify write access.
    try {
      final folderId = await driveService.findOrCreateFolder(
          folder.id, PositionBackupService.driveFolderName);
      await prefs.setDriveBackupFolder(folderId, '${folder.name}/${PositionBackupService.driveFolderName}');
      await prefs.setDriveProgressSync(true);
      if (mounted) {
        setState(() {
          _driveProgressSync = true;
          _driveBackupFolderName = '${folder.name}/Kowhai';
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text(
                  "Couldn't access that folder. Check permissions and try again.")),
        );
      }
    }
  }

  Future<void> _setRefreshOnStartup(bool value) async {
    await locator<PreferencesService>().setRefreshOnStartup(value);
    if (!mounted) return;
    setState(() => _refreshOnStartup = value);
  }

  Future<void> _rescanDrive() async {
    setState(() {
      _driveRescanning = true;
      _driveRescanStatus = 'Starting rescan…';
    });
    try {
      await locator<DriveLibraryService>().rescanDrive(
        onProgress: (status) {
          if (mounted) setState(() => _driveRescanStatus = status);
        },
      );
      widget.onDriveRescanned?.call();
    } finally {
      if (mounted) {
        setState(() {
          _driveRescanning = false;
          _driveRescanStatus = '';
        });
      }
    }
  }

  String get _themeModeLabel {
    switch (_themeMode) {
      case 'light':
        return 'Light';
      case 'dark':
        return 'Dark';
      default:
        return 'Follow system';
    }
  }

  IconData get _themeModeIcon {
    switch (_themeMode) {
      case 'light':
        return Icons.wb_sunny_rounded;
      case 'dark':
        return Icons.dark_mode_rounded;
      default:
        return Icons.phone_android_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        leading: BackButton(
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: ListView(
        children: [
          // ── Appearance ───────────────────────────────────────────────────
          ListTile(
            leading: Icon(_themeModeIcon),
            title: const Text('Color mode'),
            subtitle: Text(_themeModeLabel),
            onTap: _showColorModeDialog,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
          ),
          const Divider(),

          // ── Audiobooks ───────────────────────────────────────────────────
          ListTile(
            leading: const Icon(Icons.folder_rounded),
            title: const Text('Audiobooks folder'),
            subtitle: Text(
              _folderPath ?? 'No folder selected',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: _pickingFolder
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : null,
            onTap: _pickingFolder ? null : _selectFolder,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
          ),
          ListTile(
            leading: const Icon(Icons.sync_rounded),
            title: const Text('Refresh library on startup'),
            subtitle: const Text(
                'Scan for new or removed books each time the app opens'),
            trailing: Switch(
              value: _refreshOnStartup,
              onChanged: _setRefreshOnStartup,
            ),
            onTap: () => _setRefreshOnStartup(!_refreshOnStartup),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
          ),
          ListTile(
            leading: const Icon(Icons.auto_awesome_rounded),
            title: const Text('Get missing covers & metadata'),
            subtitle: const Text(
                'Fetches covers from Open Library for books without artwork'),
            trailing: Switch(
              value: _metadataEnrichment,
              onChanged: _setMetadataEnrichment,
            ),
            onTap: () => _setMetadataEnrichment(!_metadataEnrichment),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
          ),
          ListTile(
            leading: const Icon(Icons.fast_rewind_rounded),
            title: const Text('Smart rewind on resume'),
            subtitle: const Text(
                'Jumps back a few seconds if you haven\'t listened in a while'),
            trailing: Switch(
              value: _autoRewind,
              onChanged: _setAutoRewind,
            ),
            onTap: () => _setAutoRewind(!_autoRewind),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
          ),
          ListTile(
            leading: const Icon(Icons.skip_next_rounded),
            title: const Text('Skip interval'),
            subtitle: Text('${_skipInterval}s rewind / fast-forward'),
            onTap: _showSkipIntervalDialog,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
          ),
          const Divider(),

          // ── Cloud ────────────────────────────────────────────────────────
          if (_driveAvailable) ...[
            ListTile(
              leading: const Icon(Icons.cloud_rounded),
              title: const Text('Google Drive'),
              subtitle: Text(
                _driveAccount?.email ?? 'Not connected',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: _driveAccount == null
                  ? FilledButton(
                      onPressed: _connectDrive,
                      child: const Text('Connect'),
                    )
                  : OutlinedButton(
                      onPressed: _disconnectDrive,
                      child: const Text('Disconnect'),
                    ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
            ),
            if (_driveAccount != null) ...[
              ListTile(
                leading: const Icon(Icons.folder_shared_rounded),
                title: const Text('Drive folder'),
                subtitle: Text(
                  _driveFolderName ?? 'No folder selected',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: _pickDriveFolder,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
              ),
              ListTile(
                leading: _driveRescanning
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync_rounded),
                title: const Text('Rescan Drive'),
                subtitle: Text(_driveRescanning && _driveRescanStatus.isNotEmpty
                    ? _driveRescanStatus
                    : 'Check for new or removed audiobooks'),
                onTap: _driveRescanning ? null : _rescanDrive,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
              ),
              ListTile(
                leading: const Icon(Icons.delete_sweep_rounded),
                title: const Text('Remove when finished'),
                subtitle: const Text(
                    'Delete downloaded files 1 minute after finishing a book. '
                    'The book stays in your library as finished.'),
                trailing: Switch(
                  value: _removeWhenFinished,
                  onChanged: _setRemoveWhenFinished,
                ),
                onTap: () => _setRemoveWhenFinished(!_removeWhenFinished),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
              ),
              ListTile(
                leading: const Icon(Icons.cloud_sync_rounded),
                title: const Text('Sync progress to Drive'),
                subtitle: Text(
                  _driveProgressSync && _driveBackupFolderName != null
                      ? 'Saving to $_driveBackupFolderName'
                      : 'Back up your listening progress so you can pick up where you left off on any device',
                ),
                trailing: Switch(
                  value: _driveProgressSync,
                  onChanged: _setDriveProgressSync,
                ),
                onTap: () => _setDriveProgressSync(!_driveProgressSync),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
              ),
            ],
            const Divider(),
          ],

          // ── Privacy ──────────────────────────────────────────────────────
          ListTile(
            leading: const Icon(Icons.shield_rounded),
            title: const Text('Analytics & crash reports'),
            subtitle: const Text(
                'Send anonymous usage data to help improve Kōwhai'),
            trailing: Switch(
              value: _telemetryEnabled,
              onChanged: _setTelemetry,
            ),
            onTap: () => _setTelemetry(!_telemetryEnabled),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Text(
              'Data sent to Google Firebase is anonymous and includes no '
              'personal information such as book titles or file names.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
              ),
            ),
          ),

          const Divider(),

          // ── About ─────────────────────────────────────────────────────────
          ListTile(
            leading: const Icon(Icons.info_outline_rounded),
            title: const Text('About Kōwhai'),
            subtitle: const Text('Version, licences, source code'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AboutScreen()),
            ),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
          ),
        ],
      ),
    );
  }
}

class _SkipIntervalDialog extends StatelessWidget {
  final int current;
  final void Function(int) onSelected;

  const _SkipIntervalDialog({required this.current, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const options = [
      (value: 10, label: '10 seconds'),
      (value: 15, label: '15 seconds'),
      (value: 30, label: '30 seconds'),
      (value: 45, label: '45 seconds'),
      (value: 60, label: '60 seconds'),
    ];

    return Dialog(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Skip interval', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            ...options.map((opt) {
              final selected = opt.value == current;
              return InkWell(
                onTap: () => onSelected(opt.value),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      vertical: 14, horizontal: 8),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 48),
                    child: Row(
                      children: [
                        Text(
                          opt.label,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: selected
                                ? theme.colorScheme.primary
                                : theme.colorScheme.onSurface,
                            fontWeight:
                                selected ? FontWeight.w600 : null,
                          ),
                        ),
                        const Spacer(),
                        if (selected)
                          Icon(Icons.check_rounded,
                              color: theme.colorScheme.primary),
                      ],
                    ),
                  ),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }
}

class _ColorModeDialog extends StatelessWidget {
  final String current;
  final void Function(String) onSelected;

  const _ColorModeDialog({required this.current, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final options = [
      (value: 'system', label: 'Follow system', icon: Icons.phone_android_rounded),
      (value: 'light', label: 'Light', icon: Icons.wb_sunny_rounded),
      (value: 'dark', label: 'Dark', icon: Icons.dark_mode_rounded),
    ];

    return Dialog(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Color mode', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            ...options.map((opt) {
              final selected = opt.value == current;
              return InkWell(
                onTap: () => onSelected(opt.value),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      vertical: 14, horizontal: 8),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 48),
                    child: Row(
                      children: [
                        Icon(
                          opt.icon,
                          color: selected
                              ? theme.colorScheme.primary
                              : theme.colorScheme.onSurface,
                        ),
                        const SizedBox(width: 16),
                        Text(
                          opt.label,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: selected
                                ? theme.colorScheme.primary
                                : theme.colorScheme.onSurface,
                            fontWeight: selected ? FontWeight.w600 : null,
                          ),
                        ),
                        const Spacer(),
                        if (selected)
                          Icon(Icons.check_rounded,
                              color: theme.colorScheme.primary),
                      ],
                    ),
                  ),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }
}
