# Patrol: reading plates while walking (90° and 45° parking)

How patrol mode reads the plates of parked vehicles as a person walks past
them, step by step, with where each step lives, what changes between cars
parked at 90° and at 45°, how it was tested, and what is still open.

Single-plate scanning (open the scanner, take one photo) is described in
[PIPELINE.md](PIPELINE.md); patrol reuses its steps 1b and 4–11 for the
full read of each vehicle.

| # | Step | Where |
|---|---|---|
| 1 | Camera stream | `android/.../PlateScannerView.kt` (`patrol = true`) |
| 2 | Live text recognition | native frame OCR (ML Kit / Vision) |
| 3 | Find plate numbers in the text | `patrol/patrol_tracker.dart` (plates in a frame, `plausible`) |
| 4 | Reject text that isn't a plate | `patrol_tracker.dart` (`_notAPlate`, `_withoutCircle`) |
| 5 | Track vehicles across frames | `PatrolTracker.update` |
| 6 | Vote on the number | `PatrolVehicle._recount`, `lookAlike` |
| 7 | Report a vehicle when it leaves | `PatrolTracker` (`lostAfter`, `duplicateWindow`, `nearWindow`) |
| 8 | Choose the focus plate | `patrol/patrol_controller.dart` (`_chooseFocus`, `_inFullView`) |
| 9 | Decide when to photograph it | `PatrolController._wantsPhoto` |
| 10 | Full read of the photo | `patrol/patrol_refiner.dart` (`PatrolRefiner.refine`) |
| 11 | Keep the best full reading | `PatrolVehicle.applyFull`, `complete` |
| 12 | Result and record | `PatrolVehicle.needsCheck`, `toRecord` |

```
Camera frames ─► OCR text ─► plate numbers ─► track vehicles ─► vote ─► report when it leaves
                                                    │
                                                    └─► focus plate ─► photo ─► full read
                                                                                (code, region, number)
```

## Why two layers

Live text recognition is fast (every frame) but, on a small moving plate,
it reads only the large number. The code circle and the small region
letters are too small for it. The full read (finding the plate outline,
splitting it into sections and reading each section enlarged) gets them,
but takes about half a second per photo. So:

- **Layer 1, every frame (steps 1–7):** finds and follows each plate and
  votes on its number.
- **Layer 2, the focus plate only (steps 8–11):** photographs the one
  plate in focus at its closest, sharpest moment and reads it in full.

## Layer 1: every frame

### 1. Camera stream

- A video stream requested at 1920×1080. On the test phone (Samsung,
  camera level LIMITED) it binds at 1440×1080.
- Stills for the full read are requested at 4:3, 3264×2448; the test phone
  falls back to 1920×1440.
- Zoom 1.6× (`PATROL_ZOOM`), so plates 1.5–3 m away are large enough.
- 30 fps auto-exposure, so the shutter stays short and moving plates stay
  sharp.
- Only the newest frame is analysed; frames that arrive while it is busy
  are dropped, so it never lags behind the walker.

### 2. Live text recognition

The frame is read on the device (ML Kit on Android, Vision on iOS), giving
lines of text with their boxes, normalized to the visible preview.

### 3. Find plate numbers

Each line with a number a plate can carry starts a plate, read together
with the lines beside it on its band (region letters, embassy number).
The region is **beside the number on one-row plates and on the row above
it on two-row plates**. Live text reads a two-row plate's top row as one
line: the circle as `O` / `9`, the Ge'ez pair as small `hh`, then the
region in capitals (`OhhAA`, `9h hA A`). So the lines beside and just
above the number (smaller, within its width, with no number of their
own) are searched for trailing capitals that are a region code, and that
wins over the general parse, which took `hh` for Harari (`HR`). The
circle's digit reads as anything (`9`, `7`, `1`, `O` for a 2), so the
code is left to the full read. On the walk of 2026-10-23 this took the
region read live from 3 of 26 vehicles to 23.

- 5 digits, optionally with a series letter (`B05475`);
- 6–7 digits (the older and sample formats);
- the new national plate, three letters and four digits (`ABC1234`);
- diplomatic: embassy number, then four digits (`63-0123`, `06 0123`).

### 4. Reject text that isn't a plate

