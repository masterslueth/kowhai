import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_chrome_cast/flutter_chrome_cast.dart';

Future<bool> _vpnActive() async {
  try {
    final interfaces = await NetworkInterface.list();
    return interfaces.any((i) {
      final n = i.name.toLowerCase();
      return n.startsWith('tun') ||
          n.startsWith('ppp') ||
          n.startsWith('tap') ||
          n.startsWith('vpn');
    });
  } catch (_) {
    return false;
  }
}

Future<void> showCastPicker(BuildContext context) async {
  final discovery = GoogleCastDiscoveryManager.instance;
  final sessionManager = GoogleCastSessionManager.instance;

  final vpn = await _vpnActive();
  await discovery.startDiscovery();
  if (!context.mounted) {
    // The guard alone is not enough: discovery is a PROCESS-LIFETIME
    // singleton running mDNS, and the early return would leave it scanning
    // the network for the rest of the process. Stop it on every exit path.
    await discovery.stopDiscovery();
    return;
  }

  try {
    await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Cast to device'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (vpn)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.warning_amber_rounded,
                        size: 20,
                        color: Theme.of(ctx).colorScheme.error),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'A VPN connection is active. This may prevent '
                        'casting from working correctly.',
                        style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                              color: Theme.of(ctx).colorScheme.error,
                            ),
                      ),
                    ),
                  ],
                ),
              ),
            Flexible(
              child: StreamBuilder<List<GoogleCastDevice>>(
                stream: discovery.devicesStream,
                initialData: discovery.devices,
                builder: (ctx, snap) {
                  final devices = snap.data ?? [];
                  if (devices.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 20,
                            height: 20,
                            child:
                                CircularProgressIndicator(strokeWidth: 2),
                          ),
                          SizedBox(width: 12),
                          Text('Scanning for devices…'),
                        ],
                      ),
                    );
                  }
                  return ListView.builder(
                    shrinkWrap: true,
                    itemCount: devices.length,
                    itemBuilder: (ctx, i) {
                      final device = devices[i];
                      return ListTile(
                        leading: const Icon(Icons.cast),
                        title: Text(device.friendlyName),
                        subtitle: device.modelName != null
                            ? Text(device.modelName!)
                            : null,
                        onTap: () {
                          sessionManager.startSessionWithDevice(device);
                          Navigator.of(ctx).pop();
                        },
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Cancel'),
        ),
      ],
    ),
    );
  } finally {
    await discovery.stopDiscovery();
  }
}
