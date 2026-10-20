# Plate reading pipeline

The steps from opening the scanner to a confirmed reading. For each step:
what it does, where it lives, how to test it, the faults seen in the
session logs, and ideas to improve it. We work through them one step at a
time: test → analyse faults → fix → brainstorm better approaches.

| # | Step | Where |
|---|---|---|
| 0 | Labelled test set and per-step accuracy | *to build* |
| 1 | Find the plate area live | native frame OCR, `parsing/plate_area_detector.dart` |
| 1b | Snap the area to the plate on the still | `segmentation/plate_bounds_finder.dart` |
| 2 | Capture the still | `PlateScannerView.kt` / `PlateScannerView.swift` |
| 3 | User confirms / adjusts the area | `widgets/plate_scanner_view.dart` |
| 4 | Prepare the image | `segmentation/segment_capture.dart` |
| 5 | Ink mask | `segmentation/plate_segmenter.dart` (`_inkMask`, `_eraseLines`, `_open`) |
| 6 | Shapes | `plate_segmenter.dart` (`_blobs`, filters, `_splitTouching`) |
| 7 | Columns | `plate_segmenter.dart` (`_columns`, `_classify`, `_mergeHalves`) |
| 8 | Assign the four sections | `plate_segmenter.dart` (`segment`, `_numberRun`, `_splitJoinedStack`) |
| 9 | Decide the crops to read | `parsing/plate_section_reader.dart` (`cropsFor`) |
| 10 | OCR the crops | native `readCrops`, `CropOcr.kt` / `CropOcr.swift` |
| 11 | Interpret and validate | `plate_section_reader.dart` (`read`), `plate_arranger.dart` (code rules), `ethiopian_plate_parser.dart` |
| 12 | Review and Done | `widgets/plate_scanner_view.dart` |
| 13 | Logging | `diagnostics/session_log.dart` |

Tools available for testing:

- `tool/area_logs.dart`: snaps every logged session's proposed area and
  draws proposed (red), confirmed (green), snapped (cyan) and the serial
  row (yellow) on contact sheets (`ONLY=`, `SHAPES=1` for the shapes).
- `test/plate_bounds_finder_test.dart`: 12 real stills with the plate area
  checked by eye.
- `tool/segment_logs.dart`: draws the segmentation for every logged session
  (`ONLY=` to filter, `COLS=1` for column details).
- `tool/export_plate_fixture.dart`: saves a session's plate area as a test
  fixture.
- `test/replay_sections_test.dart` (`LOGS_DIR=`): replays logged crop reads
  through the section reader.
- `test/segmentation_test.dart`: 24 real plate crops with expected sections.

---

## 0. Labelled test set and per-step accuracy (to build first)

**Goal:** measure each step instead of judging by eye.

- A ground-truth file: for each logged session, the correct code, region,
  number and the section boxes.
- A script that replays every session through steps 4–11 and reports
  accuracy per step (area found, sections found, each section read right).

**Ideas**
- An HTML page showing every scan with each step's output side by side.
- Record the confirmed answer (edits + Done) in the log, so every finished
  scan becomes labelled data automatically.

## 1. Find the plate area live

**What:** ML Kit OCR on each camera frame → keep lines fully inside the
guide box → anchor on the serial-like line (5+ digit-like characters) → grow
a box over that band plus margin → auto-capture after 3 steady frames (or
Capture).

**Test:** compare the detected area with the area finally confirmed (both
logged).

**Faults seen**
- Needs readable text: distant or blurred plates are never detected.
- Box too tight (stacked A/A cut off at the edge) or too loose (two plates
  in view).

**Ideas**
- Detect the plate by shape (bright rectangle with a dark border), not text.
- A fixed margin so the stacks are never cut.
- "Move closer" hint when the characters are small.

## 1b. Snap the area to the plate on the still

