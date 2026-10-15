package com.et_plate_reader

import android.graphics.Bitmap
import android.graphics.Rect
import android.graphics.RectF
import com.google.mlkit.vision.text.Text
import com.google.mlkit.vision.text.TextRecognizer

/**
 * Section 4 pass: the Latin region, two letters stacked at the right end.
 *
 * OCR tends to merge the stacked letters into one tall glyph (often "1")
 * glued to the number. Each candidate column right of the number's start is
 * cut into a top and a bottom half and each half is read alone as a single
 * letter. Candidates, in order: characters OCR put after the number, the
 * space right of it, and the number's last "digit" (which may be the merged
 * column). Every column that reads is returned; the caller keeps the
 * first whose letters name a region (a real digit or the plate border can
 * also split into two letter-like halves).
 *
 * Must run off the main thread (blocks on ML Kit).
 */
object RegionStackReader {
    private const val HALF_SIZE = 160f

    private val noise = setOf('.', ',', '-', '_', '\'', '"', ':', ';', '|')
    private val asLetter = mapOf('4' to 'A', '0' to 'O', '1' to 'I', '5' to 'S', '8' to 'B', '6' to 'G', '2' to 'Z')

    class Column(val letters: String, val source: String, val box: Rect, val top: Rect, val bottom: Rect)

    /** Every candidate column that read as two letters, in the order tried. */
    fun read(
        recognizer: TextRecognizer,
        text: Text,
        bitmap: Bitmap,
        log: MutableList<String>? = null,
    ): List<Column> {
        val anchor = CropOcr.numberAnchor(text)
        if (anchor == null) {
            log?.add("region: no number anchor")
            return emptyList()
        }
        val h = anchor.height
        val pad = (h * 0.05f).toInt()
        val last = anchor.last

        val candidates = ArrayList<Pair<String, IntRange>>()
        val trailing = (anchor.end until anchor.line.size).map { anchor.line[it].boundingBox!! }
        if (trailing.isNotEmpty()) {
            candidates.add("trailing" to (trailing.minOf { it.left } - pad..trailing.maxOf { it.right } + pad))
        }
        // Latin stack: 0.05–1.1 digit pitch right of the number (measured
        // on real plates); wider reaches stray text such as watermarks.
        val p = (last.right - anchor.first.left).toFloat() / (anchor.end - anchor.start)
        val zoneRight = minOf(bitmap.width, last.right + (p * 1.1f).toInt())
        if (zoneRight - last.right >= h / 4) {
            candidates.add("zone" to (last.right + pad..zoneRight))
        }
        candidates.add("lastDigit" to (last.left - pad..last.right + pad))

        val mid = anchor.top + h / 2
        val found = ArrayList<Column>()
        for ((source, xs) in candidates) {
            val top = Rect(xs.first, anchor.top - 2 * pad, xs.last, mid)
            val bottom = Rect(xs.first, mid, xs.last, anchor.bottom + 2 * pad)
            val a = letter(recognizer, bitmap, top, log, "$source/top")
            val b = letter(recognizer, bitmap, bottom, log, "$source/bottom")
            if (a == null || b == null) continue
            found.add(Column("$a$b", source, Rect(xs.first, anchor.top, xs.last, anchor.bottom), top, bottom))
        }
        return found
    }

    private fun letter(
        recognizer: TextRecognizer,
        bitmap: Bitmap,
        area: Rect,
        log: MutableList<String>?,
        label: String,
    ): Char? {
        // Read in colour and in black and white; a letter counts when the
        // two agree, or when only one of them reads a letter at all.
        val reads = listOf(false, true).map { blackAndWhite ->
            val text = CropOcr.read(recognizer, bitmap, RectF(area), HALF_SIZE, blackAndWhite)
            val chars = (text ?: "").filter { !it.isWhitespace() && it !in noise }
                .map { c -> asLetter[c] ?: c.uppercaseChar() }
            val letter = if (chars.size == 1 && chars[0] in 'A'..'Z') chars[0] else null
            log?.add("region: $label crop=${area.toShortString()} bw=$blackAndWhite read='${text?.replace("\n", " ")}' -> $letter")
            letter
        }
        val letters = reads.filterNotNull().distinct()
        val result = if (letters.size == 1) letters[0] else null
        if (letters.size > 1) log?.add("region: $label reads disagree $letters -> none")
        return result
    }
}
