package com.et_plate_reader

import android.content.Context
import android.graphics.Rect
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.util.Size
import android.view.View
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
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
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView
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
    private var disposed = false

    override val lifecycle: Lifecycle get() = lifecycleRegistry

    init {
        channel.setMethodCallHandler(this)
        lifecycleRegistry.currentState = Lifecycle.State.RESUMED
        // Bind once laid out so previewView.viewPort is available.
        previewView.post { bindCamera() }
    }

    override fun getView(): View = previewView

    private fun bindCamera() {
        if (disposed) return
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

                val group = UseCaseGroup.Builder().addUseCase(preview).addUseCase(analysis)
                // Same viewport as the preview → ImageProxy.cropRect = visible area.
                previewView.viewPort?.let { group.setViewPort(it) }

                cameraProvider.unbindAll()
                camera = cameraProvider.bindToLifecycle(
                    this,
                    CameraSelector.DEFAULT_BACK_CAMERA,
                    group.build(),
                )
                channel.invokeMethod("onReady", null)
            } catch (e: Exception) {
                Log.e(TAG, "Camera bind failed", e)
                sendError("Camera could not be opened: ${e.message}")
            }
        }, ContextCompat.getMainExecutor(context))
    }

    @androidx.annotation.OptIn(androidx.camera.core.ExperimentalGetImage::class)
    private fun analyze(proxy: ImageProxy) {
        val media = proxy.image
        if (!analyzing.get() || disposed || media == null) {
            proxy.close()
            return
        }
        val rotation = proxy.imageInfo.rotationDegrees
        val crop = uprightRect(proxy.cropRect, proxy.width, proxy.height, rotation)
        val input = InputImage.fromMediaImage(media, rotation)
        recognizer.process(input)
            .addOnSuccessListener { text ->
                if (!analyzing.get() || disposed) return@addOnSuccessListener
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
            }
            .addOnFailureListener { e -> Log.w(TAG, "OCR failed", e) }
            .addOnCompleteListener { proxy.close() }
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
