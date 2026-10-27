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
import java.util.concurrent.atomic.AtomicInteger

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
    /** Patrol: plates passing by. Larger frames, steady short exposure. */
    private val patrol: Boolean = false,
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

    // Patrol: the last few analysed frames that read a number, by frame id,
    // so a vehicle's picture is the very frame its number was read from.
    private val frameIds = AtomicInteger(0)
    private val keptFrames = LinkedHashMap<Int, Bitmap>()
    private val saveExecutor: ExecutorService = Executors.newSingleThreadExecutor()

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

                val previewBuilder = Preview.Builder()
                val analysisBuilder = ImageAnalysis.Builder()
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                    .setResolutionSelector(
                        ResolutionSelector.Builder()
                            .setResolutionStrategy(
                                ResolutionStrategy(
                                    // Patrol: plates further away and smaller.
                                    if (patrol) Size(1920, 1080) else Size(1280, 720),
                                    ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER,
                                ),
                            )
                            .build(),
                    )
                if (patrol) {
                    // A steady 30 fps keeps each exposure at or under ~33 ms,
                    // so plates passing by blur less than with the default
                    // auto exposure (which lengthens it in low light).
                    val fps = android.util.Range(30, 30)
                    androidx.camera.camera2.interop.Camera2Interop.Extender(previewBuilder)
                        .setCaptureRequestOption(
                            android.hardware.camera2.CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, fps,
                        )
                    androidx.camera.camera2.interop.Camera2Interop.Extender(analysisBuilder)
                        .setCaptureRequestOption(
                            android.hardware.camera2.CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, fps,
                        )
                }
                val preview = previewBuilder.build().also {
                    it.setSurfaceProvider(previewView.surfaceProvider)
                }
                val analysis = analysisBuilder.build()
                analysis.setAnalyzer(analysisExecutor, ::analyze)

                // Stills for area confirmation and reading: far more pixels on
                // the plate than the 720p analysis stream.
                val capture = ImageCapture.Builder()
                    .setCaptureMode(ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY)
                    .setResolutionSelector(
                        if (patrol) {
                            // Patrol: plates are small in view, so the most
                            // pixels the sensor gives in its own 4:3 shape,
                            // up to ~8 MP (decoding larger is slow). Many
                            // phones have no 16:9 size between 1080p and the
                            // sensor's, so 2560×1440 fell back to 1080p.
                            ResolutionSelector.Builder()
                                .setAspectRatioStrategy(
                                    androidx.camera.core.resolutionselector.AspectRatioStrategy
                                        .RATIO_4_3_FALLBACK_AUTO_STRATEGY,
                                )
                                .setResolutionStrategy(
                                    ResolutionStrategy(
                                        Size(3264, 2448),
                                        ResolutionStrategy.FALLBACK_RULE_CLOSEST_LOWER_THEN_HIGHER,
                                    ),
                                )
                                .build()
                        } else {
                            ResolutionSelector.Builder()
                                .setResolutionStrategy(
                                    ResolutionStrategy(
                                        Size(2560, 1440),
                                        ResolutionStrategy.FALLBACK_RULE_CLOSEST_LOWER_THEN_HIGHER,
                                    ),
                                )
                                .build()
                        },
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
                    // Patrol too: full-resolution stills of the closest view
                    // of each vehicle, for reading its code and region.
                    cameraProvider.bindToLifecycle(this, CameraSelector.DEFAULT_BACK_CAMERA, group(true))
                        .also { imageCapture = capture }
                } catch (e: Exception) {
                    // Device can't run three streams: stills come from analysis.
                    Log.w(TAG, "ImageCapture unavailable, using analysis frames", e)
                    cameraProvider.unbindAll()
                    imageCapture = null
                    cameraProvider.bindToLifecycle(this, CameraSelector.DEFAULT_BACK_CAMERA, group(false))
                }
                Log.i(
                    TAG,
                    "bound patrol=$patrol analysis=${analysis.resolutionInfo?.resolution} " +
                        "still=${imageCapture?.resolutionInfo?.resolution}",
                )
                if (patrol) {
                    // Plates of cars passed a few metres away fill a tenth of
                    // the frame: zoom in so their code and region letters
                    // have enough pixels (patrol logs).
                    camera?.let { cam ->
                        val max = cam.cameraInfo.zoomState.value?.maxZoomRatio ?: 1f
                        cam.cameraControl.setZoomRatio(minOf(PATROL_ZOOM, max))
                    }
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

            val id = frameIds.incrementAndGet()
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
            if (patrol && text.textBlocks.any { b -> b.lines.any { l -> l.text.count { it.isDigit() } >= 4 } }) {
                keepFrame(id, visibleBitmap(proxy, rotation, crop))
            }
            main.post {
                if (!disposed) channel.invokeMethod("onFrame", mapOf("lines" to lines, "frameId" to id))
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
            save(visibleBitmap(proxy, rotation, crop), result)
        } catch (e: Exception) {
            main.post { result.error("capture_failed", e.message, null) }
        }
    }

    /** The frame upright, cropped to the visible preview. */
    private fun visibleBitmap(proxy: ImageProxy, rotation: Int, crop: Rect): Bitmap {
        val upright = uprightBitmap(proxy, rotation)
        val r = Rect(crop).apply { intersect(0, 0, upright.width, upright.height) }
        return Bitmap.createBitmap(upright, r.left, r.top, r.width(), r.height())
    }

    /** Writes [bitmap] as a JPEG in the cache and returns its path to Dart. */
    private fun save(bitmap: Bitmap, result: MethodChannel.Result) {
        try {
            val file = File(context.cacheDir, "et_plate_${System.currentTimeMillis()}.jpg")
            FileOutputStream(file).use { bitmap.compress(Bitmap.CompressFormat.JPEG, 92, it) }
            val payload = mapOf("path" to file.absolutePath, "width" to bitmap.width, "height" to bitmap.height)
            main.post { result.success(payload) }
        } catch (e: Exception) {
            main.post { result.error("capture_failed", e.message, null) }
        }
    }

    private fun keepFrame(id: Int, bitmap: Bitmap) = synchronized(keptFrames) {
        keptFrames[id] = bitmap
        while (keptFrames.size > KEPT_FRAMES) keptFrames.remove(keptFrames.keys.first())
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
            // A frame analysed earlier (by its id), as a still: the very
            // frame a vehicle's number was read from.
            "frameImage" -> {
                val id = call.argument<Int>("id") ?: -1
                val bitmap = synchronized(keptFrames) { keptFrames[id] }
                if (bitmap == null) {
                    result.error("gone", "Frame $id is no longer kept", null)
                } else {
                    saveExecutor.execute { save(bitmap, result) }
                }
            }
            // The next analysis frame as a still: instant, for patrol photos.
            "grabFrame" -> when {
                camera == null -> result.error("not_ready", "Camera is not ready", null)
                pendingCapture != null -> result.error("busy", "Capture already in progress", null)
                else -> pendingCapture = result
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
        saveExecutor.shutdown()
        synchronized(keptFrames) { keptFrames.clear() }
    }

    companion object {
        private const val TAG = "EtPlateReader"

        /** Analysed frames kept for [frameImage] (patrol). */
        private const val KEPT_FRAMES = 4

        /** Zoom while patrolling. */
        private const val PATROL_ZOOM = 1.6f

        /** Rotates a buffer-space [rect] into the upright frame ML Kit reports in. */
        fun uprightRect(rect: Rect, width: Int, height: Int, rotation: Int): Rect = when (rotation) {
            90 -> Rect(height - rect.bottom, rect.left, height - rect.top, rect.right)
            180 -> Rect(width - rect.right, height - rect.bottom, width - rect.left, height - rect.top)
            270 -> Rect(rect.top, width - rect.right, rect.bottom, width - rect.left)
            else -> Rect(rect)
        }
    }
}
