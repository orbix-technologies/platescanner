package com.et_plate_reader

import android.content.Context
import android.content.pm.PackageManager
import android.hardware.camera2.CameraManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
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
    companion object {
        /** Crops are scaled up to about this many pixels tall before OCR. */
        private const val AREA_TARGET_HEIGHT = 480f
    }

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
            "recognizeArea" -> recognizeArea(call, result)
            "readCrops" -> readCrops(call, result)
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

    /**
     * Step 3: every character inside a normalized area of a still. The crop
     * is upscaled (plate text small in the frame reads poorly) and padded
     * with white; boxes come back normalized to the area.
     */
    private fun recognizeArea(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        val left = call.argument<Double>("left")
        val top = call.argument<Double>("top")
        val right = call.argument<Double>("right")
        val bottom = call.argument<Double>("bottom")
        if (path == null || left == null || top == null || right == null || bottom == null) {
            result.error("bad_args", "path and area are required", null)
            return
        }
        val main = Handler(Looper.getMainLooper())
        Thread {
            val recognizer = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
            try {
                val image = BitmapFactory.decodeFile(path)
                    ?: throw IllegalArgumentException("Unsupported image")
                val src = Rect(
                    (left * image.width).toInt().coerceIn(0, image.width - 1),
                    (top * image.height).toInt().coerceIn(0, image.height - 1),
                    (right * image.width).toInt().coerceIn(1, image.width),
                    (bottom * image.height).toInt().coerceIn(1, image.height),
                )
                val scale = (AREA_TARGET_HEIGHT / src.height()).coerceIn(1f, 4f)
                val w = (src.width() * scale).toInt()
                val h = (src.height() * scale).toInt()
                val pad = (h * 0.15f).toInt()
                val page = Bitmap.createBitmap(w + 2 * pad, h + 2 * pad, Bitmap.Config.ARGB_8888)
                Canvas(page).apply {
                    drawColor(Color.WHITE)
                    drawBitmap(image, src, Rect(pad, pad, pad + w, pad + h), Paint(Paint.FILTER_BITMAP_FLAG))
                }

                val text = Tasks.await(recognizer.process(InputImage.fromBitmap(page, 0)))
                fun norm(b: Rect): Map<String, Double> = mapOf(
                    "left" to (b.left - pad).toDouble() / w,
                    "top" to (b.top - pad).toDouble() / h,
                    "right" to (b.right - pad).toDouble() / w,
                    "bottom" to (b.bottom - pad).toDouble() / h,
                )
                val elements = ArrayList<Map<String, Any>>()
                for (block in text.textBlocks) for (line in block.lines) for (el in line.elements) {
                    val box = el.boundingBox ?: continue
                    val symbols = el.symbols.mapNotNull { sym ->
                        val sb = sym.boundingBox ?: return@mapNotNull null
                        norm(sb) + mapOf("text" to sym.text)
                    }
                    elements.add(
                        norm(box) + mapOf(
                            "text" to el.text,
                            "confidence" to el.confidence.toDouble(),
                            "symbols" to symbols,
                        ),
                    )
                }
                val payload = HashMap<String, Any>()
                payload["elements"] = elements
                // What each section pass tried and read, for the session log.
                val log = ArrayList<String>()
                log.add("area: src=${src.toShortString()} image=${image.width}x${image.height} scale=$scale page=${page.width}x${page.height} pad=$pad")
                CodeDiscReader.read(recognizer, text, log) { page }?.let {
                    payload["codeHint"] = it
                    payload["codeVotes"] = CodeDiscReader.lastVotes
                }
                payload["regionColumns"] = RegionStackReader.read(recognizer, text, page, log).map { col ->
                    norm(col.box) + mapOf(
                        "letters" to col.letters,
                        "source" to col.source,
                        "topHalf" to norm(col.top),
                        "bottomHalf" to norm(col.bottom),
                    )
                }
                // Section 1 fallback: the number's ink colour gives the code.
                CropOcr.numberAnchor(text)?.let { a ->
                    val numberBox = Rect(a.first.left, a.top, a.last.right, a.bottom)
                    CropOcr.inkColor(page, numberBox)?.let { rgb ->
                        payload["inkColor"] = rgb.toList()
                        log.add("ink: number=${numberBox.toShortString()} rgb=${rgb.toList()}")
                    }
                    CropOcr.paperColor(page, numberBox)?.let { rgb ->
                        payload["paperColor"] = rgb.toList()
                        log.add("paper: rgb=${rgb.toList()}")
                    }
                }
                payload["debug"] = log
                main.post { result.success(payload) }
            } catch (e: Exception) {
                main.post { result.error("ocr_failed", e.message, null) }
            } finally {
                recognizer.close()
            }
        }.start()
    }

    /**
     * Reads each crop of a still alone, as photographed, in black and white
     * and with border lines erased: returns one [colour, bw, clean] text
     * triple per crop. Crops are normalized `{left, top, right, bottom}` of
     * the image; each is scaled to `size` px tall (default 160).
     */
    private fun readCrops(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        val crops = call.argument<List<Map<String, Double>>>("crops")
        val size = (call.argument<Double>("size") ?: 160.0).toFloat()
        if (path == null || crops == null) {
            result.error("bad_args", "path and crops are required", null)
            return
        }
        val main = Handler(Looper.getMainLooper())
        Thread {
            val recognizer = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
            try {
                val image = BitmapFactory.decodeFile(path)
                    ?: throw IllegalArgumentException("Unsupported image")
                val reads = crops.map { c ->
                    val area = RectF(
                        (c["left"]!! * image.width).toFloat(),
                        (c["top"]!! * image.height).toFloat(),
                        (c["right"]!! * image.width).toFloat(),
                        (c["bottom"]!! * image.height).toFloat(),
                    )
                    CropOcr.Mode.values().map { mode -> CropOcr.read(recognizer, image, area, size, mode) }
                }
                main.post { result.success(reads) }
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
