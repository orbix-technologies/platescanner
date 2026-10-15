package com.et_plate_reader

import android.content.Context
import android.content.pm.PackageManager
import android.hardware.camera2.CameraManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.net.Uri
import android.os.Handler
import android.os.Looper
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import java.io.File
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
            "recognizeImage" -> recognizeImage(call.argument<String>("path"), result)
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

    // Still-image OCR with the same payload as a camera frame, normalized to
    // the (EXIF-upright) image. Runs off the main thread.
    private fun recognizeImage(path: String?, result: MethodChannel.Result) {
        if (path == null) {
            result.error("bad_args", "path is required", null)
            return
        }
        val main = Handler(Looper.getMainLooper())
        Thread {
            val recognizer = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
            try {
                val image = InputImage.fromFilePath(context, Uri.fromFile(File(path)))
                val text = Tasks.await(recognizer.process(image))
                val decoded = BitmapFactory.decodeFile(path)
                    ?: throw IllegalArgumentException("Unsupported image")
                val bitmap = if (image.rotationDegrees == 0) decoded else Bitmap.createBitmap(
                    decoded, 0, 0, decoded.width, decoded.height,
                    Matrix().apply { postRotate(image.rotationDegrees.toFloat()) }, true,
                )
                val w = bitmap.width.toDouble()
                val h = bitmap.height.toDouble()
                val lines = text.textBlocks.flatMap { it.lines }.mapNotNull { line ->
                    val box = line.boundingBox ?: return@mapNotNull null
                    mapOf(
                        "text" to line.text,
                        "confidence" to line.confidence.toDouble(),
                        "left" to box.left / w,
                        "top" to box.top / h,
                        "right" to box.right / w,
                        "bottom" to box.bottom / h,
                    )
                }
                val payload = HashMap<String, Any>()
                payload["lines"] = lines
                CodeDiscReader.read(recognizer, text) { bitmap }?.let { payload["codeHint"] = it }
                main.post { result.success(payload) }
            } catch (e: Exception) {
                main.post { result.error("ocr_failed", e.message, null) }
            } finally {
                recognizer.close()
            }
        }.start()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        availabilityChannel.setMethodCallHandler(null)
    }
}
