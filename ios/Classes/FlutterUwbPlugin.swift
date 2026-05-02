import Flutter
import UIKit

public class FlutterUwbPlugin: NSObject, FlutterPlugin {
  private var impl: UwbHostApiImpl?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let messenger = registrar.messenger()
    let plugin = FlutterUwbPlugin()
    let impl = UwbHostApiImpl(messenger: messenger)
    plugin.impl = impl
    UwbHostApiSetup.setUp(binaryMessenger: messenger, api: impl)
    // Keep the plugin alive for the lifetime of the engine.
    registrar.publish(plugin)
  }
}
