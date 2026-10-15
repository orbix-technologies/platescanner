package com.et_plate_reader

import android.graphics.Bitmap
import android.graphics.RectF
import com.google.mlkit.vision.text.Text
import com.google.mlkit.vision.text.TextRecognizer

/**
 * Section 1 pass: the circled service code.
 *
 * Latin OCR reads the ring as a letter ("D-0123456") and misses the digit.
 * Reading only the inner disc — ring cropped away, padded with white —
 * returns the digit. The circle sits left of the plate number, on its row,
 * about as tall as a digit; crops are scanned left to right through that
 * zone so the circle is met before the Ge'ez. If nothing reads, the sweep
 * is repeated in black and white.
 *
 * Must run off the main thread (blocks on ML Kit).
 */
object CodeDiscReader {
    private const val DISC_SIZE = 180f

    // Ring fragments read as brackets / O are dropped; glyphs commonly read
    // for the code digit are mapped.
    private val ringNoise = setOf('(', ')', '[', ']', '{', '}', 'O', 'o', 'C', 'c', '0', '.', ',', '-')
    private val asDigit = mapOf('I' to '1', 'l' to '1', '|' to '1', 'i' to '1', 'Z' to '2', 'z' to '2', 'S' to '5', 's' to '5')

    /**
     * Returns "1".."5", or null. [bitmap] is only called when a pass is
     * needed and must return the upright image matching [text]'s boxes.
     */
    fun read(
        recognizer: TextRecognizer,
        text: Text,
        log: MutableList<String>? = null,
        bitmap: () -> Bitmap,
    ): String? {
        val anchor = CropOcr.numberAnchor(text)
        if (anchor == null) {
            log?.add("code: no number anchor")
            return null
        }
        val digit = anchor.first
        val image = bitmap()
        val h = anchor.height.toFloat()
        val half = h * 0.2f
        val cy = (anchor.top + anchor.bottom) / 2f
        log?.add("code: anchor digit=${digit} numberHeight=$h image=${image.width}x${image.height}")
        for (blackAndWhite in listOf(false, true)) {
            var cx = maxOf(half, digit.left - 3.5f * h)
            val end = digit.left - 0.4f * h
            while (cx <= end) {
                val crop = RectF(cx - half, cy - half, cx + half, cy + half)
                val read = CropOcr.read(recognizer, image, crop, DISC_SIZE, blackAndWhite)
                val digitRead = digitOf(read)
                log?.add("code: crop=${crop.toShortString()} bw=$blackAndWhite read='${read?.replace("\n", " ")}' -> $digitRead")
                if (digitRead != null) return digitRead
                cx += h * 0.15f
            }
        }
        return null
    }

    /** The single code digit in [text], or null. */
    fun digitOf(text: String?): String? {
        if (text == null) return null
        val chars = text.filter { !it.isWhitespace() && it !in ringNoise }.map { asDigit[it] ?: it }
        if (chars.isEmpty() || chars.any { it != chars[0] } || chars[0] !in '1'..'5') return null
        return chars[0].toString()
    }
}