- Text outside the visible preview: the camera frame is wider than the
  screen, so it reads text the user can't see and photos don't contain.

- Phone numbers and web text on vehicles (spare-wheel covers, stickers):
  `+`, `@`, `www`, `.com`, a mobile number (`09…`, `07…`), or three or
  more groups of digits.
- A diplomatic number (`10 8161` on a sticker) only with a plate seen
  around it (10b).
- Writing on screens, signs and paper: a word in small letters (plates
  use capitals only), or a `:` (times, addresses, ports).
- The lines beside the number are checked too, so a neighbouring
  `10.42.0.165:` can't lend the number a code.
- The circled code read as a letter joined to the number (`O30142`,
  `G30138`): series letters are A, B, C…, never O, G or Q, so that letter
  is dropped and the five digits kept.

### 5. Track vehicles across frames

Each plate in a frame is matched to the vehicle seen at about the same
place, or with the same number, in the previous frames. A vehicle collects
every reading of its plate while it is in view.

### 6. Vote on the number

- The winning number is the one most frames agree on. Code and region are
  voted on separately, among the readings of that number: "AA" is read in
  about a third of the frames, so the reading most often seen whole would
  be the number alone.
- Look-alike misreads count as the same number (`B08468` = `808468`;
  O = 0, I = 1, …).
- It is shown in its most complete form: with the series letter when one
  was read, and with the code and region when a reading had them.

### 7. Report a vehicle when it leaves

Only a plate is reported. A plate walked past is read again and again,
mostly with its region; random text (a sticker, a sign, a clock, a
misread) is glimpsed in a frame or two with nothing around it. So a
vehicle counts when it was read in **3 or more frames**, or with **plate
evidence**: its region read, a plate outline seen around its number
(10b), or a national number read twice. A diplomatic number only with
the outline (common on stickers). Others are dropped. On the walks of
2026-10-23 this dropped all 10 random detections (read in 1–2 frames,
nothing around them) and none of the 26 real readings (3–37 frames).

- A vehicle not seen for **0.9 s** has left the view and is reported once.
- The same number again within **90 s** (its other plate, or walking back)
  is merged into the earlier vehicle, not reported again.
- A number one character off a vehicle that left within **4 s** is a
  misread of it and is merged.
- A vehicle that never had a readable number is dropped.
- A vehicle reported already can be merged later: another one leaving
  is the same plate (a misread, `C69061` then `C69001`), and its winning
  number changes. It is reported again (`onVehicle`, same record id); one
  merged away into another is reported to `onVehicleRemoved`.

## Layer 2: the focus plate

### 8. Choose the focus plate

Of the plates fully in view (at least 3% from every edge), the largest,
that is the closest. It keeps the focus until it has been read in full
(complete, with a photo) or another plate is 1.5× wider (clearly closer),
so the box doesn't jump between cars. This is what makes patrol read **one
plate at a time**.

### 9. Decide when to photograph it

- When it first becomes the focus.
- Again only when it is at least **1.3×** wider than in its last photo
  (the walker is clearly closer).
- At most **3** photos per vehicle, and one at a time.
- First the very frame its number was read in (`frameImage`): the plate
  is fully in view there. The full-resolution still (`captureFrame`) is
  asked for at the same time but takes 0.5–1 s, by when a plate walked
  past is at the edge or gone (walk of 2026-10-23: 8 of 27 full reads
  found no number on the still); it is read only when the frame didn't
  give a full reading, and given up after 1.5 s (`stillTimeout`).
- Vehicles that are not the focus (or not fully in view yet) get one
  video frame (`_snapshot`) when no photo is being taken, so every vehicle
  has a picture. It is the very frame the number was read from: the native
  side keeps the last 4 analysed frames that read a number, by frame id
  (`frameImage`), so the plate box drawn on it is exactly where the text
  was read. Once that frame is gone, the next one (`grabFrame`). A vehicle that left before its picture was
  ready is reported again with it, and Finish waits up to 2.5 s for a
  picture still being taken. It is not read in full: those vehicles carry the
  live number only.

### 10. Full read of the photo

1. **Find the number on the photo.** OCR the whole photo, and take the
   element matching the vehicle's live number (look-alikes equal, or the
   national format) **nearest** to where it was seen live. The same
   number can appear twice (both plates, a sheet of samples).
