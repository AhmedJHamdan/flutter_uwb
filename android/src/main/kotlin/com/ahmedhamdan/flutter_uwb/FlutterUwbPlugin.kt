package com.ahmedhamdan.flutter_uwb

import io.flutter.embedding.engine.plugins.FlutterPlugin

class FlutterUwbPlugin : FlutterPlugin {
    private var impl: UwbHostApiImpl? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val instance = UwbHostApiImpl(binding.applicationContext, binding.binaryMessenger)
        impl = instance
        UwbHostApi.setUp(binding.binaryMessenger, instance)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        UwbHostApi.setUp(binding.binaryMessenger, null)
        impl?.dispose()
        impl = null
    }
}