**What:** right after capture, off the UI isolate: find the serial on the
still (a row of 4+ same-height dark shapes nearest the proposed area,
extended over digits joined to a screw or the border) → top / bottom = the
long horizontal edges just outside the row (outer of plate edge / printed
border) → left / right = the first vertical edge, going outwards, that
spans the plate's height *including the margins above and below the row*
(text never does), near where the top / bottom edges end → small margin.
The proposed box is replaced unless the user already moved it. If nothing
is found near the proposal, the detection at the moment of the still is
tried; otherwise the proposal stays.

**Test:** `tool/area_logs.dart` on the logs; `plate_bounds_finder_test`.

**Faults seen (fixed by this step)** — 172 logged sessions:
- Proposal from a frame before the still: box shifted off the plate, or on
  a fog lamp.
- Box too tall (aspect ~3 instead of ~4.2), stack cut at the right edge,
  neighbouring plate or watermark line included.
- Snapped: 166 / 172; all four edges found on 146. Diplomatic plates
  (embassy number · Ge'ez · 4 digits · C/D) fit too: the row stops at the
  dot before the serial, and the side search reaches the plate's left edge
  past the embassy number. Only 3 CD scans logged so far. Segmentation on the
  snapped area finds more circles / Ge'ez / Latin stacks than on the
  area users confirmed by hand.

**Faults left**
- Plate whose digits touch a dark holder frame (60648): no row found.
- Tiny, blurred night shots; old 2-row and AAL plates (out of scope).
- Plate without a printed border on a white car: a bit loose.

## 2. Capture the still

**What:** high-resolution photo (CameraX `ImageCapture`, ~2560×1440;
AVFoundation 1080p on iOS) cropped to the visible preview, saved as JPEG.

**Test:** pixels per character height in the logged photos; blur measure.

**Faults seen**
- Motion blur; plate small in the frame (a few hundred pixels wide).

**Ideas**
- Take 2–3 shots and keep the sharpest.
- Tap-to-focus on the plate before capturing.
- Sharpness check with a "hold still" warning.

## 3. User confirms / adjusts the area

**What:** frozen photo with a draggable box; Confirm area or Retake.

**Test:** how often and how far the box is moved (logged).

**Faults seen**
- Extra work for the user; a box that cuts the stacked letters.

**Ideas**
- Snap the box to the plate border automatically, so confirming is a tap.

## 4. Prepare the image

**What:** crop to the area, scale to 160 px tall, grayscale.

**Faults seen**
- Tilted and curved plates stay tilted; 160 px loses detail on small
  plates.

**Ideas**
- **Deskew:** estimate the tilt from the border lines or the digits'
  baseline and rotate.
- **Perspective correction:** find the plate's four corners and warp to a
  flat rectangle.
- Choose the working height from the character size.

## 5. Ink mask

**What:** adaptive (Bradley) threshold over a window half the crop's height
→ erase rows / columns that are mostly ink (border) → thin-line opening only
inside tall, solid, over-wide shapes (watermark / cursor joins).

**Test:** view the masks of the fixtures (to add to `segment_logs.dart`).

**Faults seen**
- Border lines survive on tilted plates.
- Watermark text and a mouse cursor join digits (photos of a screen).
- Thin rings and Ge'ez strokes break if thinned.

**Ideas**
- Erase the border after deskewing (then exactly horizontal / vertical).
- Use colour distance from the plate background instead of brightness
  (blue, red, green ink).
- Speck cleanup.

## 6. Shapes

**What:** connected ink regions → drop noise, shapes cut by the crop edge,
hollow border fragments, slivers, flat border remnants → split touching
digits (not rings) → split stacked letters touching (thin neck).

**Faults seen**
- The plate's stencil font breaks "0" and "1" into pieces.
- Screw heads touch or cut letters.
- Stacked letters touch each other.

**Ideas**
- Use the known font: digit widths and gaps are fixed, so split and merge
  against a template grid.
- Screw / rivet detector (small, round, dark, with a highlight).

## 7. Columns

**What:** shapes overlapping horizontally form a column (not side by side at
the same height, unless nested) → classify **tall** (digit), **stack** (two
letters), **circle** (ring with a digit inside), **short** → merge slivers
and stencil pieces into digits; a stack between two digits is digit pieces.

**Faults seen** (most logged bugs came from here)
- A round 6 grouped with the narrow A/A or E/T beside it.
- A/A joined into one shape counted as a digit.
- The "1"'s flag, stem and foot taken for a stack.
- Each fix is a separate local rule, which makes the whole fragile.

**Ideas**
- **Layout fitting:** every plate follows one of a few layouts (circle ·
  Ge'ez stack · chip · 5–7 digits · Latin stack; police; diplomatic; UN /
  AU). Fit each layout to the shapes and keep the best fit, so the plate's
  grammar decides instead of many local rules.

## 8. Assign the four sections

**What:** number = longest run of tall columns (small pieces in its band
bridge gaps; a stack or circle ends it); the first stack right of it =
section 4 (or two letters side by side, AU); a last column clearly taller
than the digits = joined section 4; the stack left of it = section 2; the
circle further left = section 1 (its inner shape kept for reading); tall
columns left of the Ge'ez = embassy digits (CD).

**Faults seen**
- Tilted plates.
- Circle hidden in a border fragment.
- A large series letter (C) next to the Ge'ez taken as part of section 2.

**Ideas**
- Layout fitting (step 7).
- Check the measured distances (circle ≈ 2.8 digit pitch left of the
  number, Ge'ez ≈ 1.6, chip ≈ 0.6, Latin stack 0.1–1.0 right) and search a
  focused window when a section is missing.

## 9. Decide the crops to read

**What:** number crop (bounded halfway to the stacks); each stacked letter;
both letters side by side as one word; the digit inside the circle, single
and drawn three times; embassy digits; single digits only in a second round
when the number reads disagree.

**Faults seen**
- Padding sometimes includes ring or border pieces.

**Ideas**
- Mask out everything that is not the character's own pixels.

## 10. OCR the crops

**What:** ML Kit (Android) / Vision (iOS); every crop read three ways (as
photographed, black and white, border lines erased).

**Faults seen** (main one)
- Clear single characters read as nothing (T, M, the circled 4).
- 6 read as 9; the notched 0 read as G or D.

**Ideas** (likely the biggest win)
- **Our own character classifier.** The font is fixed and the set is small:
  10 digits, circled 1–5, ~15 Latin region letters, and the Ge'ez region
  letters. Template matching or a tiny model trained on the crops already in
  the logs would read single characters far better than general OCR, offline
  — and could read the **Ge'ez** too.

## 11. Interpret and validate

**What:** number = vote across the whole-number reads (series letter kept
before five digits; G → 0); letters by majority plus the word read, lenient
variants only if they name a region / UN / AU / CD; code: special plate,
yellow background → police, circle vote, ink colour (never red ↔ orange);
`EthiopianPlateParser.validate`.

**Faults seen**
- Many hand-written rules (look-alikes, colour versus circle).

**Ideas**
- With a classifier, each character has a confidence; most rules go away.
- Ge'ez ↔ Latin consistency: section 2 must match section 4 (አአ ↔ AA).
  Done one way: section 2 is now spelled from section 4's region
  (`PlateArranger.geezFromLatin`, note "from AA"); it is still not read.

## 12. Review and Done

**What:** enlarged plate with section boxes 1–4, four section cards, the
reading, Edit / Adjust area / Retake, Done.

**Ideas**
- Tap a section card to fix just that section.
- Show low-confidence characters in orange.

## 13. Logging

**What:** per scan, a JSON log (detections, capture, confirmed area,
segmentation, every crop and its reads, the sections, timings, how it ended)
plus the photo, in `cache/et_plate_logs/`.

**Ideas**
- Record the confirmed answer so finished scans are labelled ground truth.

---

## Suggested order

1. **Step 0:** labelled set + per-step accuracy report.
2. **Steps 4–8:** deskew / perspective + layout fitting (section detection).
3. **Step 10:** glyph classifier trained on the logged crops (also reads
   Ge'ez).
4. Steps 1–3 (capture quality) and 12 (review UI).
