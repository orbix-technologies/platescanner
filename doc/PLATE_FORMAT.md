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
| UN | የተመ · number (7) · U/N stacked, light blue | Latin stack `UN` → code `UN`, no region |
| AU | አሕ · number (7) · `AU` side by side | Latin letters `AU` → code `AU` |
| Diplomatic | embassy no. (big, 2 digits) · Ge'ez · number (**4**) · C/D stacked | Stack `CD` → code `CD`, 4-digit number, embassy looked up |
| Police | ፖሊስ · Ge'ez · number (6) · region stacked, **yellow** plate | Yellow background → code `POLICE` |

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
