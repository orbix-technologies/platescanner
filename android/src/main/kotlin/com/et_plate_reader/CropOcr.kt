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

    /**
     * The tallest run of [minDigits]+ digits read on one line (5 by default:
     * a plate number), or null.
     */
    fun numberAnchor(text: Text, minDigits: Int = 5): Anchor? {
        val run = if (minDigits == 5) numberRun else Regex("\\d{$minDigits,}")
        var best: Anchor? = null
        for (line in text.textBlocks.flatMap { it.lines }) {
            val symbols = line.elements.flatMap { it.symbols }.filter { it.boundingBox != null }
            val joined = symbols.joinToString("") { it.text.take(1).ifEmpty { " " } }
            val m = run.find(joined) ?: continue
            val a = Anchor(symbols, m.range.first, m.range.last + 1)
            if (best == null || a.height > best.height) best = a
        }
        return best
    }

    /** How a crop is prepared before OCR. */
    enum class Mode {
        /** As photographed. */
        COLOUR,

        /** Grayscale + Otsu threshold. */
        BW,

        /** Black and white with long straight lines (plate border) erased. */
        CLEAN,
    }

    /**
     * OCR of [area] of [bitmap] alone: scaled so its height is [size] px,
     * centred on a white page with a margin of its own size on every side.
     */
    fun read(
        recognizer: TextRecognizer,
        bitmap: Bitmap,
        area: RectF,
        size: Float,
        blackAndWhite: Boolean,
    ): String? = read(recognizer, bitmap, area, size, if (blackAndWhite) Mode.BW else Mode.COLOUR)

    fun read(recognizer: TextRecognizer, bitmap: Bitmap, area: RectF, size: Float, mode: Mode): String? {
        val crop = prepare(bitmap, area, size, mode) ?: return null
        return ocr(recognizer, listOf(crop))
    }

    /** [area] of [bitmap] scaled to [size] px tall and prepared per [mode]. */
    fun prepare(bitmap: Bitmap, area: RectF, size: Float, mode: Mode): Bitmap? {
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
        if (mode != Mode.COLOUR) crop = binarize(crop)
        if (mode == Mode.CLEAN) stripLines(crop)
        return crop
    }

    /**
     * OCR of [crops] laid side by side on one white page (a margin of the
     * tallest crop's height around and between them), so several single
     * letters read as one word. Recycles [crops].
     */
    fun ocr(recognizer: TextRecognizer, crops: List<Bitmap>): String? {
        if (crops.isEmpty()) return null
        val m = crops.maxOf { maxOf(it.width, it.height) }
        val width = crops.sumOf { it.width } + m * (crops.size + 1)
        val height = crops.maxOf { it.height } + 2 * m
        val page = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        Canvas(page).apply {
            drawColor(Color.WHITE)
            var x = m
            for (c in crops) {
                drawBitmap(c, x.toFloat(), m.toFloat(), null)
                x += c.width + m
            }
        }
        return try {
            Tasks.await(recognizer.process(InputImage.fromBitmap(page, 0))).text
        } catch (e: Exception) {
            null
        } finally {
            crops.forEach { it.recycle() }
            page.recycle()
        }
    }

    /**
     * Erases rows / columns that are mostly ink: the plate border running
     * past a letter. A border boxing in a single letter stops OCR reading it.
     */
    fun stripLines(bw: Bitmap) {
        val w = bw.width
        val h = bw.height
        val px = IntArray(w * h)
        bw.getPixels(px, 0, w, 0, 0, w, h)
        for (y in 0 until h) {
            var ink = 0
            for (x in 0 until w) if (px[y * w + x] == Color.BLACK) ink++
            if (ink > w * 0.6) for (x in 0 until w) px[y * w + x] = Color.WHITE
        }
        for (x in 0 until w) {
            var ink = 0
            for (y in 0 until h) if (px[y * w + x] == Color.BLACK) ink++
            if (ink > h * 0.6) for (y in 0 until h) px[y * w + x] = Color.WHITE
        }
        bw.setPixels(px, 0, w, 0, 0, w, h)
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

    /**
     * Average colour of the plate background (pixels lighter than the Otsu
     * threshold) inside [area], as [r, g, b], or null. A yellow background
     * marks a police plate.
     */
    fun paperColor(bitmap: Bitmap, area: Rect): IntArray? {
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
            if (lum[i] <= t) continue
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
     * and the moiré of a photographed screen. The brightness is first
     * evened out against the plate around it, so a shadow over part of the
     * plate doesn't turn that part black (scans of 2026-10-27).
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
        flatten(lum, w, h)
        val threshold = otsu(lum)
        for (i in px.indices) px[i] = if (lum[i] <= threshold) Color.BLACK else Color.WHITE
        val out = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        out.setPixels(px, 0, w, 0, 0, w, h)
        src.recycle()
        return out
    }

    /**
     * [lum] divided by the brightness of the plate around each pixel: the
     * brightest value within a window wider than a stroke, smoothed. Ink
     * stays dark against its own background, lit or shaded.
     */
    private fun flatten(lum: IntArray, w: Int, h: Int) {
        val r = (minOf(w, h) / 10).coerceAtLeast(4)
        val bg = boxBlur(maxFilter(lum, w, h, r), w, h, r)
        for (i in lum.indices) lum[i] = (lum[i] * 255 / bg[i].coerceAtLeast(1)).coerceAtMost(255)
    }

    /** Brightest value within [r] of each pixel (rows, then columns). */
    private fun maxFilter(src: IntArray, w: Int, h: Int, r: Int): IntArray {
        val rows = IntArray(src.size)
        for (y in 0 until h) for (x in 0 until w) {
            var m = 0
            for (k in maxOf(0, x - r)..minOf(w - 1, x + r)) m = maxOf(m, src[y * w + k])
            rows[y * w + x] = m
        }
        val out = IntArray(src.size)
        for (x in 0 until w) for (y in 0 until h) {
            var m = 0
            for (k in maxOf(0, y - r)..minOf(h - 1, y + r)) m = maxOf(m, rows[k * w + x])
            out[y * w + x] = m
        }
        return out
    }

    /** Mean within [r] of each pixel (rows, then columns). */
    private fun boxBlur(src: IntArray, w: Int, h: Int, r: Int): IntArray {
        val rows = IntArray(src.size)
        for (y in 0 until h) {
            var sum = 0
            var n = 0
            for (k in 0..minOf(w - 1, r)) { sum += src[y * w + k]; n++ }
            for (x in 0 until w) {
                rows[y * w + x] = sum / n
                val add = x + r + 1
                val drop = x - r
                if (add < w) { sum += src[y * w + add]; n++ }
                if (drop >= 0) { sum -= src[y * w + drop]; n-- }
            }
        }
        val out = IntArray(src.size)
        for (x in 0 until w) {
            var sum = 0
            var n = 0
            for (k in 0..minOf(h - 1, r)) { sum += rows[k * w + x]; n++ }
            for (y in 0 until h) {
                out[y * w + x] = sum / n
                val add = y + r + 1
                val drop = y - r
                if (add < h) { sum += rows[add * w + x]; n++ }
                if (drop >= 0) { sum -= rows[drop * w + x]; n-- }
            }
        }
        return out
    }
}
