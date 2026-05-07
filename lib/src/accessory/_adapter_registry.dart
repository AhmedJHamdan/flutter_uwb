import '../pigeon/uwb.g.dart' as pigeon;
import 'accessory_adapter.dart';

/// Maps `vendorTag → AccessoryAdapter` and pushes the current tag set
/// to native via [pigeon.UwbHostApi.setRegisteredAdapterTags].
///
/// Package-private — owned by `FlutterUwb`. Built-in adapters are
/// registered at construction; user-supplied adapters override built-ins
/// with the same `vendorTag`.
class AdapterRegistry {
  AdapterRegistry({required pigeon.UwbHostApi api}) : _api = api;

  final pigeon.UwbHostApi _api;
  final Map<String, AccessoryAdapter> _adapters = {};

  /// Register or replace the adapter for `adapter.vendorTag`. A custom
  /// adapter with the same tag as a built-in shadows the built-in.
  void register(AccessoryAdapter adapter) {
    _adapters[adapter.vendorTag] = adapter;
    _push();
  }

  /// Remove the adapter previously registered for [vendorTag]. No-op
  /// if no adapter is registered. Note: removing a built-in adapter
  /// disables it for the current `FlutterUwb` instance.
  void unregister(String vendorTag) {
    if (_adapters.remove(vendorTag) != null) _push();
  }

  /// Look up the adapter for [vendorTag], or `null` if none is
  /// registered.
  AccessoryAdapter? lookup(String vendorTag) => _adapters[vendorTag];

  /// Snapshot of currently registered tags.
  List<String> tags() => _adapters.keys.toList(growable: false);

  /// Test seam — bypasses the Pigeon round-trip used by [register].
  void registerWithoutPush(AccessoryAdapter adapter) {
    _adapters[adapter.vendorTag] = adapter;
  }

  void _push() {
    // Best-effort fire-and-forget. The native dispatcher uses the
    // current set as a routing hint; an in-flight refresh racing with
    // a `startRanging` is harmless because the Dart-side lookup at
    // `connected`-event time is what actually selects the adapter.
    _api.setRegisteredAdapterTags(tags());
  }
}
