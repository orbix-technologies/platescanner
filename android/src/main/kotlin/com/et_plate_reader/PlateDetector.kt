package com.et_plate_reader

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.util.Log
import org.tensorflow.lite.Interpreter
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.channels.FileChannel

/**
 * Finds whole licence plates in a frame with the on-device YOLO model
 * (`assets/plate_detector.tflite`, trained in `training/`).
 *
 * The model takes a 640×640 RGB image (letterboxed, 0–1 floats), channels
 * first `[1, 3, H, W]` (LiteRT export of PyTorch) or last `[1, H, W, 3]`,
 * and returns `[1, 5, N]` candidates: centre x, centre y, width, height
 * (normalized to the input, or in input pixels on older exports) and a
 * plate score. Boxes come back in the bitmap's pixels after NMS.
 *
 * Absent model → [create] returns null and the scanner keeps working on
 * OCR text boxes alone.
 */
class PlateDetector private constructor(private val interpreter: Interpreter) {

    data class Plate(val box: RectF, val score: Float)

    private val inShape = interpreter.getInputTensor(0).shape()
    private val channelsFirst = inShape[1] == 3
    private val size = if (channelsFirst) inShape[2] else inShape[1]
    private val input = ByteBuffer.allocateDirect(4 * size * size * 3).order(ByteOrder.nativeOrder())
    private val outShape = interpreter.getOutputTensor(0).shape() // [1, 5, N]
    private val output = Array(1) { Array(outShape[1]) { FloatArray(outShape[2]) } }
    private val pixels = IntArray(size * size)
    private val canvasBitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
    private val canvas = Canvas(canvasBitmap)
    private val paint = Paint(Paint.FILTER_BITMAP_FLAG)

    /** Plates in [bitmap] (pixel coordinates), best first. Not thread-safe. */
    @Synchronized
    fun detect(bitmap: Bitmap, minScore: Float = MIN_SCORE): List<Plate> {
        val started = System.currentTimeMillis()
        val scale = size.toFloat() / maxOf(bitmap.width, bitmap.height)
        val w = bitmap.width * scale
        val h = bitmap.height * scale
        val left = (size - w) / 2f
        val top = (size - h) / 2f
        canvas.drawColor(Color.rgb(114, 114, 114))
        canvas.drawBitmap(bitmap, null, RectF(left, top, left + w, top + h), paint)
        canvasBitmap.getPixels(pixels, 0, size, 0, 0, size, size)
        input.rewind()
        if (channelsFirst) {
            val floats = input.asFloatBuffer()
            val plane = size * size
            for (i in pixels.indices) {
                val p = pixels[i]
                floats.put(i, ((p shr 16) and 0xFF) / 255f)
                floats.put(plane + i, ((p shr 8) and 0xFF) / 255f)
                floats.put(2 * plane + i, (p and 0xFF) / 255f)
            }
        } else {
            for (p in pixels) {
                input.putFloat(((p shr 16) and 0xFF) / 255f)
                input.putFloat(((p shr 8) and 0xFF) / 255f)
                input.putFloat((p and 0xFF) / 255f)
            }
        }
        input.rewind()
        interpreter.run(input, output)

        val rows = output[0]
        // Normalized coordinates never exceed ~1; input pixels do.
        var maxCoord = 0f
        for (r in 0 until 4) for (v in rows[r]) if (v > maxCoord) maxCoord = v
        val unit = if (maxCoord <= 2f) size.toFloat() else 1f
        val candidates = ArrayList<Plate>()
        for (i in 0 until outShape[2]) {
            val score = rows[4][i]
            if (score < minScore) continue
            val cx = rows[0][i] * unit
            val cy = rows[1][i] * unit
            val bw = rows[2][i] * unit
            val bh = rows[3][i] * unit
            val box = RectF(
                ((cx - bw / 2 - left) / scale).coerceIn(0f, bitmap.width.toFloat()),
                ((cy - bh / 2 - top) / scale).coerceIn(0f, bitmap.height.toFloat()),
                ((cx + bw / 2 - left) / scale).coerceIn(0f, bitmap.width.toFloat()),
                ((cy + bh / 2 - top) / scale).coerceIn(0f, bitmap.height.toFloat()),
            )
            if (box.width() > 1f && box.height() > 1f) candidates.add(Plate(box, score))
        }
        val plates = nms(candidates)
        if (Log.isLoggable(TAG, Log.DEBUG) || plates.isNotEmpty()) {
            Log.d(TAG, "Plate detector: ${plates.size} plate(s) in ${System.currentTimeMillis() - started} ms, best ${plates.firstOrNull()?.score}")
        }
        return plates
    }

    /** Plates as channel maps, normalized to [crop] (the visible preview). */
    fun detectNormalized(bitmap: Bitmap, crop: Rect): List<Map<String, Double>> =
        detect(bitmap).map { p ->
            mapOf(
                "left" to ((p.box.left - crop.left) / crop.width()).toDouble(),
                "top" to ((p.box.top - crop.top) / crop.height()).toDouble(),
                "right" to ((p.box.right - crop.left) / crop.width()).toDouble(),
                "bottom" to ((p.box.bottom - crop.top) / crop.height()).toDouble(),
                "score" to p.score.toDouble(),
            )
        }

    fun close() = interpreter.close()

    companion object {
        private const val TAG = "EtPlateReader"
        private const val ASSET = "plate_detector.tflite"
        const val MIN_SCORE = 0.35f
        private const val NMS_IOU = 0.5f

        fun create(context: Context): PlateDetector? = try {
            val model = load(context)
            PlateDetector(Interpreter(model, Interpreter.Options().setNumThreads(4))).also {
                Log.i(TAG, "Plate detector loaded: input ${it.inShape.contentToString()}")
            }
        } catch (e: Exception) {
            Log.i(TAG, "No plate detector model, using OCR boxes only: ${e.message}")
            null
        }

        private fun load(context: Context): ByteBuffer = try {
            // Memory-mapped when the APK stores the model uncompressed (AGP default for .tflite).
            context.assets.openFd(ASSET).use { fd ->
                FileInputStream(fd.fileDescriptor).channel.use { ch ->
                    ch.map(FileChannel.MapMode.READ_ONLY, fd.startOffset, fd.declaredLength)
                }
            }
        } catch (e: java.io.FileNotFoundException) {
            // Compressed by the host app's packaging options: read it into memory.
            val bytes = context.assets.open(ASSET).use { it.readBytes() }
            ByteBuffer.allocateDirect(bytes.size).order(ByteOrder.nativeOrder()).put(bytes).also { it.rewind() }
        }

        private fun nms(plates: List<Plate>): List<Plate> {
            val kept = ArrayList<Plate>()
            for (p in plates.sortedByDescending { it.score }) {
                if (kept.none { iou(it.box, p.box) > NMS_IOU }) kept.add(p)
            }
            return kept
        }

        private fun iou(a: RectF, b: RectF): Float {
            val iw = minOf(a.right, b.right) - maxOf(a.left, b.left)
            val ih = minOf(a.bottom, b.bottom) - maxOf(a.top, b.top)
            if (iw <= 0f || ih <= 0f) return 0f
            val inter = iw * ih
            return inter / (a.width() * a.height() + b.width() * b.height() - inter)
        }
    }
}
