import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_uwb/flutter_uwb.dart';

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
  final Map<String, UwbDevice> _devicesById = {};
  RangingSample? _lastSample;
  String? _activeRangingId;
  StreamSubscription<UwbDevice>? _deviceFoundSub;
  StreamSubscription<String>? _deviceLostSub;
  StreamSubscription<RangingSample>? _samplesSub;
  StreamSubscription<String>? _peerLostSub;
  StreamSubscription<RangingErrorEvent>? _errorsSub;

  @override
  void initState() {
    super.initState();
    _checkUwb();
    _deviceFoundSub = _uwb.deviceFound.listen((d) {
      final id = d.id;
      if (id == null || !mounted) return;
      setState(() => _devicesById[id] = d);
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Peer lost: $id')),
      );
    });
    _errorsSub = _uwb.rangingErrors.listen((e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ranging error (${e.deviceId}): ${e.message}')),
      );
    });
  }

  @override
  void dispose() {
    _deviceFoundSub?.cancel();
    _deviceLostSub?.cancel();
    _samplesSub?.cancel();
    _peerLostSub?.cancel();
    _errorsSub?.cancel();
    if (_activeRangingId != null) _uwb.stopRanging();
    if (_scanning) _uwb.stopDiscovery();
    super.dispose();
  }

  Future<void> _checkUwb() async {
    try {
      final available = await _uwb.isUwbAvailable();
      if (!mounted) return;
      setState(() => _uwbAvailable = available);
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
      await _uwb.startDiscovery('demo');
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
    if (id == null) return;
    try {
      await _uwb.pairWith(id);
      if (!mounted) return;
      await _uwb.startRanging(id);
      if (mounted) setState(() => _activeRangingId = id);
    } on UwbException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    }
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
      appBar: AppBar(title: const Text('flutter_uwb example')),
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
                  subtitle: Text(_lastSample == null
                      ? 'waiting for first sample…'
                      : 'distance: ${_lastSample!.distanceMeters?.toStringAsFixed(2) ?? "?"} m'
                          ' · az: ${_lastSample!.azimuthDegrees?.toStringAsFixed(1) ?? "?"}°'
                          ' · el: ${_lastSample!.elevationDegrees?.toStringAsFixed(1) ?? "?"}°'),
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
                            title: Text(d.name ?? 'Unnamed'),
                            subtitle: Text(
                              '${d.platform ?? "?"} · ${d.id ?? "?"}',
                            ),
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
