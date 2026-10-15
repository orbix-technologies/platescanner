package com.et_plate_reader

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Rect
import android.graphics.RectF
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.Text
import com.google.mlkit.vision.text.TextRecognizer

/**
 * Second OCR pass for the circled service code on new-format plates.
 *
 * Latin OCR reads the ring as a letter ("D-0123456") and misses the digit.
 * Reading only the inner disc — ring cropped away, padded with white,
 * upscaled — returns the digit. The disc sits at the left end of the line
 * holding the serial; a few candidate centres are tried, in units of that
 * line's height.
 *
 * Must run off the main thread (blocks on ML Kit).
 */
object CodeDiscReader {
    private val serialRun = Regex("\\d{5,}")
    private val visibleCode = Regex("(^|[^0-9])[1-5]([^0-9]|$)|[\\u2460-\\u2464]")

    // Disc centre offsets from the line's left edge, × line height: a fine
    // scan near the edge (OCR may start the line anywhere on the ring), then
    // further left for when the line starts at the serial. Runs once per
    // confirmed area, so the extra OCR calls are cheap.
    private val centreOffsets = floatArrayOf(
        0.1f, 0.2f, 0.0f, 0.3f, -0.1f, 0.4f, -0.2f, -1.45f, -1.1f, -0.8f,
    )

    /**
     * Returns "1".."5", or null. [bitmap] is only called when a pass is
     * needed and must return the upright image matching [text]'s boxes.
     */
    fun read(recognizer: TextRecognizer, text: Text, bitmap: () -> Bitmap): String? {
        val line = text.textBlocks.flatMap { it.lines }
            .filter { serialRun.containsMatchIn(it.text) && it.boundingBox != null }
            .maxByOrNull { it.boundingBox!!.height() } ?: return null
        val box = line.boundingBox!!
        val prefix = line.text.substring(0, serialRun.find(line.text)!!.range.first)
        if (visibleCode.containsMatchIn(prefix)) return null

        val image = bitmap()
        val h = box.height().toFloat()
        val half = h * 0.17f
        for (offset in centreOffsets) {
            val cx = box.left + offset * h
            val cy = box.exactCenterY()
            val crop = RectF(cx - half, cy - half, cx + half, cy + half)
            val digit = readCrop(recognizer, image, crop)
            if (digit == null) continue
            return digit
        }
        return null
    }

    private const val DISC_SIZE = 180f

    // Ring fragments read as brackets / O are dropped; glyphs commonly read
    // for the code digit are mapped.
    private val ringNoise = setOf('(', ')', '[', ']', '{', '}', 'O', 'o', 'C', 'c', '0', '.', ',', '-')
    private val asDigit = mapOf('I' to '1', 'l' to '1', '|' to '1', 'i' to '1', 'Z' to '2', 'z' to '2', 'S' to '5', 's' to '5')

    /** The single code digit in [text], or null. */
    fun digitOf(text: String): String? {
        val chars = text.filter { !it.isWhitespace() && it !in ringNoise }.map { asDigit[it] ?: it }
        if (chars.isEmpty() || chars.any { it != chars[0] } || chars[0] !in '1'..'5') return null
        return chars[0].toString()
    }

    private fun readCrop(recognizer: TextRecognizer, bitmap: Bitmap, area: RectF): String? {
        val src = Rect(
            area.left.toInt().coerceAtLeast(0),
            area.top.toInt().coerceAtLeast(0),
            area.right.toInt().coerceAtMost(bitmap.width),
            area.bottom.toInt().coerceAtMost(bitmap.height),
        )
        if (src.width() < 8 || src.height() < 8) return null
        // Inner disc scaled to ~180 px (a fixed ×3 blurs crops that were
        // already upscaled), centred on a white page 3× larger again.
        val scale = (DISC_SIZE / src.width()).coerceIn(0.5f, 4f)
        val w = (src.width() * scale).toInt()
        val hgt = (src.height() * scale).toInt()
        val page = Bitmap.createBitmap(w * 3, hgt * 3, Bitmap.Config.ARGB_8888)
        Canvas(page).apply {
            drawColor(Color.WHITE)
            drawBitmap(bitmap, src, Rect(w, hgt, w * 2, hgt * 2), null)
        }
        return try {
            val result = Tasks.await(recognizer.process(InputImage.fromBitmap(page, 0)))
            digitOf(result.text)
        } catch (e: Exception) {
            null
        } finally {
            page.recycle()
        }
    }
}
