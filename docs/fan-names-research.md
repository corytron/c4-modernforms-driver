# Fan marketing names from the model data

Research for [issue #37](https://github.com/corytron/c4-modernforms-driver/issues/37),
written 2026-11-04. Desk research on public web pages only: no fan, controller
or other device on the house network was contacted, no login was used, no
licence or terms were accepted, and WAC's API reference PDFs were not opened
(the project stays off WAC's API License Agreement; search-engine summaries of
them were seen and not relied on; what `fanType` is comes from
[`modernforms-api-research.md`](modernforms-api-research.md) section 2.4 and
from the evidence below). Everything is in the author's own words; model
numbers and product names are facts. No private value appears here.

**Status key**, as in [`modernforms-api-research.md`](modernforms-api-research.md):
**[verified: source]** was read in the source named at the claim;
**[assumed: why]** is inferred and not confirmed. As in the project's key, what
a user's dump on GitHub or a forum says about their own fan is a *field
report*: that it was posted is verified, that it is true of the fan is
assumed. A claim resting on a search engine's summary or on a URL seen in a
result list, with the page itself not opened (several retailers answer
automated requests with 403), says so and is marked **r**.

## Summary

1. **Yes: the family name can be derived from `fanType` alone, with a lookup
   table.** `fanType` is the maker's model code of the fan without the
   `FR-W` / `FH-W` prefix, the light-kit letter and the finish: a four-digit
   family number, an optional blade-count marker and the blade span in
   inches (section 2). The family number is the design (1811 Aviator, 2006
   Zephyr, 1801 Wynd), the last number the size. Six fan-side values (the
   house's and five from public reports and fixtures) all fit the grammar and
   resolve to a product (section 2); only one owner named the product, so the
   other rows rest on the grammar [assumed].
2. **The house fan's `1811-5-54` is the Aviator 5: the five-blade Aviator,
   54 inch.** The maker's spec sheets are named `FR-W1811-5-54` and
   `FH-W1811-5-54`, ENERGY STAR lists "AVIATOR 5 - 54", and its motor code
   `DC125X20` matches the spec sheet's "125 x 20" motor. Confidence high
   (near 95 %); the residual risk is that this one fan was never compared
   with its box. `fanType` cannot say downrod (FR) or flush mount (FH): both
   are the same design with the same code.
3. **50 Modern Forms families** (75 `fanType` strings, Appendix B) are listed
   in section 3, 2018 to 2026, current and retired, each with its page on
   modernforms.com. WAC's own "WAC Smart Fans" use another numbering
   (`F-0nn`); 23 names are listed, but no `fanType` of such a fan is public.
4. **`brand` does not distinguish a name**: the three real Gen 3 dumps in
   public (the house's and two field reports) say 1 and are Modern Forms
   fans. Keep the brand out of the name.
5. **`lightType` cannot name a light kit**: one code covers three different
   designs. Show it raw.
6. **No open-source integration maps `fanType` to a name.** Home Assistant
   shows the raw string as the device model (section 6).
7. **Recommended**: exact-match table only; device name `Aviator 5` (ASCII,
   no brand, no inch sign); `Fan Model` row `Gen 3, Aviator 5 (1811-5-54),
   light kit F4IN-120V-R1-30, Breeze` (63 characters); an unknown `fanType`
   keeps today's text and is never renamed (section 7).

## 1. What the fan reports

From the static shadow (`{"queryStaticShadowData":1}`; the house values are
in `tests/fixtures/mf_gen3.lua` L135-L139): `lightType`
`F4IN-120V-R1-30`, `fanType` `1811-5-54`, `fanMotorType` `DC125X20`, `brand`
`1`, `deviceName` (what the owner typed in the vendor app, a private value:
dropped on receipt by `docs/v1-design.md` V20). Nothing in the answer is a
marketing name [verified: the fixture]. The vendor's own app does not show one
either: a Radiant owner says it reports the model number as `2603-56` [field
report: AIO-ISS #287, comment of 2026-07-31]. Gen 1/2 answers also carry
`productSku` and `productionLotNumber`, empty in the two public fixtures
[verified: AIO `tests/test_aiomodernforms.py` L155-L156; HA `device_info.json`].

## 2. How `fanType` is built

**Grammar** (checked against every value below with Lua 5.1 patterns
`^(%d%d%d%d)%-(%d%d?%d?)$` and `^(%d%d%d%d)%-(%d)%-(%d%d?%d?)$`):

| Part | Meaning | Evidence |
| --- | --- | --- |
| first 4 digits | model family: the number inside `FR-W####`, `FH-W####` and `FR-D####` model codes; the design, not the size or the mount | [verified: maker spec-sheet names, ENERGY STAR model numbers, the pairs below] |
| first 2 of them | the design year (18 = 2018 ... 26 = 2026) | [assumed: ENERGY STAR "available on market" dates of the 35 families found there rise with the number, 1801 = 2018-08, 2006 = 2020-09, 2601 = 2026-02, 2606 = 2026-07] |
| middle digit, only sometimes | a blade-count marker; in the whole catalogue only the five-blade Aviator has one (`1811-5-54`, against the three-blade `1811-54`); Zephyr 5, Mykonos 5 and Smooth 5 are separate families | [verified: the 72 spec-sheet names, 90 fan pages, the 2019 catalogue and 243 ENERGY STAR records were scanned for a third segment] |
| last number | the blade span in inches, as in the model code without the `L` (light) letter | [verified: spec sheets state the sweep, e.g. 54" for `FR-W1811-5-54`; ENERGY STAR "Blade Span" agrees] |

Not in it: mount (FR downrod and FH flush share a code), light kit (`L`),
finish, colour temperature. Gen 4 fans put the same grammar in the fixture's
`model` field (`2603-56`: [field report: HA-ISS #169247]; the library copies
that field into `fan_type`, [verified: AIO `gen4.py` L188]).

**Fan-side values against products** (the maker's and ENERGY STAR's side is
verified in every row; the fan side is a field report unless it says house):

| `fanType` | Seen where | Product | Evidence for the product |
| --- | --- | --- | --- |
| `1811-5-54` | the house fan, Gen 3, firmware 02.00.0052 (read-only query, M0) | Aviator 5, 54 in | spec sheets `FR-W1811-5-54_SPSHT.pdf` and `FH-W1811-5-54_SPSHT.pdf` titled "Aviator 5"; ES pd_id 2366495 and 2366677 [verified]; that the fan is one [assumed: same grammar] |
| `2603-56` | Gen 4 Radiant owner: fixture `detail.model` and the app (HA-ISS #169247; AIO-ISS #287, comment of 2026-07-31) | Radiant 56 | the owner names the model; spec sheet `FR-D2603-56_SPSHT.pdf` [verified] |
| `2006-52` | AIO-ISS #272, comment of 2026-07-28: Gen 3, firmware 02.00.0043, dateCode 2022-11-17, `brand` 1 | Zephyr 52 | spec sheet `FR-W2006-52_SPSHT.pdf`, ES pd_id 2366931 [verified]; the owner did not name it [assumed] |
| `1801-60` | AIO-ISS #88, comment of 2021-11-06: Gen 3, firmware 02.00.0026, `brand` 1 | Wynd 60 | spec sheet `FR-W1801-60_SPSHT.pdf`, ES pd_id 2359773 [verified]; owner silent [assumed] |
| `1818-56` | HA `tests/components/modern_forms/fixtures/device_info.json`; AIO tests L153: Gen 1/2, firmware 01.03.0025 | Nautilus 56 | spec sheet `FR-W1818_SPSHT.pdf` [verified]; fixture possibly edited [assumed] |
| `2003-52` | AIO tests L170, no light kit | Slim 52 | ES pd_id 2358765 [verified]; synthetic (its dateCode `20220101` is not the format real fans send) [assumed] |

Generation is not a function of the model: family 1801 appears on firmware
01.03.0025 (a Wynd 42, HAF #88 of 2021-05-05) and on 02.00.0026 (the
`1801-60` above) [assumed: two field reports]. Read the generation from the
answer (timer keys, firmware), as [`modernforms-api-research.md`](modernforms-api-research.md)
section 1 does. Spec-sheet text is inconsistent in the sweep line (Lotus 56
against model 54, Hydra 96 against 120, Roboto 62 against 52); the model
codes and ENERGY STAR diameters agree with each other, so keys are built from
those.

## 3. The families

Every row is the maker's own page: `https://modernforms.com/product/<slug>/`
(read 2026-11-04). The list was enumerated from the site's public REST feed
(categories 115 downrod and 116 flush mount, 79 pages), then every other
product page (691 in the sitemap, throttled, no login) was scanned for fan
model codes, which added 11 retired or mis-filed fan pages; every
spec-sheet name below exists at
`https://modernforms.com/images/products/SPECSHEET_PDF/<name>_SPSHT.pdf`.
Columns: **Mnt** R = downrod (FR-) page, H = flush-mount (FH-) page.
**Blades** a = stated on the maker's page, r = a retailer title or URL seen in
a search result, `-` = no source read. **Status** from the site's per-model
notes: listed (none), limited ("limited availability, consult factory"),
retired ("Retired"). **Sources**: SS = spec sheet; ES-N = ENERGY STAR open data
(dataset 2te3-nmxp, 243 WAC/Modern Forms records) has the same model numbers
and the same marketing name (28 families), ES# = model numbers only (7); 19 =
the 2019 catalogue lists it; F4 = the page sells an "F4-" remote (see the
note under the table). A name in parentheses is the maker's name when it has
no size; the `fanType` is then `family-size`.

| Family | Names by size | Mnt | Blades | Status | Sources (slug; SS; checks) |
| --- | --- | --- | --- | --- | --- |
| 1801 | Wynd 42, Wynd 52, Wynd 60 | R | 42: 5r | listed | wynd-42, -52, -60; SS FR-W1801-42/52/60; ES-N; 19 |
| 1802 | Vox 26, Vox 38 (the downrod 38 was "Elf" in 2019) | R H | - | flush listed, downrod limited | vox-26, vox-38, vox-26-2, elf; SS FH-W1802-26/38, FR-W1802-26, FR-W1802; ES-N; 19 |
| 1803 | Axis 44, Axis 52 | R H | 52: 3r | listed | axis-44, axis-52, axis-44-flush, axis-52-flush; SS FR/FH-W1803-44/52; ES-N; 19 |
| 1804 | Stargazer (52) | R | - | listed | stargazer; 19 |
| 1805 | Hydra 80, Hydra 96, Hydra 120 | R | - | limited | hydra-80, -96, -120; SS FR-W1805-80/96/120; 19 |
| 1806 | Cervantes (56) | R | 4r | retired | cervantes; 19 |
| 1807 | Aloft (44) | H | - | listed | aloft; 19 |
| 1809 | Lotus (54) | R | - | listed | lotus; SS FR-W1809; ES-N; 19 |
| 1810 | Vortex (60) | R | - | limited | vortex; SS FR-W1810; 19 |
| 1811 | Aviator 54 (`1811-54`), Aviator 5 (`1811-5-54`), Aviator 70 (`1811-70`) | R H | 54: 3r; Aviator 5: 5r | listed, 70 limited | aviator, aviator-54-5, aviator-70, aviator-flush, aviator-5-flush; SS FR/FH-W1811-54, FR/FH-W1811-5-54, FR-W1811-70; ES-N; 19 (3-blade only) |
| 1812 | Morpheus II (60) | R | - | retired | morpheus-ii; 19 |
| 1813 | Morpheus III (60) | R | 2-3a | limited | morpheus-iii; SS FR-W1813; ES#; 19 |
| 1814 | Woody 60, Woody 72 | R | - | 60 limited, 72 retired | woody-60, woody-72; SS FR-W1814-60; ES#; 19 |
| 1815 | Windflower 60, Windflower 80 | R | - | limited | windflower-60, -80; SS FR-W1815-60/80; 19 |
| 1816 | Orb 62, Orb 82 | R | - | listed | orb-62, orb-82; 19 |
| 1817 | Osprey (56) | R | - | retired | osprey; 19 |
| 1818 | Nautilus (56) | R | - | retired | nautilus; SS FR-W1818; 19 |
| 1819 | Mykonos (52) | R | 3r | listed | mykonos; SS FR-W1819; ES-N; 19 |
| 1910 | Roboto 52, Roboto 62 | R | - | listed | roboto-52, -62; SS FR-W1910-52/62; ES-N; 19 |
| 1916 | Nirvana (56) | R | - | retired | nirvana; 19 |
| 1920 | Venus (60) | R | - | retired | venus; 19 |
| 1922 | Paradox (56) | R | - | retired | paradox; 19 |
| 2001 | Renegade 52, Renegade 66 | R | - | limited | renegade-52, -66; SS FR-W2001-52/66; ES-N |
| 2003 | Slim (52) | R H | 3r | retired | slim, slim-flush; ES-N |
| 2004 | Tip Top 44, Tip Top 52 | H | - | listed | tip-top-44, -52; SS FH-W2004-44/52; ES-N |
| 2006 | Zephyr 52, Zephyr 62, Zephyr 72 | R | 52: 3r (page: "two or three") | listed | zephyr-52, -62, -72; SS FR-W2006-52/62/72; ES-N |
| 2008 | Mykonos 5 (60) | R | 5a | listed | mykonos-5; SS FR-W2008; ES-N |
| 2101 | Wynd XL (72) | R | - | listed | wynd-xl; SS FR-W2101; ES-N |
| 2102 | Ultra (54, UV-C) | R | - | retired | ultra |
| 2103 | Twirl (58) | R | - | retired | twirl; ES-N |
| 2201 | Wyndmill (65) | R | 12r | limited | wyndmill; SS FR-W2201; ES-N |
| 2202 | Skylark 54, Skylark 62 (Skylark Flush is 54) | R H | - | listed | skylark-54, -62, skylark-flush; SS FR-W2202-54/62, FH-W2202; ES-N |
| 2203 | Corona 44, Corona 52 | H | - | listed | corona-44, -52; SS FH-W2203-44/52; ES-N |
| 2204 | Torque 58, Torque 70 | R | - | limited | torque, torque-70; SS FR-W2204-58/70; ES-N |
| 2301 | Roboto XL (70) | R | - | limited | roboto-xl, roboto-xl-with-luminaire; SS FR-W2301-70/70L; ES-N |
| 2303 | Aura 60, Aura 72 | R | 8 (spec sheet) | listed | aura-60, aura; SS FR-W2303-60/72; ES-N |
| 2304 | Lucid (62) | R | - | limited | lucid-3; SS FR-W2304; ES-N |
| 2401 | Zephyr 5 (62) | R | 5a | listed | zephyr-5; SS FR-W2401; ES# |
| 2402 | Veloce (28) | H | - | listed | veloce-smart-fan; SS FH-D2402 |
| 2403 | Size Matters 56, 65, 84 | R | 8a | listed | size-matters-56, -65, -84 (each also "with luminaire"); SS FR-W2403-56/65/84; ES-N |
| 2404 | Spinster (60) | R | 3a | listed | spinster; SS FR-W2404; ES# |
| 2501 | Bolo (56), Bolo 62 | R | 3a | listed | bolo, bolo-62; SS FR-W2501, FR-W2501-62L; ES-N |
| 2502 | Smooth (52) | R H | 3a | listed | smooth, smooth-flush; SS FR-W2502, FH-W2502-52; ES# |
| 2503 | Pisces (54) | R | 3a | listed | pisces-5; SS FR-W2503; ES# |
| 2504 | Carve 60, Carve 72 | R | 3a | listed | carve-60, carve-72 (each also "with luminaire"); SS FR-D2504-60/72; ES# |
| 2601 | Smooth 5 (56) | R | - | listed | smooth-5; ES-N |
| 2602 | Crown (62) | R | - | listed | crown; SS FR-D2602-62; ES-N; F4 |
| 2603 | Radiant 56, Radiant 64 | R | 56: 5r | listed | radiant-56, -64; SS FR-D2603-56/64; ES-N; F4 |
| 2605 | Chill (54) | R | - | listed | chill-2; SS FR-W2605; ES-N; F4 |
| 2606 | Spoke (60) | R | 5a | listed | spoke; SS FR-W2606; ES-N; F4 |

Status counts (a family is retired when all its pages say so, limited when
any page does): 28 listed, 12 limited, 10 retired. Names and sizes are
[verified: the pages above]; that a real fan of that family reports
`family-size` is [assumed: the grammar of section 2], except the six values
in that section. Families the author could not find anywhere: 1808, 2002,
2005, 2007, 2302, 2604 and the numbers above 2606; a `fanType` from one of
them is simply unknown. "Custom Smart Fans" (the maker's custom programme) may
carry other codes [assumed]. **Generation** cannot be put in the table (section
2); a hint only: the pages of 2602, 2603, 2605 and 2606 are the only ones that
sell the "New Generation" remotes with an "F4-" part number, and Radiant is
the one confirmed Gen 4 in the field [field reports: AIO-ISS #287; HA-ISS
#169247]; that the other three are Gen 4 too is [assumed]. The D in `FR-D` / `FH-D`
(2102, 2402, 2504, 2602, 2603) has no stated meaning and does not track Gen 4
(Ultra, 2021, is older than Gen 4) [assumed].

### WAC-brand smart fans (numbers `F-0nn`)

WAC's own "WAC Smart Fans" speak the same local API: owners report it for
2020 and for 2024 and later [assumed: field reports HAF #34 of 2020-06-17,
#111 of 2024-05-31, #117 of 2024-12-10], and the client id of such a fan starts with
`WAC_` instead of `MF_` ([`modernforms-api-research.md`](modernforms-api-research.md)
section 2.4). Their numbers are not four-digit families, so no `fanType` of
one is known and none can be derived. Names and sizes from ENERGY STAR (brand
WAC or WAC Lighting; the name is from retailer titles, **r**, where ES says
only "Ceiling Fan"); which of them are Wi-Fi fans is established only where
a listing says "smart" or ES says "Bluetooth, Wi-Fi" (F-036L, F-101, F-102).

| Number | Name, size in inches |
| --- | --- |
| F-001, F-001L | Mocha 54; F-064, F-064L Mocha XL 66 |
| F-003L (r) | Clean 52 |
| F-004L | Orb 44 (a second "Orb": Modern Forms has an Orb 62 and 82) |
| F-005L, F-034L, F-035L | Odyssey 52, Odyssey Flush 44, Odyssey Flush 52 |
| F-036L, F-037L | Hug 44 (r), Hug 52 |
| F-053L, F-054L | Eclipse 54; "Mod" 54 (ES lists F-054L under brand Modern Forms) |
| F-056, F-056L | Stella 60 |
| F-060, F-060L | Blitzen 54 |
| F-070L, F-071L | Sonoma 56; Viper 60 |
| F-072L, F-073L | Atlantis 52; Atlantis Flush 52 |
| F-074L, F-080L | Swirl 54; Windmill 65 (near-homonym of Wyndmill) |
| F-081L to F-084L | San Francisco 52 downrod, 52 flush, 44 downrod, 44 flush |
| F-088L, F-110, F-111 | Zelda 60; Ferris 52; Zeke 60 |
| F-099L, F-101, F-102, F-103 to F-109 | unnamed in ES: 65, 65, 84, then 44 to 56 |
| (number unknown) | Novelle 52, Gage 52, Rotary 65, Malibu 70 (r, retailer titles) |

## 4. Brand

- `brand` is 1 in the three real Gen 3 dumps in public: the house Aviator 5
  [verified] and two field reports (`2006-52`, `1801-60`), all Modern Forms
  products with `MF_` client ids. AIO's fixture has `brand` 0 next to an
  `MF_` id, but it is synthetic [assumed, see section 2]. The project's own research
  records a documented range of 0 to 2 without meanings
  ([`modernforms-api-research.md`](modernforms-api-research.md) section 2.4);
  what 0 and 2 stand for is unknown [assumed: perhaps WAC and another brand].
- Home Assistant ignores it and hard-codes the manufacturer `Modern Forms`
  [verified: HA `entity.py` L55].
- **Name rule**: look the name up by `fanType` alone (the numbering is
  Modern Forms', so the brand adds nothing) and never put the brand in the
  device name: the driver is already "Modern Forms Fan", and the family names
  are unique inside the line. Show `brand` raw in a property if wanted. A
  WAC-brand fan, once a sample exists, would need the prefix `WAC` because
  names collide across brands (Orb above).

## 5. Light kits

- Public `lightType` values: `F4IN-120V-R1-30` on three different designs
  (Aviator 5, `2006-52`, `1801-60`), `F6IN-120V-R1-30` on the `1818-56`
  fixture, empty without a kit [verified: the house fixture; field reports
  and fixtures of section 2].
- No public document defines the code. Its shape reads as `F<n>IN`,
  voltage, revision `R1`, and a final number that matches the 3000 K default
  of the kits (the maker's SKUs insert `27` and `35` for 2700 K and 3500 K)
  [assumed: pattern only, four samples]. The kit sold for the Aviator 5 has
  its own accessory number (`F-1811-5-LED-**`, [verified: its spec sheet]),
  which is not in the code.
- **Conclusion**: nothing maps it to a kit name; show it raw as today.

## 6. Open-source prior art

| Project | What it does with `fanType` | Source |
| --- | --- | --- |
| Home Assistant `modern_forms` | device model = the raw string; manufacturer fixed `Modern Forms` | `entity.py` L55-L56 at core `e1bc462` (2026-11-02) |
| `aiomodernforms` (e572e78) | reads it into `Info.fan_type` unchanged; Gen 4: copies the fixture `model` | `models.py` L78, L98; `gen4.py` L188; constants `const.py` L66-L68, L87 |
| AIO mock fan and tests | sample values only: `1818-56`, `2003-52`, `2006-52` | `mock_fan/generations.py` L47, L73; `tests/test_aiomodernforms.py` L153, L170 |
| Homey app | declares the field, never uses it; names a device by `deviceName` | `src/models/FanStaticData.ts` L6; `src/services/DiscoveryService.ts` L30 |
| pypi-modernforms | uses its presence only to know the static shadow was read | `modernforms/modernforms_fan.py` L194-L195 |
| mf-mqtt | publishes the model as `N/A`; its `info.model` is never set | `homeassistant/type-mf-fan.js` L15 |
| Homebridge (two), Hubitat (two), `ha-modernforms`, `mffprober` | do not read the static shadow | grep of the nine repositories at the commits `modernforms-api-research.md` lists |

Nobody maps it to a name. No table from model code to name is published by
the maker or by open code either: section 3 had to be assembled from the
maker's product pages and spec-sheet names, with ENERGY STAR as the check.

## 7. Recommendation for the driver

**Rule.** A new module `src/modernforms_fan/fan/names.lua` and its spec:

```lua
-- exact fanType -> the maker's catalogue name; the full seed is Appendix B
return { ["1811-5-54"] = "Aviator 5", ["1811-54"] = "Aviator 54", ["2006-52"] = "Zephyr 52", ["1801-60"] = "Wynd 60" }
```

1. Trim `fan_type`; accept only the two patterns of section 2; anything else
   (empty, `FR-W...`, an `L` suffix, a finish) is unparsable. Look up the
   exact string. A hit gives the name; a miss gives no name.
2. Never guess: no fuzzy matching, no stripping segments to find a near key,
   no name from the brand, the generation, `lightType` or `deviceName`. An
   optional second map family to design name (`["2006"] = "Zephyr"`) may feed
   the property text only (`Zephyr family, 40 in (2006-40)`), never a rename.
3. **Display strings**, all ASCII: `Fan Model` with a hit
   `Gen 3, Aviator 5 (1811-5-54), light kit F4IN-120V-R1-30, Breeze`
   (63 characters; the longest catalogue name, Size Matters 84, gives 67, under
   the 70 characters of `docs/v1-design.md` section 2.5); a miss keeps today's text
   `Gen 3, fan 9999-5-120, light kit F4IN-120V-R1-30, Breeze`
   (`fan/texts.lua` L265-L288). The raw model stays in the row, so the table
   is checkable by eye.
4. **Device name for the rename**: `Aviator 5` for the fan and `Aviator 5
   Light` for the light. The maker's names already carry the size where the
   maker uses one (`Wynd 60`, `Radiant 56`), so no size suffix is added and
   two sizes of one design stay distinct. No brand. **No inch sign**: the
   sign is a double quote, which is legal XML but breaks quoting wherever a
   name is pasted into a script, an export or a comma-separated property
   list (the project already avoids commas in names, `docs/v1-design.md`
   section 2.5), and the typographic signs are non-ASCII, which the texts rule
   forbids (`fan/texts.lua` L18) [assumed: no Composer rule read]. If a long
   form is wanted in a property, write `54-inch` or `54 in`.
5. **When to rename**: only on the owner's `Use Selected Fan` click, only if
   the device name is still the default (`Modern Forms Fan`, `docs/v1-design.md`
   section 2.2), never over a name the owner chose, once. Row D15 of
   `docs/edge-cases-control4.md` marks a rename by the driver as forbidden
   (the name is the owner's; each `RenameDevice` call refreshes the whole
   project); the owner's request for this feature is the exception, kept to
   one click. A miss never renames.
6. **Keeping the table**: a Lua table in the driver, changed only by a later
   build (the driver reads no website). The spec asserts: every key matches
   the grammar; names are ASCII and at most 20 characters; the canary
   `1811-5-54` is `Aviator 5`. New rows come from unknown `fanType` strings
   that owners report (the `Fan Model` row and the debug log show it) and
   from the maker's feed (Appendix A). Seed it with Appendix B, the 75
   strings of section 3; cite this document and the retrieval date in a
   comment, not the maker's text. Aliases (Vox 38 was "Elf") stay in that
   comment, not in the table.
7. **Unknown or foreign**: Gen 4 keeps its "not supported" status; WAC-brand
   and unlisted fans keep the raw model and are not renamed.

## 8. Open questions

1. Name form: `Aviator 5` / `Aviator 5 Light`, or with the word "Fan"
   (`Aviator 5 Fan`)? The driver does not know the room [assumed], so a
   room prefix is the owner's to add.
2. Is the D15 exception (rename on the `Use Selected Fan` click, from the
   default name only) acceptable, and does the light child rename with it?
3. Does the house fan's nameplate or box say Aviator 5, and FR or FH? That
   settles the one unverified step and the mount.
4. Where do owners report an unknown `fanType` (an issue template)? The
   driver could print a ready line for it.
5. WAC-brand and Gen 4 names: wait for a sample, or list the Gen 4
   families anyway for the property text?
6. Product names are the maker's trademarks; the table uses them nominatively.
   Do the `NOTICE` and the manual's non-affiliation line cover it?
7. Not found: a definition of `lightType`; a statement of how `fanType` is
   built outside WAC's API reference (not opened here; the project's research
   cites its page 8); whether the `fanType` of a "Custom Smart Fan" differs.

## Appendix A: reproducing the lists (2026-11-04)

```
curl -s 'https://modernforms.com/wp-json/wp/v2/product?product_cat=115&per_page=100&_fields=slug,title,link'   # downrod fans
curl -s 'https://modernforms.com/wp-json/wp/v2/product?product_cat=116&per_page=100&_fields=slug,title,link'   # flush-mount fans
curl -sG 'https://data.energystar.gov/resource/2te3-nmxp.json' --data-urlencode "\$limit=2000" \
  --data-urlencode "\$where=upper(brand_name) like '%MODERN FORMS%' or upper(energy_star_partner) like '%WAC%'"
```

The first two list the maker's fan pages (retired fans filed under lighting
categories need the page scan of section 3); the ENERGY STAR set lists
certified models only (rows last updated 2026-11-04 per the dataset's
metadata, newest record read dated 2026-07), so a brand-new family can be
missing there. Not used: C4Forums, WAC's support site and the retailers that
refused automated access (Ferguson, Zoro): their model strings appear here
only as URLs or titles seen in search results, marked **r**.

## Appendix B: seed table (75 strings, ASCII, names at most 15 characters)

Generated from section 3 (Lua syntax, tabs). The six values of section 2 are
observed; the others follow from the grammar [assumed].

```lua
return {
	["1801-42"] = "Wynd 42", ["1801-52"] = "Wynd 52", ["1801-60"] = "Wynd 60", ["1802-26"] = "Vox 26",
	["1802-38"] = "Vox 38", ["1803-44"] = "Axis 44", ["1803-52"] = "Axis 52", ["1804-52"] = "Stargazer",
	["1805-80"] = "Hydra 80", ["1805-96"] = "Hydra 96", ["1805-120"] = "Hydra 120", ["1806-56"] = "Cervantes",
	["1807-44"] = "Aloft", ["1809-54"] = "Lotus", ["1810-60"] = "Vortex", ["1811-54"] = "Aviator 54",
	["1811-5-54"] = "Aviator 5", ["1811-70"] = "Aviator 70", ["1812-60"] = "Morpheus II", ["1813-60"] = "Morpheus III",
	["1814-60"] = "Woody 60", ["1814-72"] = "Woody 72", ["1815-60"] = "Windflower 60", ["1815-80"] = "Windflower 80",
	["1816-62"] = "Orb 62", ["1816-82"] = "Orb 82", ["1817-56"] = "Osprey", ["1818-56"] = "Nautilus",
	["1819-52"] = "Mykonos", ["1910-52"] = "Roboto 52", ["1910-62"] = "Roboto 62", ["1916-56"] = "Nirvana",
	["1920-60"] = "Venus", ["1922-56"] = "Paradox", ["2001-52"] = "Renegade 52", ["2001-66"] = "Renegade 66",
	["2003-52"] = "Slim", ["2004-44"] = "Tip Top 44", ["2004-52"] = "Tip Top 52", ["2006-52"] = "Zephyr 52",
	["2006-62"] = "Zephyr 62", ["2006-72"] = "Zephyr 72", ["2008-60"] = "Mykonos 5", ["2101-72"] = "Wynd XL",
	["2102-54"] = "Ultra", ["2103-58"] = "Twirl", ["2201-65"] = "Wyndmill", ["2202-54"] = "Skylark 54",
	["2202-62"] = "Skylark 62", ["2203-44"] = "Corona 44", ["2203-52"] = "Corona 52", ["2204-58"] = "Torque 58",
	["2204-70"] = "Torque 70", ["2301-70"] = "Roboto XL", ["2303-60"] = "Aura 60", ["2303-72"] = "Aura 72",
	["2304-62"] = "Lucid", ["2401-62"] = "Zephyr 5", ["2402-28"] = "Veloce", ["2403-56"] = "Size Matters 56",
	["2403-65"] = "Size Matters 65", ["2403-84"] = "Size Matters 84", ["2404-60"] = "Spinster", ["2501-56"] = "Bolo",
	["2501-62"] = "Bolo 62", ["2502-52"] = "Smooth", ["2503-54"] = "Pisces", ["2504-60"] = "Carve 60",
	["2504-72"] = "Carve 72", ["2601-56"] = "Smooth 5", ["2602-62"] = "Crown", ["2603-56"] = "Radiant 56",
	["2603-64"] = "Radiant 64", ["2605-54"] = "Chill", ["2606-60"] = "Spoke",
}
```
