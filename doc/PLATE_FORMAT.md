# Ethiopian plate format

Source for categories, colours and region codes:
[metaappz — Ethiopian licence plates](https://www.metaappz.com/References/Ethiopian_licence_plates)
(the page notes its samples may not be identical to the originals).
Layout measurements come from real plate photos.

## Sections (current plates), left to right

| # | Section | Content | How it is read |
|---|---|---|---|
| 1 | Code | Number in a circle (category) | Circle pass on the inner disc; else the number's ink colour |
| 2 | Region (Ge'ez) | Two Ge'ez letters stacked vertically | Not recognised (shown as `XX`); mapped from section 4 |
| 3 | Number | 5–7 digits | Main OCR, longest run of number-sized digits |
| 4 | Region (Latin) | Two Latin letters stacked vertically | Stacked-letter pass (top / bottom halves read alone) |

A small security chip sits between sections 2 and 3, "ETH" marks in the
corners and a vertical security number on the left edge; none are read.

Positions measured from the number in digit pitch `p` (EBR sample / taxi
94529): circle centre ≈ 2.7–2.8p left, Ge'ez ≈ 1.5–1.65p left, chip ≈ 0.6p
left, Latin stack ≈ 0.3–0.85p right.

## Categories (section 1)

| Code | Category | Colours |
|---|---|---|
| 1 | Taxi (minibuses, contract taxis, bajajs) | Red |
| 2 | Private | White / blue |
| 3 | Commercial / business | White / green |
| 4 | Government | White / black |
| 5 | Red Cross, religious and civic societies | White / orange |

Special plates: UN (light blue, "የተመ" / "UN"), AU (light green, "አሕ" /
"AU"), temporary (light blue, "ተላላፊ"), police (yellow, black characters,
"ፖሊስ" on the left), embassies (numbered country codes, e.g. 01 Italy,
04 USA, 56 China — full list on the source page).

### Special plate layouts (from scanned sample sheet)

| Plate | Layout | How the app reads it |
|---|---|---|
| UN | የተመ · number (7) · U/N stacked, light blue | Stack read `UN`; else no circle + Ge'ez word + no Ge'ez stack + 7 digits → `UN`. Section 1 shows የተመ, section 2 empty |
| AU | አሕ · number (7) · `AU` **side by side**, light green | Letters read `AU`; else no circle + Ge'ez word + letters side by side → `AU`. Section 1 shows አሕ, section 2 empty |
| Diplomatic | embassy no. (big, 2 digits, **no circle**) · Ge'ez · number (**4**) · C/D stacked on a yellow strip | No circle + two big digits left of the Ge'ez → code `CD` even when C/D is misread (section 4 shown as `CD`, "by layout"); else stack `CD`. Embassy number read alone and as one word, looked up |
| Police | ፖሊስ · Ge'ez stack · number (6) · region stacked, **yellow** plate | Yellow background → `POLICE`; else no circle + Ge'ez word + Ge'ez stack in dark ink → `POLICE`. Section 1 shows ፖሊስ |
| Temporary | ተላላፊ · Ge'ez stack · number (6) · region stacked, light blue on white | No circle + Ge'ez word + Ge'ez stack in blue ink → `TEMP`. Section 1 shows ተላላፊ |

A "Ge'ez word" is two or more letter-sized shapes (0.3–0.6 of a digit)
spanning at least 1.5 digit pitches where the circle would be (words in the
logs span 1.7–3.3); a broken circle or a cut stack is not one. Section 4
naming a region rules out UN and AU.

## Old two-row plates

Same four sections as the one-row plate, on two rows:

| Row | Content |
|---|---|
| Top | ① circle · two Ge'ez letters **side by side** (ከ ከ, ኢ ት) · chip · two Latin letters **side by side** (AA, ET, OR) |
| Bottom | The number alone, large: 5 digits (`04765`) or letter + 5 digits (`A45699`) |

How the app reads them:

- **Snapping**: four or more letter-sized shapes level with each other
  (along the digits' tilt) just above the digit row mark a two-row plate;
  the top edge is searched above that row, the box spans it left to right,
  and the proportions are 1.5–2.8 : 1.
- **Segmentation**: the digits in the lower part of the crop and a row of
  circle + four letters above them (`twoRow`). The circle and letters are
  taken left to right; Ge'ez and Latin letters come out side by side. The
  border clean-up is retried keeping rows broken by gaps, since the big
  digits fill most of the plate's width.
- **Reading**: the number crop isn't bounded by the region letters (they are
  above it); the Latin letters are read as a word; the reading's layout is
  `twoRow`.

Not handled: plates photographed sideways (they need rotating first), and
blurry or strongly tilted shots where the top row isn't found (the number
is then read with a one-row guess).

## New national plate (from June 2026)

Directive No. 1050/2025 (Ministry of Transport and Logistics) replaces the
regional plates with one national format. Issued in Addis Ababa from
11 June 2026 to newly registered vehicles first; existing vehicles move over
later (reported 3–6 months), so **old and new plates are on the road
together**.

| Part | Content | How the app reads it |
|---|---|---|
| Left | ኢት over ETH, map of Ethiopia, QR code | Section 1 = `ETH`, shown as ኢት |
| Number | Three Latin letters, four digits (`ABC1234`); pale green, hatched with micro-text; the 0 is notched | See below |
| Region | None (no circle, no Ge'ez / Latin region) | Sections 2 and 4 empty, "none on ETH plates"; no missing-region issue |

The plate's characters are pale and hatched, so they break apart in the
image (snapping and segmentation fail), and the notched 0 is read as G, O
or D ("AAAGG0O"). The app therefore:

- **live**: anchors on a line of three letters and four digit-like
  characters (0–9, O, Q, D, G, C), and frames the plate from that line
  alone (ኢት block on the left ≈ 0.3 of its width); no outline snapping;
- **reading**: takes the number from the whole-area OCR line (letters kept,
  G / O / D / Q / C → 0 in the digits). All three leading characters must be
  read as letters and one must not be a digit look-alike, because old
  `C06703` plates misread as `CO67038` / `OCO670` (and carrying a small
  "ETH") would match otherwise. Motorcycles' reported three-digit form is
  not accepted until confirmed.

Not confirmed yet: the category colours (the directive reportedly keeps
"only three colours"; earlier reports list black = private, green =
commercial / electric, red + "Taxi" = taxi, orange = civic; government by
institution name; tags such as CD, AO, PD, SME; "Green Transport" on
electric vehicles), and how police, UN, AU, diplomatic and temporary plates
look under the new system. The category is therefore not set from colour.
Personalised numbers are allowed and may not follow `ABC1234`.

Sources: The Reporter (thereporterethiopia.com/51124, /47371), Ethiopian
Business Review, ENA (ena.et eng_7482891), Ethiopiauto, 2merkato, Capital.

## Regions

| Region | Latin | Ge'ez |
|---|---|---|
| Ethiopia (federal) | ET | ኢት |
| Addis Ababa | AA | አአ |
| Afar | AF | አፋ |
| Amhara | AM | አማ |
| Benishangul Gumuz | BG | ቤጉ |
| Dire Dawa | DR | ድሬ |
| Gambela | GM | ጋም |
| Harar | HR | ሐረ |
| Oromia | OR | ኦሮ |
| Somali | SM | ሶማ |

Not on the source page, kept unverified in `ethiopian_region.dart`: Tigray
(TG), Sidama (SD), former SNNP (SP), South West (SW), and the alias OM for
Oromia.

## Open questions

- [ ] Codes for Tigray, Sidama, South West, Central and South Ethiopia.
- [ ] Number length per plate generation (5 on older, 6–7 on newer?).
- [ ] Layout of special (UN, AU, police, temporary, embassy) plates.
