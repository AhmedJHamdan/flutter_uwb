import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_uwb/flutter_uwb.dart';

import 'brand.dart';
import 'qorvo_accessory.dart';
import 'widgets/radar.dart';
import 'widgets/readout_card.dart';

void main() {
  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'flutter_uwb',
      theme: buildBrandTheme(),
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

  void _togglePrecisionFind() {
    final caps = _capabilities;
    final canCamera = caps?.supportsCameraAssist ?? false;
    final canExtended = caps?.supportsExtendedDistance ?? false;
    setState(() {
      if (_cameraAssist || _extendedDistance) {
        _cameraAssist = false;
        _extendedDistance = false;
      } else {
        _cameraAssist = canCamera;
        _extendedDistance = canExtended;
      }
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          _cameraAssist || _extendedDistance
              ? 'Precision Find on'
              : 'Precision Find off',
        ),
      ),
    );
  }

  String get _distanceText {
    final m = _lastSample?.distanceMeters;
    return m == null ? '— m' : '${m.toStringAsFixed(2)} m';
  }

  String get _azimuthText {
    final az = _lastSample?.azimuthDegrees;
    if (_capabilities?.supportsDirection == false) return 'n/a';
    return az == null ? '—°' : '${az.toStringAsFixed(0)}°';
  }

  String get _signalText {
    if (!_scanning && _activeRangingId == null) return 'idle';
    if (_activeRangingId != null && _lastSample != null) return 'live';
    if (_activeRangingId != null) return 'pairing';
    return 'scan';
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final radarSize = math.min(size.width - 64, 320.0);
    final tracked = _trackedPolar();

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Brand.background,
        elevation: 0,
        title: Text(
          'flutter_uwb',
          style: TextStyle(
            color: Brand.text,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.4,
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Qorvo accessory demo',
            icon: const Icon(Icons.sensors, color: Brand.muted),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const QorvoAccessoryScreen()),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('UWB · RANGING', style: eyebrowStyle()),
              const SizedBox(height: 18),
              Center(
                child: SizedBox(
                  width: radarSize,
                  child: Radar(
                    trackedNormalizedDistance: tracked?.$1,
                    trackedAngleRadians: tracked?.$2,
                  ),
                ),
              ),
              const SizedBox(height: 18),
              if (_uwbAvailable == false)
                _StatusBanner(
                  text: 'UWB hardware not available on this device',
                  color: Brand.muted,
                ),
              if (_uwbAvailable == true &&
                  _activeRangingId == null &&
                  !_scanning)
                _StatusBanner(text: 'Tap Start Ranging to discover peers'),
              if (_scanning && _activeRangingId == null)
                _StatusBanner(text: 'Scanning for peers…'),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: ReadoutCard(label: 'Distance', value: _distanceText),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ReadoutCard(label: 'Azimuth', value: _azimuthText),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ReadoutCard(label: 'Signal', value: _signalText),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: Brand.primary,
                        foregroundColor: Brand.background,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: _scanning && _activeRangingId == null
                          ? _toggleScan
                          : (_activeRangingId != null
                                ? _stopRanging
                                : _toggleScan),
                      child: Text(
                        _activeRangingId != null
                            ? 'Stop Ranging'
                            : (_scanning ? 'Stop Discovery' : 'Start Ranging'),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      style: ButtonStyle(
                        foregroundColor: WidgetStateProperty.resolveWith(
                          (states) => states.contains(WidgetState.disabled)
                              ? Brand.primary.withValues(alpha: 0.45)
                              : Brand.primary,
                        ),
                        iconColor: WidgetStateProperty.resolveWith(
                          (states) => states.contains(WidgetState.disabled)
                              ? Brand.primary.withValues(alpha: 0.45)
                              : Brand.primary,
                        ),
                        side: WidgetStateProperty.resolveWith(
                          (states) => BorderSide(
                            color: states.contains(WidgetState.disabled)
                                ? Brand.primary.withValues(alpha: 0.35)
                                : Brand.primary,
                          ),
                        ),
                        padding: const WidgetStatePropertyAll(
                          EdgeInsets.symmetric(vertical: 14),
                        ),
                        shape: WidgetStatePropertyAll(
                          RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                      onPressed: _activeRangingId == null
                          ? null
                          : _togglePrecisionFind,
                      icon: const Icon(Icons.navigation_outlined, size: 18),
                      label: const Text(
                        'Precision Find',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ],
              ),
              if (_devicesById.isNotEmpty) ...[
                const SizedBox(height: 24),
                Text(
                  'Discovered peers'.toUpperCase(),
                  style: readoutLabelStyle(),
                ),
                const SizedBox(height: 8),
                for (final d in _devicesById.values)
                  _PeerTile(
                    device: d,
                    isActive: _activeRangingId == d.id,
                    onPair: () => _pairAndRange(d),
                  ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(
                  _error!,
                  style: TextStyle(color: Colors.redAccent.shade100),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Project a `RangingSample` onto the radar canvas. Distance is normalised
  /// against a 9 m envelope (the BPRF default); azimuth degrees → radians.
  (double, double)? _trackedPolar() {
    final s = _lastSample;
    if (s == null) return null;
    final r = (s.distanceMeters / 9.0).clamp(0.0, 1.0);
    final azDeg = s.azimuthDegrees ?? 90.0;
    final a = (90 - azDeg) * math.pi / 180.0;
    return (r, a);
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.text, this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF13182F),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Brand.muted.withValues(alpha: 0.25)),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(color: color ?? Brand.text, fontSize: 13),
      ),
    );
  }
}

class _PeerTile extends StatelessWidget {
  const _PeerTile({
    required this.device,
    required this.isActive,
    required this.onPair,
  });

  final UwbDevice device;
  final bool isActive;
  final VoidCallback onPair;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
        decoration: BoxDecoration(
          color: const Color(0xFF13182F),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isActive
                ? Brand.primary
                : Brand.muted.withValues(alpha: 0.25),
          ),
        ),
        child: Row(
          children: [
            Icon(
              isActive ? Icons.radar : Icons.phone_android,
              color: isActive ? Brand.primary : Brand.muted,
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    device.name,
                    style: const TextStyle(
                      color: Brand.text,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Text(
                    device.platform,
                    style: TextStyle(color: Brand.muted, fontSize: 11),
                  ),
                ],
              ),
            ),
            if (!isActive)
              TextButton(
                onPressed: onPair,
                style: TextButton.styleFrom(foregroundColor: Brand.primary),
                child: const Text('Pair & range'),
              ),
          ],
        ),
      ),
    );
  }
}
