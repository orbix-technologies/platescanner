package com.et_plate_reader

import android.content.Context
import android.content.pm.PackageManager
import android.hardware.camera2.CameraManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Registers the availability channel and the `et_plate_reader/scanner` view. */
class EtPlateReaderPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var availabilityChannel: MethodChannel
    private lateinit var context: Context

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        availabilityChannel = MethodChannel(binding.binaryMessenger, "et_plate_reader/availability")
        availabilityChannel.setMethodCallHandler(this)
        binding.platformViewRegistry.registerViewFactory(
            PlateScannerViewFactory.VIEW_TYPE,
            PlateScannerViewFactory(binding.binaryMessenger),
        )
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "checkAvailability" -> result.success(mapOf("status" to availability()))
            else -> result.notImplemented()
        }
    }

    // Camera-free: no camera is opened. ML Kit's Latin model is bundled in
    // the APK, so a present camera is enough.
    private fun availability(): String {
        val pm = context.packageManager
        if (!pm.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY)) return "noCamera"
        return try {
            val manager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
            if (manager.cameraIdList.isEmpty()) "noCamera" else "supported"
        } catch (e: Exception) {
            "unknown"
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        availabilityChannel.setMethodCallHandler(null)
    }
}