2. **Search area for the whole plate.** The plate reaches past the
   number: the circle and Amharic letters to the left, the region letters
   to the right, and the top row of two-row plates above. With `h` the
   number's height, the area is the number's box grown by 1.6h left, 0.9h
   right and 0.5h up and down.
3. **Snap to the plate outline** (`PlateBoundsFinder`, PIPELINE step 1b):
   the serial row, its tilt, then the plate's edges or printed border
   along it. Two-row plates: the top row is found above the number (with
   border runs erased first, because the top-row letters touch the
   border — along the row's tilt, or a tilted border survives as short
   slanted runs). Letters merged into one wide shape (the circle and the
   Ge'ez pair, small or at an angle) count as the letters they span. Not
   a top row: shapes two-thirds of a digit high, six or more alike, or a
   digit-high shape beside them (the number of another plate above).
4. **Split into sections** (`PlateSegmenter`, PIPELINE steps 4–8): code
   circle, Amharic region, number, Latin region letters, for every layout
   (one-row, old two-row, diplomatic, police, temporary, UN/AU, national
   ETH). The outline search's two-row finding is passed on
   (`twoRowHint`), so fewer top-row letters are needed. When they merged,
   the top row's fixed layout places the sections (circle 0–0.21 of the
   number's width, Ge'ez pair 0.21–0.52, Latin pair 0.62–1.05; the chip
   between is skipped). On that walk this took two-row plates read in
   all four sections from 2 of 17 photos to 9.
5. **Read each section** cropped and enlarged (`readCrops`, PIPELINE steps
   9–11), and combine them into code + region + number.

### 10b. Is there a plate at all?

Each picture of a vehicle (a photo where its number was found, or a video
frame) is searched for a plate outline around the number. It counts as a
plate when the plate's own **top and bottom edges** are found
(`PlateBounds.isPlate`): measured on logged patrol photos and rendered
screen text, real plates that showed an outline always had both, and text
on a screen or a page never did (0 of 78 lines, light and dark).

A vehicle read in **only one frame** whose pictures showed no plate is
dropped: a glance at text that isn't a plate (a clock read as
`Ot 23 154`, a sign). Read in two or more frames, a vehicle whose
pictures were searched and none showed a plate (`noPlateSeen`) is marked
**Check** and saved with status `check`. It is
not dropped: the outline is missed on about 1 in 3 real plates in walking
photos (blur, angle), so dropping would lose real cars.

### 11. Keep the best full reading

A full reading is kept when its number agrees with the live vote
(look-alikes equal, or only the series letter differs: the number crop
read `170677` for `C70677`, keeping the live number), or, when the live number is uncertain, when it is
complete. Of those, a valid reading wins over an invalid one, and one with
more parts read wins over one with fewer.

### 12. Result and record

- **✓** when the kept full reading is complete (code, region where the
  plate kind has one, number) and agrees with the live number.
- **Check** when the number was read only once, the frames disagree
  (fewer than 2 agreeing votes or under 50% agreement), the full read is
  not complete, or no plate was seen around the number (10b).
- Each record keeps the photo, the plate area and each section's box
  (`plateArea`, `sectionAreas`), and the layout (one or two rows) of the
  full reading. The example app's record page draws them.
- Each vehicle is reported to `onVehicle` when it leaves the view, again
  when a full reading is kept, and, for those still in view, when the
  patrol ends: on Finish, and also when it is closed or left with back.
  The record's id stays the same, so saving each report replaces the
  earlier one; the example app saves every report this way, so a closed
  patrol or a crash mid-walk loses nothing.
- Photos are taken into the app's cache, which the system may clear; the
  host keeps them by copying them into its own storage (the example app
  copies them into its documents folder, `plate_photos/`).

## 90° and 45° parking

### What the camera sees

| | 90° (perpendicular) | 45° (angled) |
|---|---|---|
| Plate to camera | Faces the walker when they turn the phone to it | Turned about 45° away from the walker |
| Plate shape in the image | Normal proportions (one-row ≈ 4.5:1, two-row ≈ 2:1) | About 0.7× as wide: one-row ≈ 3.2:1, two-row ≈ 1.4:1 |
| Size across the plate | Even | Perspective: the near end is larger than the far end |
| Code circle | Round | An oval up to about 0.6 as wide as tall when it is on the far end |
| Thin strokes (0, 1) | Clear | Narrower; can break up on the near end |
| Time in view | Short: neighbouring cars hide the plate until the walker is in front | Longer: the plate is visible earlier along the row |
| Walking direction | Doesn't matter | Matters: walking the way the plates face gives a less steep view |

