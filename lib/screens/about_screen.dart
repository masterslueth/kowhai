import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/github_release_service.dart';
import 'licenses_screen.dart';

class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key});

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  String _installedVersion = '';
  GithubRelease? _latestRelease;
  bool _checkingUpdate = false;

  @override
  void initState() {
    super.initState();
    _loadVersionInfo();
  }

  Future<void> _loadVersionInfo() async {
    final info = await PackageInfo.fromPlatform();
    if (!mounted) return;
    setState(() {
      _installedVersion = info.version;
      _checkingUpdate = true;
    });

    final release = await GithubReleaseService().fetchLatest();
    if (!mounted) return;
    setState(() {
      _latestRelease = release;
      _checkingUpdate = false;
    });
  }

  /// Opens [url] in an external app, refusing anything that is not plain web
  /// HTTP(S).
  ///
  /// `launchUrl(mode: externalApplication)` dispatches an implicit VIEW intent
  /// with whatever scheme the URI carries, so a tampered or unexpected
  /// `html_url` from the releases API could otherwise hand `javascript:`,
  /// `intent:` or a `file:` URI to another app. The manifest `<queries>` block
  /// only gates `canLaunchUrl` visibility — it does not restrict dispatch.
  Future<void> _open(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    const allowed = {'http', 'https'};
    if (!allowed.contains(uri.scheme.toLowerCase())) {
      debugPrint('[Kowhai:About] refusing to open non-web scheme: ${uri.scheme}');
      return;
    }
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication) &&
        mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't open that link.")),
      );
    }
  }

  /// Returns true if [latest] is a newer semver than [installed].
  bool _isNewer(String installed, String latest) {
    List<int> parse(String v) => v
        .split('.')
        .map((p) => int.tryParse(p) ?? 0)
        .toList();
    final a = parse(installed);
    final b = parse(latest);
    for (var i = 0; i < b.length; i++) {
      final ai = i < a.length ? a[i] : 0;
      if (b[i] > ai) return true;
      if (b[i] < ai) return false;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final hasUpdate = _latestRelease != null &&
        _installedVersion.isNotEmpty &&
        _isNewer(_installedVersion, _latestRelease!.version);

    return Scaffold(
      appBar: AppBar(title: const Text('About Kōwhai')),
      body: ListView(
        children: [
          // ── Identity block ────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 32),
            child: Column(
              children: [
                _KowhaiIcon(size: 80),
                const SizedBox(height: 16),
                Text(
                  'Kōwhai',
                  style: theme.textTheme.headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                if (_installedVersion.isNotEmpty)
                  Text(
                    'Version $_installedVersion',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color:
                          theme.colorScheme.onSurface.withValues(alpha: 0.55),
                    ),
                  ),
                const SizedBox(height: 8),
                // ── Update status ──────────────────────────────────────────
                if (_checkingUpdate)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.4),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Checking for updates…',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.45),
                        ),
                      ),
                    ],
                  )
                else if (hasUpdate)
                  GestureDetector(
                    onTap: () => _open(_latestRelease!.url),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.new_releases_rounded,
                            size: 16, color: theme.colorScheme.primary),
                        const SizedBox(width: 6),
                        Text(
                          'v${_latestRelease!.version} available',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(Icons.open_in_new,
                            size: 13, color: theme.colorScheme.primary),
                      ],
                    ),
                  )
                else if (_latestRelease != null)
                  Text(
                    'Up to date',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color:
                          theme.colorScheme.onSurface.withValues(alpha: 0.45),
                    ),
                  ),
              ],
            ),
          ),

          const Divider(),

          // ── Links ─────────────────────────────────────────────────────────
          ListTile(
            leading: const Icon(Icons.language_rounded),
            title: const Text('Kōwhai website'),
            subtitle: const Text('kowhai.mattsteed.com'),
            trailing: const Icon(Icons.open_in_new, size: 18),
            onTap: () => _open('https://kowhai.mattsteed.com'),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
          ),
          ListTile(
            leading: const Icon(Icons.shield_outlined),
            title: const Text('Privacy policy'),
            subtitle: const Text('How Kōwhai handles your data'),
            trailing: const Icon(Icons.open_in_new, size: 18),
            onTap: () =>
                _open('https://kowhai.mattsteed.com/privacy-policy/'),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
          ),
          ListTile(
            leading: const Icon(Icons.code_rounded),
            title: const Text('Source code'),
            subtitle: const Text('github.com/masterslueth/kowhai'),
            trailing: const Icon(Icons.open_in_new, size: 18),
            onTap: () =>
                _open('https://github.com/masterslueth/kowhai'),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
          ),
          ListTile(
            leading: const Icon(Icons.download_rounded),
            title: const Text('Latest release'),
            subtitle: Text(
              _latestRelease != null
                  ? 'v${_latestRelease!.version} on GitHub'
                  : 'github.com/masterslueth/kowhai/releases',
            ),
            trailing: const Icon(Icons.open_in_new, size: 18),
            onTap: () => _open(
              _latestRelease?.url ?? GithubReleaseService.releasesPageUrl,
            ),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
          ),

          const Divider(),

          // ── Legal ─────────────────────────────────────────────────────────
          ListTile(
            leading: const Icon(Icons.balance_rounded),
            title: const Text('Third-party libraries'),
            subtitle: const Text('Open-source licences'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const LicensesScreen()),
            ),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
          ),
        ],
      ),
    );
  }
}

// ── Kōwhai icon widget ────────────────────────────────────────────────────────

class _KowhaiIcon extends StatelessWidget {
  final double size;
  const _KowhaiIcon({required this.size});

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      'assets/kowhai-icon-512.png',
      width: size,
      height: size,
      semanticLabel: 'Kōwhai',
    );
  }
}
