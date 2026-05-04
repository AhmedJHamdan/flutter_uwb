import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_uwb/flutter_uwb.dart';

/// Minimal vendor-profile demo: registers the Qorvo DWM3001CDK BLE
/// service and ranges against the first one that shows up.
///
/// Wire it up from the example home with a feature toggle, e.g.:
///
/// ```dart
/// Navigator.of(context).push(MaterialPageRoute(
///   builder: (_) => const QorvoAccessoryScreen(),
/// ));
/// ```
///
/// The UUIDs below come from Qorvo's published FiRa MK profile — the
/// service exposes a `Rx` characteristic the iPhone writes to and a
/// `Tx` characteristic the dongle notifies on. Other vendors will
/// publish their own UUIDs; the rest of this screen is identical.
class QorvoAccessoryScreen extends StatefulWidget {
  const QorvoAccessoryScreen({super.key});

  @override
  State<QorvoAccessoryScreen> createState() => _QorvoAccessoryScreenState();
}

class _QorvoAccessoryScreenState extends State<QorvoAccessoryScreen> {
  static const _serviceUuid = '6E40FFF0-B5A3-F393-E0A9-E50E24DCCA9E';
  static const _rxUuid = '6E400002-B5A3-F393-E0A9-E50E24DCCA9E';
  static const _txUuid = '6E400003-B5A3-F393-E0A9-E50E24DCCA9E';
  static const _vendorTag = 'qorvo';

  final FlutterUwb _uwb = FlutterUwb.instance;
  final Map<String, UwbDevice> _devices = {};
  RangingSample? _lastSample;
  String? _activeId;
  String? _error;

  StreamSubscription<UwbDevice>? _foundSub;
  StreamSubscription<String>? _lostSub;
  StreamSubscription<RangingSample>? _samplesSub;
  StreamSubscription<RangingErrorEvent>? _errSub;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      await _uwb.registerAccessoryProfile(
        serviceUuid: _serviceUuid,
        rxUuid: _rxUuid,
        txUuid: _txUuid,
        vendorTag: _vendorTag,
      );
      await _uwb.startDiscovery('flutter_uwb-qorvo-host');
    } on UwbException catch (e) {
      if (mounted) setState(() => _error = e.message);
      return;
    }

    _foundSub = _uwb.deviceFound.listen((d) {
      if (!d.platform.startsWith('accessory')) return;
      if (mounted) setState(() => _devices[d.id] = d);
    });
    _lostSub = _uwb.deviceLost.listen((id) {
      if (mounted) setState(() => _devices.remove(id));
    });
    _samplesSub = _uwb.rangingSamples.listen((s) {
      if (mounted) setState(() => _lastSample = s);
    });
    _errSub = _uwb.rangingErrors.listen((e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('${e.code.name}: ${e.message}')));
    });
  }

  Future<void> _range(UwbDevice d) async {
    try {
      await _uwb.startRanging(d.id);
      if (mounted) setState(() => _activeId = d.id);
    } on UwbException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _stop() async {
    try {
      await _uwb.stopRanging();
    } on UwbException catch (_) {}
    if (mounted) {
      setState(() {
        _activeId = null;
        _lastSample = null;
      });
    }
  }

  @override
  void dispose() {
    _foundSub?.cancel();
    _lostSub?.cancel();
    _samplesSub?.cancel();
    _errSub?.cancel();
    _uwb.stopRanging();
    _uwb.stopDiscovery();
    _uwb.unregisterAccessoryProfile(_serviceUuid);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Qorvo DWM3001CDK')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null)
              Text(_error!, style: const TextStyle(color: Colors.red)),
            if (_activeId != null)
              Card(
                child: ListTile(
                  title: Text('Ranging $_activeId'),
                  subtitle: Text(
                    _lastSample == null
                        ? 'waiting for first sample…'
                        : 'distance: ${_lastSample!.distanceMeters.toStringAsFixed(2)} m',
                  ),
                  trailing: TextButton(
                    onPressed: _stop,
                    child: const Text('Stop'),
                  ),
                ),
              ),
            const SizedBox(height: 12),
            Expanded(
              child: _devices.isEmpty
                  ? const Center(child: Text('Power on the Qorvo dongle…'))
                  : ListView(
                      children: [
                        for (final d in _devices.values)
                          ListTile(
                            leading: const Icon(Icons.sensors),
                            title: Text(d.name),
                            subtitle: Text('${d.platform} · ${d.id}'),
                            trailing: TextButton(
                              onPressed: () => _range(d),
                              child: const Text('Range'),
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