Steps 1–9 work the same for both: they track the number's text, which
recognition still reads at 45°. The angle matters in the full read
(step 10), whose shape checks were written for plates seen from the front.

### Changes for 45°

- **Code circle (segmenter, `_classify`).** The circle used to need a
  width/height ratio of 0.75–1.35, which rejects the far-end oval at 45°.
  It now accepts 0.5–1.35, and to stop a narrow digit from passing, the
  ring must hold a shape (the code digit) at least a quarter of its height
  and centred vertically (within 0.2 of the ring's height). On the
  straight-on photos this changed one result only, a circled 1 that was
  missed before and is now found.

### Test results

`tool/angle_sim.dart` turns each logged scan photo as if the plate were
seen at an angle (in perspective, from about three plate widths away, in
both directions), then snaps and segments it, and compares with the
straight-on photo. 165 photos × 2 directions = 330 cases.

| Found on the turned photo | 90° | 30° | 45° before | 45° after |
|---|---|---|---|---|
| Plate area (overlap ≥ 0.7) | 330/330 | 321/330 | 303/330 | 303/330 |
| Code circle | 262/264 | 251/264 | 137/264 | **253/266** |
| Region letters | 314/318 | 308/318 | 300/318 | 300/318 |
| Amharic region | 314/314 | 265/314 | 240/314 | 251/314 |
| Number box spans the same digits | 322/330 | 282/330 | 256/330 | 258/330 |

The straight-on photos now find 266 circles instead of 264 (the circled 1
above and one more). Run it with:

```
ANGLE=45 dart run tool/angle_sim.dart <et_plate_logs dir> <out dir>
```

Failures are drawn on contact sheets in `<out dir>` (`ONLY=` to filter,
`COLS=1` for column details).

### Still open at 45°

- **Leading digit lost on the near end.** In about 1 in 5 turned photos
  the first one or two digits (often a 0) lose their thin side strokes,
  break into top and bottom arcs and are taken for Amharic letters, so the
  number crop starts too late. Many of these are sample-sheet photos with
  watermark text across the digits, and the simulated turn blurs thin
  strokes, so the real rate needs real 45° walks.
- **Plate shape limit.** The outline search expects one-row plates of
  3.3–5.2:1 and two-row of 1.5–2.8:1. A plate at 45° is close to (or
  below) the lower limits; it passed in the simulation, but real walks
  should confirm it.
- **Text recognition at 45°.** Not simulated: the live and whole-photo
  OCR is native and only runs on the phone.

## How to walk

- Hold the phone upright at about plate height (waist to knee), not at
  eye level pointing down.
- Stay 1.5–3 m from the plates; a plate should fill about a third of the
  screen width.
- Walk a little slower than normal; each plate should be fully on screen
  for about a second.
- Keep the plate in the middle of the screen, with the circle and region
  letters inside. When the focus box and the "Now reading" card appear,
  hold steady for a moment.
- **90°:** turn the phone toward each plate as you pass it.
- **45°:** walk past normally, without stepping in front of each car. To
  compare, walk the row once in each direction.

Every patrol is logged when `recordSessions` is on, even one without a
single photo (a video frame of the scene is saved with it then).

## Testing a walk

1. Patrol with `recordSessions: true` (the example app does).
2. Pull the logs and photos:
   `adb exec-out run-as com.et_plate_reader.et_plate_reader_example tar c cache | tar x`
3. `cache/et_plate_logs/patrol_*.json` holds every frame's lines, every
   vehicle, and a trace of each full read (number found, search area,
   snapped area, sections, crop reads, result).
4. `tool/patrol_log_replay.dart` and `tool/patrol_photos.dart` replay the
   tracker and the full read offline; `example/lib/patrol_probe.dart`
   re-runs the full read with the phone's OCR on every logged photo.
5. In the example app, tap a reading to see the photo with the plate area
   and each section's box (code blue, Amharic purple, number yellow,
   region green); a part not found is marked "(not found)".
