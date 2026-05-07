import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_uwb/flutter_uwb.dart';

import 'brand.dart';
import 'widgets/custom_adapter_demo.dart';
import 'widgets/precision_arrow.dart';
import 'widgets/radar.dart';
import 'widgets/readout_card.dart';

/// BLE profile advertised by Qorvo's QANI firmware on the DWM3001CDK,
/// verified live via a Mac GATT enumeration:
///
///   service  2E938FD0-6A61-11ED-A1EB-0242AC120002
///   write    2E93998A-...  (host → accessory  — Apple FiRa "rx")
///   notify   2E939AF2-...  (accessory → host  — Apple FiRa "tx")
class _QorvoProfile {
  static const serviceUuid = '2E938FD0-6A61-11ED-A1EB-0242AC120002';
  static const rxUuid = '2E93998A-6A61-11ED-A1EB-0242AC120002';
  static const txUuid = '2E939AF2-6A61-11ED-A1EB-0242AC120002';
  static const vendorTag = 'qorvo';
}

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
  bool _demoAdapterEnabled = false;
  DeviceCapabilities? _capabilities;
  final Map<String, UwbDevice> _devicesById = {};
  RangingSample? _lastSample;
  String? _activeRangingId;
  int? _lastHapticBin;
  String? _lastVerb;
  DateTime? _directionLostSince;
  Timer? _directionLostTimer;
  int _currentTab = 0;

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
    // Register the Qorvo accessory profile so DWM3001CDK boards surface in
    // the same `deviceFound` stream as iOS / Android peers.
    _uwb.registerAccessoryProfile(
      serviceUuid: _QorvoProfile.serviceUuid,
      rxUuid: _QorvoProfile.rxUuid,
      txUuid: _QorvoProfile.txUuid,
      vendorTag: _QorvoProfile.vendorTag,
    );
    _deviceFoundSub = _uwb.deviceFound.listen((d) {
      if (!mounted) return;
      setState(() => _devicesById[d.id] = d);
    });
    _deviceLostSub = _uwb.deviceLost.listen((id) {
      if (!mounted) return;
      setState(() => _devicesById.remove(id));
    });
    _samplesSub = _uwb.rangingSamples.listen(_onSample);
    _peerLostSub = _uwb.peerLost.listen((id) {
      if (!mounted) return;
      developer.log('SNACK peerLost: $id', name: 'flutter_uwb.example');
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Peer lost: $id')));
    });
    _errorsSub = _uwb.rangingErrors.listen((e) {
      developer.log(
        'SNACK rangingError: code=${e.code.name} dev=${e.deviceId} msg=${e.message}',
        name: 'flutter_uwb.example',
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ranging error (${e.deviceId}): ${e.message}')),
      );
    });
    _incomingSub = _uwb.incomingRequests.listen(_handleIncomingRequest);
  }

  void _onSample(RangingSample s) {
    if (!mounted) return;
    final hadDirection = _lastSample?.azimuthDegrees != null;
    final hasDirection = s.azimuthDegrees != null;

    if (_activeRangingId != null && hasDirection) {
      final bin = proximityBin(s.distanceMeters);
      if (_lastHapticBin != null && bin < _lastHapticBin!) {
        HapticFeedback.selectionClick();
      }
      _lastHapticBin = bin;

      final verb = proximityVerb(s.distanceMeters);
      if (verb == 'HERE' && _lastVerb != 'HERE') {
        HapticFeedback.heavyImpact();
      } else if (_lastVerb == 'HERE' && verb != 'HERE') {
        HapticFeedback.lightImpact();
      }
      _lastVerb = verb;
    }

    if (hadDirection && !hasDirection) {
      _directionLostSince ??= DateTime.now();
      // Re-trigger a rebuild after the 800 ms grace window so the body
      // switcher picks the home view if direction never returns.
      _directionLostTimer?.cancel();
      _directionLostTimer = Timer(const Duration(milliseconds: 800), () {
        if (mounted) setState(() {});
      });
    } else if (hasDirection) {
      _directionLostSince = null;
      _directionLostTimer?.cancel();
    }

    setState(() => _lastSample = s);
  }

  bool get _showPrecision {
    if (_activeRangingId == null) return false;
    final s = _lastSample;
    if (s?.azimuthDegrees != null) return true;
    final lostAt = _directionLostSince;
    if (lostAt == null) return false;
    return DateTime.now().difference(lostAt) <
        const Duration(milliseconds: 800);
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
    _directionLostTimer?.cancel();
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
        // Default the precision toggles ON when the hardware supports them
        // — matches the "premium experience by default" expectation. The
        // user can flip them off in Settings before starting a session.
        _cameraAssist = caps.supportsCameraAssist;
        _extendedDistance = caps.supportsExtendedDistance;
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
    // Only one ranging session can be active at a time on iOS — a second
    // startRanging while another is live fails with -5887 (sessionFailed)
    // because the AR/camera resources are already claimed. Tear the
    // previous session down first.
    if (_activeRangingId != null && _activeRangingId != id) {
      await _stopRanging();
    }
    final skipsTokenExchange = device.platform.startsWith('accessory') ||
        device.platform.startsWith('static-pair');
    final cameraAssist = _cameraAssist;
    final extendedDistance = _extendedDistance;
    try {
      if (!skipsTokenExchange) {
        await _uwb.pairWith(id);
        if (!mounted) return;
      }
      await _uwb.startRanging(
        id,
        options: RangingOptions(
          cameraAssist: cameraAssist,
          extendedDistance: extendedDistance,
        ),
      );
      if (mounted) setState(() => _activeRangingId = id);
    } on UwbException catch (e) {
      developer.log(
        'SNACK pairAndRange UwbException: dev=$id platform=${device.platform} '
        'cameraAssist=$cameraAssist extDist=$extendedDistance msg=${e.message}',
        name: 'flutter_uwb.example',
      );
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
    _directionLostTimer?.cancel();
    if (mounted) {
      setState(() {
        _activeRangingId = null;
        _lastSample = null;
        _lastHapticBin = null;
        _lastVerb = null;
        _directionLostSince = null;
      });
    }
  }

  void _setCameraAssist(bool value) {
    setState(() => _cameraAssist = value);
  }

  void _setExtendedDistance(bool value) {
    setState(() => _extendedDistance = value);
  }

  Future<void> _setDemoAdapterEnabled(bool value) async {
    if (value) {
      await _uwb.registerAccessoryAdapter(const DemoTagAdapter());
      // Surface a synthetic tile so the user can tap to exercise the
      // adapter framework without real DemoTag hardware.
      final device = UwbDevice(
        id: demoTagDeviceId,
        name: 'DemoTag',
        platform: 'accessory:$demoTagVendorTag',
      );
      if (!_devicesById.containsKey(device.id)) {
        setState(() => _devicesById[device.id] = device);
      }
    } else {
      await _uwb.unregisterAccessoryAdapter(demoTagVendorTag);
      setState(() => _devicesById.remove(demoTagDeviceId));
    }
    if (mounted) setState(() => _demoAdapterEnabled = value);
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

  String get _elevationText {
    final el = _lastSample?.elevationDegrees;
    if (_capabilities?.supportsDirection == false) return 'n/a';
    if (el == null) return '—°';
    final sign = el >= 0 ? '+' : '';
    return '$sign${el.toStringAsFixed(0)}°';
  }

  String get _signalText {
    if (!_scanning && _activeRangingId == null) return 'idle';
    if (_activeRangingId != null && _lastSample != null) return 'live';
    if (_activeRangingId != null) return 'pairing';
    return 'scan';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: IndexedStack(
          index: _currentTab,
          children: [_buildRangingTab(context), _buildSettingsTab(context)],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        backgroundColor: const Color(0xFF13182F),
        indicatorColor: Brand.primary.withValues(alpha: 0.18),
        surfaceTintColor: Colors.transparent,
        height: 64,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        selectedIndex: _currentTab,
        onDestinationSelected: (i) => setState(() => _currentTab = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.radar_outlined),
            selectedIcon: Icon(Icons.radar),
            label: 'Ranging',
          ),
          NavigationDestination(
            icon: Icon(Icons.tune_outlined),
            selectedIcon: Icon(Icons.tune),
            label: 'Settings',
          ),
        ],
      ),
    );
  }

  Widget _buildRangingTab(BuildContext context) {
    final size = MediaQuery.of(context).size;
    // First-frame guard: on some Android configs (e.g. Galaxy on Vulkan/
    // Impeller) MediaQuery.size is Size.zero on the very first build, which
    // produces SizedBox(width: -64) and trips a downstream
    // 'child == _child' / Duplicate GlobalKey assertion. Clamp positive.
    final radarSize = math.min(size.width - 64, 320.0)
        .clamp(80.0, 320.0)
        .toDouble();
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'UWB · RANGING · ${_signalText.toUpperCase()}',
            style: eyebrowStyle(),
          ),
          const SizedBox(height: 18),
          Center(
            child: SizedBox(
              width: radarSize,
              height: radarSize,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 240),
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeIn,
                child: _showPrecision
                    ? Center(
                        key: const ValueKey('arrow'),
                        child: PrecisionArrow(
                          azimuthDegrees: _lastSample!.azimuthDegrees ?? 0,
                          elevationDegrees: _lastSample!.elevationDegrees,
                          distanceMeters: _lastSample!.distanceMeters,
                          size: radarSize * 0.85,
                        ),
                      )
                    : Radar(
                        key: const ValueKey('radar'),
                        active: _activeRangingId != null,
                      ),
              ),
            ),
          ),
          const SizedBox(height: 18),
          if (_uwbAvailable == false)
            _StatusBanner(
              text: 'UWB hardware not available on this device',
              color: Brand.muted,
            ),
          if (_uwbAvailable == true && _activeRangingId == null && !_scanning)
            _StatusBanner(text: 'Tap Start Ranging to discover peers'),
          if (_scanning && _activeRangingId == null)
            _StatusBanner(text: 'Scanning for peers…'),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: ReadoutCard(label: 'Distance', value: _distanceText),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ReadoutCard(label: 'Azimuth', value: _azimuthText),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ReadoutCard(label: 'Elevation', value: _elevationText),
              ),
            ],
          ),
          const SizedBox(height: 18),
          FilledButton(
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
                : (_activeRangingId != null ? _stopRanging : _toggleScan),
            child: Text(
              _activeRangingId != null
                  ? 'Stop Ranging'
                  : (_scanning ? 'Stop Discovery' : 'Start Ranging'),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          if (_devicesById.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text('Discovered peers'.toUpperCase(), style: readoutLabelStyle()),
            const SizedBox(height: 8),
            for (final d in _devicesById.values)
              _PeerTile(
                device: d,
                isActive: _activeRangingId == d.id,
                busyElsewhere:
                    _activeRangingId != null && _activeRangingId != d.id,
                onPair: () => _pairAndRange(d),
              ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(_error!, style: TextStyle(color: Colors.redAccent.shade100)),
          ],
        ],
      ),
    );
  }

  Widget _buildSettingsTab(BuildContext context) {
    final caps = _capabilities;
    final canCamera = caps?.supportsCameraAssist ?? false;
    final canExtended = caps?.supportsExtendedDistance ?? false;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('UWB · SETTINGS', style: eyebrowStyle()),
          const SizedBox(height: 18),
          _SettingsSection(
            title: 'Hardware',
            children: [
              _StatusRow(
                label: 'UWB available',
                ok: _uwbAvailable == true,
                value: _uwbAvailable == null
                    ? 'checking…'
                    : (_uwbAvailable! ? 'yes' : 'no'),
              ),
              _StatusRow(
                label: 'Direction (AoA)',
                ok: caps?.supportsDirection ?? false,
                value: (caps?.supportsDirection ?? false) ? 'yes' : 'no',
              ),
              _StatusRow(
                label: 'Camera assist',
                ok: canCamera,
                value: canCamera ? 'supported' : 'unsupported',
              ),
              _StatusRow(
                label: 'Extended distance',
                ok: canExtended,
                value: canExtended ? 'supported' : 'unsupported',
              ),
              _StatusRow(
                label: 'Precise distance',
                ok: caps?.supportsPreciseDistance ?? false,
                value: (caps?.supportsPreciseDistance ?? false) ? 'yes' : 'no',
              ),
              _StatusRow(
                label: 'Raw AoA',
                ok: caps?.supportsAoa ?? false,
                value: (caps?.supportsAoa ?? false) ? 'yes' : 'no',
              ),
            ],
          ),
          const SizedBox(height: 16),
          _SettingsSection(
            title: 'Ranging options',
            subtitle:
                'Applied to every ranging session — both peers and '
                'accessories. Defaults on when the hardware supports it.',
            children: [
              _ToggleRow(
                label: 'Camera assist',
                value: _cameraAssist,
                enabled: canCamera && _activeRangingId == null,
                onChanged: _setCameraAssist,
                hint: canCamera
                    ? 'Enables azimuth + elevation via the U2 chip.'
                    : 'Not supported on this device.',
              ),
              _ToggleRow(
                label: 'Extended distance',
                value: _extendedDistance,
                enabled: canExtended && _activeRangingId == null,
                onChanged: _setExtendedDistance,
                hint: canExtended
                    ? 'Trades update rate for longer range.'
                    : 'Not supported on this device.',
              ),
            ],
          ),
          const SizedBox(height: 16),
          _SettingsSection(
            title: 'Accessory profiles',
            subtitle: 'BLE service triplets the host scans for.',
            children: [
              _InfoRow(
                label: _QorvoProfile.vendorTag,
                value: _QorvoProfile.serviceUuid,
              ),
            ],
          ),
          const SizedBox(height: 16),
          _SettingsSection(
            title: 'Custom adapter (sample)',
            subtitle:
                'Toggles the DemoTag accessory adapter. Surfaces a synthetic '
                'tile under Discovered peers to exercise the framework '
                'round-trip without real hardware. Android only.',
            children: [
              _ToggleRow(
                label: 'DemoTag adapter',
                value: _demoAdapterEnabled,
                enabled: _activeRangingId == null,
                onChanged: (v) => _setDemoAdapterEnabled(v),
                hint: _demoAdapterEnabled
                    ? 'Registered. Tap the DemoTag tile to start the demo handshake.'
                    : 'Off. Flip on to register the demo adapter.',
              ),
            ],
          ),
        ],
      ),
    );
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
    required this.busyElsewhere,
    required this.onPair,
  });

  final UwbDevice device;
  final bool isActive;
  final bool busyElsewhere;
  final VoidCallback onPair;

  static IconData _iconFor(UwbDevice d, bool isActive) {
    if (isActive) return Icons.radar;
    if (d.platform.startsWith('accessory')) return Icons.sensors;
    if (d.platform == 'ios') return Icons.phone_iphone;
    return Icons.phone_android;
  }

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
              _iconFor(device, isActive),
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
                onPressed: busyElsewhere ? null : onPair,
                style: TextButton.styleFrom(
                  foregroundColor: busyElsewhere ? Brand.muted : Brand.primary,
                ),
                child: const Text('Pair & range'),
              ),
          ],
        ),
      ),
    );
  }
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({
    required this.title,
    required this.children,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
      decoration: BoxDecoration(
        color: const Color(0xFF13182F),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Brand.muted.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title.toUpperCase(), style: readoutLabelStyle()),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(
              subtitle!,
              style: TextStyle(color: Brand.muted, fontSize: 11, height: 1.35),
            ),
          ],
          const SizedBox(height: 8),
          for (final c in children) c,
        ],
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({
    required this.label,
    required this.ok,
    required this.value,
  });

  final String label;
  final bool ok;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(
            ok ? Icons.check_circle_outline : Icons.remove_circle_outline,
            size: 16,
            color: ok ? Brand.primary : Brand.muted,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(color: Brand.text, fontSize: 13),
            ),
          ),
          Text(value, style: TextStyle(color: Brand.muted, fontSize: 12)),
        ],
      ),
    );
  }
}

class _ToggleRow extends StatelessWidget {
  const _ToggleRow({
    required this.label,
    required this.value,
    required this.enabled,
    required this.onChanged,
    this.hint,
  });

  final String label;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: enabled ? Brand.text : Brand.muted,
                    fontSize: 13,
                  ),
                ),
                if (hint != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      hint!,
                      style: TextStyle(
                        color: Brand.muted,
                        fontSize: 11,
                        height: 1.3,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: enabled ? onChanged : null,
            activeThumbColor: Brand.primary,
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: Brand.text, fontSize: 13)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(
                color: Brand.muted,
                fontSize: 11,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
