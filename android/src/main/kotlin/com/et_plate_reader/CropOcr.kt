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
 * Helpers shared by the dedicated section passes ([CodeDiscReader],
 * [RegionStackReader]). Must run off the main thread (blocks on ML Kit).
 */
object CropOcr {
    private val numberRun = Regex("\\d{5,}")

    /** The plate number as read: its characters and their extent. */
    class Anchor(
        val line: List<Text.Symbol>,
        /** Index in [line] of the number's first and one-past-last digit. */
        val start: Int,
        val end: Int,
    ) {
        val first: Rect get() = line[start].boundingBox!!
        val last: Rect get() = line[end - 1].boundingBox!!
        val top: Int get() = (start until end).minOf { line[it].boundingBox!!.top }
        val bottom: Int get() = (start until end).maxOf { line[it].boundingBox!!.bottom }
        val height: Int get() = bottom - top
    }

    /** The tallest run of 5+ digits read on one line, or null. */
    fun numberAnchor(text: Text): Anchor? {
        var best: Anchor? = null
        for (line in text.textBlocks.flatMap { it.lines }) {
            val symbols = line.elements.flatMap { it.symbols }.filter { it.boundingBox != null }
            val joined = symbols.joinToString("") { it.text.take(1).ifEmpty { " " } }
            val m = numberRun.find(joined) ?: continue
            val a = Anchor(symbols, m.range.first, m.range.last + 1)
            if (best == null || a.height > best.height) best = a
        }
        return best
    }

    /**
     * OCR of [area] of [bitmap] alone: scaled so its height is [size] px,
     * centred on a white page with a margin of its own size on every side,
     * optionally reduced to black and white first.
     */
    fun read(
        recognizer: TextRecognizer,
        bitmap: Bitmap,
        area: RectF,
        size: Float,
        blackAndWhite: Boolean,
    ): String? {
        val src = Rect(
            area.left.toInt().coerceAtLeast(0),
            area.top.toInt().coerceAtLeast(0),
            area.right.toInt().coerceAtMost(bitmap.width),
            area.bottom.toInt().coerceAtMost(bitmap.height),
        )
        if (src.width() < 6 || src.height() < 6) return null
        val scale = (size / src.height()).coerceIn(0.5f, 5f)
        val w = (src.width() * scale).toInt().coerceAtLeast(1)
        val h = (src.height() * scale).toInt().coerceAtLeast(1)
        var crop = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        Canvas(crop).drawBitmap(bitmap, src, Rect(0, 0, w, h), null)
        if (blackAndWhite) crop = binarize(crop)
        val m = maxOf(w, h)
        val page = Bitmap.createBitmap(w + 2 * m, h + 2 * m, Bitmap.Config.ARGB_8888)
        Canvas(page).apply {
            drawColor(Color.WHITE)
            drawBitmap(crop, m.toFloat(), m.toFloat(), null)
        }
        return try {
            Tasks.await(recognizer.process(InputImage.fromBitmap(page, 0))).text
        } catch (e: Exception) {
            null
        } finally {
            crop.recycle()
            page.recycle()
        }
    }

    /**
     * Average colour of the ink (pixels darker than the Otsu threshold)
     * inside [area] of [bitmap], as [r, g, b], or null. The plate number's
     * colour identifies the category (code 1 red … 5 orange).
     */
    fun inkColor(bitmap: Bitmap, area: Rect): IntArray? {
        val r = Rect(area).apply { intersect(0, 0, bitmap.width, bitmap.height) }
        if (r.width() < 4 || r.height() < 4) return null
        val px = IntArray(r.width() * r.height())
        bitmap.getPixels(px, 0, r.width(), r.left, r.top, r.width(), r.height())
        val lum = IntArray(px.size) { i ->
            val c = px[i]
            (299 * Color.red(c) + 587 * Color.green(c) + 114 * Color.blue(c)) / 1000
        }
        val t = otsu(lum)
        var n = 0L
        var sr = 0L
        var sg = 0L
        var sb = 0L
        for (i in px.indices) {
            if (lum[i] > t) continue
            val c = px[i]
            sr += Color.red(c)
            sg += Color.green(c)
            sb += Color.blue(c)
            n++
        }
        if (n == 0L) return null
        return intArrayOf((sr / n).toInt(), (sg / n).toInt(), (sb / n).toInt())
    }

    private fun otsu(lum: IntArray): Int {
        val hist = IntArray(256)
        for (l in lum) hist[l]++
        val total = lum.size
        var sum = 0.0
        for (t in 0 until 256) sum += t * hist[t].toDouble()
        var sumB = 0.0
        var wB = 0
        var best = 0.0
        var threshold = 128
        for (t in 0 until 256) {
            wB += hist[t]
            if (wB == 0) continue
            val wF = total - wB
            if (wF == 0) break
            sumB += t * hist[t].toDouble()
            val mB = sumB / wB
            val mF = (sum - sumB) / wF
            val between = wB.toDouble() * wF * (mB - mF) * (mB - mF)
            if (between > best) {
                best = between
                threshold = t
            }
        }
        return threshold
    }

    /**
     * Grayscale + Otsu threshold: dark ink on white. Removes plate colours
     * and the moiré of a photographed screen.
     */
    fun binarize(src: Bitmap): Bitmap {
        val w = src.width
        val h = src.height
        val px = IntArray(w * h)
        src.getPixels(px, 0, w, 0, 0, w, h)
        val lum = IntArray(px.size) { i ->
            val c = px[i]
            (299 * Color.red(c) + 587 * Color.green(c) + 114 * Color.blue(c)) / 1000
        }
        val threshold = otsu(lum)
        for (i in px.indices) px[i] = if (lum[i] <= threshold) Color.BLACK else Color.WHITE
        val out = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        out.setPixels(px, 0, w, 0, 0, w, h)
        src.recycle()
        return out
    }
}
