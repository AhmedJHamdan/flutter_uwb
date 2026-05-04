import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_uwb/flutter_uwb.dart';

import 'qorvo_accessory.dart';

void main() {
  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'flutter_uwb example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      home: const _Home(),
    );
  }
}

class _Home extends StatefulWidget {
  const _Home();

  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  final FlutterUwb _uwb = FlutterUwb.instance;
  bool? _uwbAvailable;
  bool _scanning = false;
  String? _error;
  bool _cameraAssist = false;
  bool _extendedDistance = false;
  DeviceCapabilities? _capabilities;
  final Map<String, UwbDevice> _devicesById = {};
  RangingSample? _lastSample;
  String? _activeRangingId;
  StreamSubscription<UwbDevice>? _deviceFoundSub;
  StreamSubscription<String>? _deviceLostSub;
  StreamSubscription<RangingSample>? _samplesSub;
  StreamSubscription<String>? _peerLostSub;
  StreamSubscription<RangingErrorEvent>? _errorsSub;
  StreamSubscription<IncomingRequest>? _incomingSub;

  @override
  void initState() {
    super.initState();
    _checkUwb();
    _deviceFoundSub = _uwb.deviceFound.listen((d) {
      if (!mounted) return;
      setState(() => _devicesById[d.id] = d);
    });
    _deviceLostSub = _uwb.deviceLost.listen((id) {
      if (!mounted) return;
      setState(() => _devicesById.remove(id));
    });
    _samplesSub = _uwb.rangingSamples.listen((s) {
      if (!mounted) return;
      setState(() => _lastSample = s);
    });
    _peerLostSub = _uwb.peerLost.listen((id) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Peer lost: $id')));
    });
    _errorsSub = _uwb.rangingErrors.listen((e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ranging error (${e.deviceId}): ${e.message}')),
      );
    });
    _incomingSub = _uwb.incomingRequests.listen(_handleIncomingRequest);
  }

  Future<void> _handleIncomingRequest(IncomingRequest req) async {
    final id = req.device.id;
    try {
      final myToken = await _uwb.getLocalToken(UwbRole.controlee);
      await _uwb.acceptRequest(id, myToken);
      await _uwb.startRanging(id);
      if (mounted) setState(() => _activeRangingId = id);
    } on UwbException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Auto-accept failed: ${e.message}')),
      );
    }
  }

  @override
  void dispose() {
    _deviceFoundSub?.cancel();
    _deviceLostSub?.cancel();
    _samplesSub?.cancel();
    _peerLostSub?.cancel();
    _errorsSub?.cancel();
    _incomingSub?.cancel();
    if (_activeRangingId != null) _uwb.stopRanging();
    if (_scanning) _uwb.stopDiscovery();
    super.dispose();
  }

  Future<void> _checkUwb() async {
    try {
      final available = await _uwb.isUwbAvailable();
      final caps = await _uwb.getDeviceCapabilities();
      if (!mounted) return;
      setState(() {
        _uwbAvailable = available;
        _capabilities = caps;
      });
    } on UwbException catch (e) {
      if (!mounted) return;
      setState(() => _error = 'isUwbAvailable failed: ${e.message}');
    }
  }

  Future<void> _toggleScan() async {
    if (_scanning) {
      try {
        await _uwb.stopDiscovery();
      } on UwbException catch (e) {
        if (mounted) setState(() => _error = e.message);
      }
      if (mounted) {
        setState(() {
          _scanning = false;
          _devicesById.clear();
        });
      }
      return;
    }

    try {
      final name =
          '${Platform.localHostname}-${DateTime.now().millisecondsSinceEpoch % 10000}';
      await _uwb.startDiscovery(name);
      if (mounted) {
        setState(() {
          _scanning = true;
          _error = null;
        });
      }
    } on UwbException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _pairAndRange(UwbDevice device) async {
    final id = device.id;
    try {
      // Apple-FiRa accessory peers (cross-OS or vendor accessories)
      // negotiate session keys inside startRanging itself; same-OS
      // peers need a token exchange first.
      if (!device.platform.startsWith('accessory')) {
        await _uwb.pairWith(id);
        if (!mounted) return;
      }
      await _uwb.startRanging(
        id,
        options: RangingOptions(
          cameraAssist: _cameraAssist,
          extendedDistance: _extendedDistance,
        ),
      );
      if (mounted) setState(() => _activeRangingId = id);
    } on UwbException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  String _rangingSubtitle() {
    if (_lastSample == null) return 'waiting for first sample…';
    final distance =
        'distance: ${_lastSample!.distanceMeters.toStringAsFixed(2)} m';
    // Hide az/el on devices whose UWB hardware lacks AoA (iPhone 14+
    // ship a single UWB antenna; direction can never populate).
    if (_capabilities?.supportsDirection == false) {
      return '$distance · distance only on this device';
    }
    final az = _lastSample!.azimuthDegrees?.toStringAsFixed(1) ?? '?';
    final el = _lastSample!.elevationDegrees?.toStringAsFixed(1) ?? '?';
    return '$distance · az: $az° · el: $el°';
  }

  Future<void> _stopRanging() async {
    try {
      await _uwb.stopRanging();
    } on UwbException catch (_) {}
    if (mounted) {
      setState(() {
        _activeRangingId = null;
        _lastSample = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('flutter_uwb example'),
        actions: [
          IconButton(
            tooltip: 'Qorvo accessory demo',
            icon: const Icon(Icons.sensors),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const QorvoAccessoryScreen()),
            ),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: ListTile(
                title: const Text('UWB hardware'),
                subtitle: Text(switch (_uwbAvailable) {
                  null => 'checking…',
                  true => 'available on this device',
                  false => 'not available',
                }),
                trailing: IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: _checkUwb,
                ),
              ),
            ),
            if (_capabilities != null) _CapabilitiesCard(_capabilities!),
            _RangingOptionsCard(
              cameraAssist: _cameraAssist,
              extendedDistance: _extendedDistance,
              cameraAssistSupported:
                  _capabilities?.supportsCameraAssist ?? false,
              extendedDistanceSupported:
                  _capabilities?.supportsExtendedDistance ?? false,
              directionSupported: _capabilities?.supportsDirection ?? false,
              onCameraAssistChanged: (v) => setState(() => _cameraAssist = v),
              onExtendedDistanceChanged: (v) =>
                  setState(() => _extendedDistance = v),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              icon: Icon(_scanning ? Icons.stop : Icons.search),
              label: Text(_scanning ? 'Stop discovery' : 'Start discovery'),
              onPressed: _toggleScan,
            ),
            if (_activeRangingId != null) ...[
              const SizedBox(height: 12),
              Card(
                color: Theme.of(context).colorScheme.primaryContainer,
                child: ListTile(
                  title: Text('Ranging $_activeRangingId'),
                  subtitle: Text(_rangingSubtitle()),
                  trailing: TextButton(
                    onPressed: _stopRanging,
                    child: const Text('Stop'),
                  ),
                ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Colors.red)),
            ],
            const SizedBox(height: 12),
            Expanded(
              child: _devicesById.isEmpty
                  ? const Center(child: Text('No devices yet'))
                  : ListView(
                      children: [
                        for (final d in _devicesById.values)
                          ListTile(
                            leading: const Icon(Icons.phone_android),
                            title: Text(d.name),
                            subtitle: Text('${d.platform} · ${d.id}'),
                            trailing: TextButton(
                              onPressed: () => _pairAndRange(d),
                              child: const Text('Pair & range'),
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CapabilitiesCard extends StatelessWidget {
  const _CapabilitiesCard(this.caps);

  final DeviceCapabilities caps;

  @override
  Widget build(BuildContext context) {
    final lines = <String>[
      'distance: ${caps.supportsPreciseDistance ? "yes" : "no"}'
          ' · direction: ${caps.supportsDirection ? "yes" : "no"}',
      'camera assist: ${caps.supportsCameraAssist ? "yes" : "no"}'
          ' · extended distance: ${caps.supportsExtendedDistance ? "yes" : "no"}',
      if (caps.supportedChannels.isNotEmpty)
        'channels: ${caps.supportedChannels.join(", ")}',
      if (caps.supportedConfigIds.isNotEmpty)
        'configIds: ${caps.supportedConfigIds.join(", ")}',
      if (caps.minRangingIntervalMs != null)
        'min interval: ${caps.minRangingIntervalMs} ms',
    ];
    return Card(
      child: ListTile(
        title: const Text('Capabilities'),
        subtitle: Text(lines.join('\n')),
        isThreeLine: true,
      ),
    );
  }
}

class _RangingOptionsCard extends StatelessWidget {
  const _RangingOptionsCard({
    required this.cameraAssist,
    required this.extendedDistance,
    required this.cameraAssistSupported,
    required this.extendedDistanceSupported,
    required this.directionSupported,
    required this.onCameraAssistChanged,
    required this.onExtendedDistanceChanged,
  });

  final bool cameraAssist;
  final bool extendedDistance;
  final bool cameraAssistSupported;
  final bool extendedDistanceSupported;
  final bool directionSupported;
  final ValueChanged<bool> onCameraAssistChanged;
  final ValueChanged<bool> onExtendedDistanceChanged;

  @override
  Widget build(BuildContext context) {
    final cameraAssistSubtitle = directionSupported
        ? 'Run an ARSession alongside NISession to keep direction'
        : 'This device has no UWB AoA antenna (iPhone 14+); camera assist '
              'will not produce direction here, only on capable peers.';
    return Card(
      child: Column(
        children: [
          SwitchListTile(
            title: const Text('Camera assist (iOS)'),
            subtitle: Text(cameraAssistSubtitle),
            value: cameraAssist,
            onChanged: cameraAssistSupported ? onCameraAssistChanged : null,
          ),
          SwitchListTile(
            title: const Text('Extended distance (iOS 17+ peer mode)'),
            subtitle: const Text('Range beyond the default ~9m envelope'),
            value: extendedDistance,
            onChanged: extendedDistanceSupported
                ? onExtendedDistanceChanged
                : null,
          ),
        ],
      ),
    );
  }
}
