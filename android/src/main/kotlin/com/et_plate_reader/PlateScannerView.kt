package com.et_plate_reader

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Matrix
import android.graphics.Rect
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.util.Size
import android.view.View
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.UseCaseGroup
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * CameraX preview + ML Kit Latin OCR.
 *
 * Analysis runs keep-latest on a background thread; only recognised lines,
 * normalized to the visible preview area, cross the channel.
 */
class PlateScannerView(
    private val context: Context,
    messenger: BinaryMessenger,
    viewId: Int,
) : PlatformView, LifecycleOwner, MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, "${PlateScannerViewFactory.VIEW_TYPE}_$viewId")
    private val main = Handler(Looper.getMainLooper())
    private val lifecycleRegistry = LifecycleRegistry(this)
    private val analysisExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private val recognizer = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
    private val analyzing = AtomicBoolean(false)
    private val previewView = PreviewView(context).apply {
        // TextureView so the preview composes under Flutter widgets.
        implementationMode = PreviewView.ImplementationMode.COMPATIBLE
        scaleType = PreviewView.ScaleType.FILL_CENTER
    }
    private var provider: ProcessCameraProvider? = null
    private var camera: Camera? = null
    private var imageCapture: ImageCapture? = null
    private var disposed = false
    @Volatile private var pendingCapture: MethodChannel.Result? = null

    override val lifecycle: Lifecycle get() = lifecycleRegistry

    init {
        channel.setMethodCallHandler(this)
        lifecycleRegistry.currentState = Lifecycle.State.RESUMED
        // Bind once laid out so previewView.viewPort is available.
        previewView.post { bindCamera() }
    }

    override fun getView(): View = previewView

    private fun bindCamera(attempt: Int = 0) {
        if (disposed) return
        // Coordinates sent to Dart are relative to the visible preview only
        // when the analysis shares the preview's ViewPort, which exists once
        // the view is laid out. Wait for it (up to ~1 s) before binding.
        if (previewView.viewPort == null && attempt < 20) {
            previewView.postDelayed({ bindCamera(attempt + 1) }, 50)
            return
        }
        val future = ProcessCameraProvider.getInstance(context)
        future.addListener({
            if (disposed) return@addListener
            try {
                val cameraProvider = future.get()
                provider = cameraProvider

                val preview = Preview.Builder().build().also {
                    it.setSurfaceProvider(previewView.surfaceProvider)
                }
                val analysis = ImageAnalysis.Builder()
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                    .setResolutionSelector(
                        ResolutionSelector.Builder()
                            .setResolutionStrategy(
                                ResolutionStrategy(
                                    Size(1280, 720),
                                    ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER,
                                ),
                            )
                            .build(),
                    )
                    .build()
                analysis.setAnalyzer(analysisExecutor, ::analyze)

                // Stills for area confirmation and reading: far more pixels on
                // the plate than the 720p analysis stream.
                val capture = ImageCapture.Builder()
                    .setCaptureMode(ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY)
                    .setResolutionSelector(
                        ResolutionSelector.Builder()
                            .setResolutionStrategy(
                                ResolutionStrategy(
                                    Size(2560, 1440),
                                    ResolutionStrategy.FALLBACK_RULE_CLOSEST_LOWER_THEN_HIGHER,
                                ),
                            )
                            .build(),
                    )
                    .build()

                fun group(withCapture: Boolean): UseCaseGroup {
                    val g = UseCaseGroup.Builder().addUseCase(preview).addUseCase(analysis)
                    if (withCapture) g.addUseCase(capture)
                    // Same viewport as the preview → every cropRect = visible area.
                    previewView.viewPort?.let { g.setViewPort(it) }
                    return g.build()
                }

                cameraProvider.unbindAll()
                camera = try {
                    cameraProvider.bindToLifecycle(this, CameraSelector.DEFAULT_BACK_CAMERA, group(true))
                        .also { imageCapture = capture }
                } catch (e: Exception) {
                    // Device can't run three streams: stills come from analysis.
                    Log.w(TAG, "ImageCapture unavailable, using analysis frames", e)
                    cameraProvider.unbindAll()
                    imageCapture = null
                    cameraProvider.bindToLifecycle(this, CameraSelector.DEFAULT_BACK_CAMERA, group(false))
                }
                channel.invokeMethod("onReady", null)
            } catch (e: Exception) {
                Log.e(TAG, "Camera bind failed", e)
                sendError("Camera could not be opened: ${e.message}")
            }
        }, ContextCompat.getMainExecutor(context))
    }

    // Runs on analysisExecutor, so blocking on ML Kit is fine here.
    @androidx.annotation.OptIn(androidx.camera.core.ExperimentalGetImage::class)
    private fun analyze(proxy: ImageProxy) {
        try {
            val rotation = proxy.imageInfo.rotationDegrees
            val crop = uprightRect(proxy.cropRect, proxy.width, proxy.height, rotation)
            pendingCapture?.let { result ->
                pendingCapture = null
                capture(proxy, rotation, crop, result)
            }
            val media = proxy.image
            if (!analyzing.get() || disposed || media == null) return
            val text = Tasks.await(recognizer.process(InputImage.fromMediaImage(media, rotation)))
            if (!analyzing.get() || disposed) return

            val lines = ArrayList<Map<String, Any>>()
            for (block in text.textBlocks) {
                for (line in block.lines) {
                    val box = line.boundingBox ?: continue
                    lines.add(
                        mapOf(
                            "text" to line.text,
                            "confidence" to line.confidence.toDouble(),
                            "left" to (box.left - crop.left).toDouble() / crop.width(),
                            "top" to (box.top - crop.top).toDouble() / crop.height(),
                            "right" to (box.right - crop.left).toDouble() / crop.width(),
                            "bottom" to (box.bottom - crop.top).toDouble() / crop.height(),
                        ),
                    )
                }
            }
            main.post {
                if (!disposed) channel.invokeMethod("onFrame", mapOf("lines" to lines))
            }
        } catch (e: Exception) {
            Log.w(TAG, "OCR failed", e)
        } finally {
            proxy.close()
        }
    }

    /** High-resolution still; falls back to the next analysis frame on error. */
    private fun takeStill(still: ImageCapture, result: MethodChannel.Result) {
        still.takePicture(
            analysisExecutor,
            object : ImageCapture.OnImageCapturedCallback() {
                override fun onCaptureSuccess(image: ImageProxy) {
                    try {
                        val rotation = image.imageInfo.rotationDegrees
                        val crop = uprightRect(image.cropRect, image.width, image.height, rotation)
                        capture(image, rotation, crop, result)
                    } finally {
                        image.close()
                    }
                }

                override fun onError(exception: ImageCaptureException) {
                    Log.w(TAG, "Still capture failed, using analysis frame", exception)
                    pendingCapture = result
                }
            },
        )
    }

    /** Saves this frame, cropped to the visible preview, as a JPEG still. */
    private fun capture(proxy: ImageProxy, rotation: Int, crop: Rect, result: MethodChannel.Result) {
        try {
            val upright = uprightBitmap(proxy, rotation)
            val r = Rect(crop).apply { intersect(0, 0, upright.width, upright.height) }
            val visible = Bitmap.createBitmap(upright, r.left, r.top, r.width(), r.height())
            val file = File(context.cacheDir, "et_plate_${System.currentTimeMillis()}.jpg")
            FileOutputStream(file).use { visible.compress(Bitmap.CompressFormat.JPEG, 92, it) }
            val payload = mapOf("path" to file.absolutePath, "width" to visible.width, "height" to visible.height)
            main.post { result.success(payload) }
        } catch (e: Exception) {
            main.post { result.error("capture_failed", e.message, null) }
        }
    }

    private fun uprightBitmap(proxy: ImageProxy, rotation: Int): Bitmap {
        val raw = proxy.toBitmap()
        if (rotation == 0) return raw
        val m = Matrix().apply { postRotate(rotation.toFloat()) }
        return Bitmap.createBitmap(raw, 0, 0, raw.width, raw.height, m, true)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                analyzing.set(true)
                result.success(null)
            }
            "pause" -> {
                analyzing.set(false)
                result.success(null)
            }
            "captureFrame" -> {
                val still = imageCapture
                when {
                    camera == null -> result.error("not_ready", "Camera is not ready", null)
                    pendingCapture != null -> result.error("busy", "Capture already in progress", null)
                    still != null -> takeStill(still, result)
                    else -> pendingCapture = result
                }
            }
            "setTorch" -> {
                val on = call.argument<Boolean>("on") ?: false
                val cam = camera
                if (cam == null || !cam.cameraInfo.hasFlashUnit()) {
                    result.success(false)
                } else {
                    cam.cameraControl.enableTorch(on)
                    result.success(on)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun sendError(message: String) {
        main.post {
            if (!disposed) channel.invokeMethod("onError", mapOf("message" to message))
        }
    }

    override fun dispose() {
        if (disposed) return
        disposed = true
        analyzing.set(false)
        channel.setMethodCallHandler(null)
        lifecycleRegistry.currentState = Lifecycle.State.DESTROYED
        provider?.unbindAll()
        recognizer.close()
        analysisExecutor.shutdown()
    }

    companion object {
        private const val TAG = "EtPlateReader"

        /** Rotates a buffer-space [rect] into the upright frame ML Kit reports in. */
        fun uprightRect(rect: Rect, width: Int, height: Int, rotation: Int): Rect = when (rotation) {
            90 -> Rect(height - rect.bottom, rect.left, height - rect.top, rect.right)
            180 -> Rect(width - rect.right, height - rect.bottom, width - rect.left, height - rect.top)
            270 -> Rect(rect.top, width - rect.right, rect.bottom, width - rect.left)
            else -> Rect(rect)
        }
    }
}
