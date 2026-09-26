# WeatherFlow PiConsole patches

Local patches for the [WeatherFlow
PiConsole](https://github.com/peted-davis/WeatherFlow_PiConsole),
plus the machinery to keep them applied across updates.

Three of them are bugs in the console rather than configuration
problems, and none shows an error on screen. One makes every
circular gauge draw as an oval. One makes a station in UDP mode
display wind and nothing else. One makes the Sager forecaster fail
on clear days, which around here is most of them. The rest are
appearance: precision the sensor cannot actually support, and
colour.

Every patch can be switched on or off, and switching one off
**reverts** it rather than merely leaving it in place.

Tested against v26.4.2 on a Raspberry Pi 4 running 64-bit Raspberry
Pi OS Trixie, driving a 10.1 inch 1280x800 panel, with a Tempest on
a UDP connection.

---

## What's in here

| Patch | Files | Default | What it does |
|---|---|---|---|
| `square-dials` | `kvlang/layout.kv` | on | Keeps the wind, moon and barometer dials circular on displays that are not 5:3 |
| `udp-obs-length` | `lib/observation_parser.py` | on | Stops an `IndexError` that kills the parser thread on every UDP observation |
| `sager-metar-clouds` | `lib/sager.py` | on | Stops the Sager forecast failing whenever nearby stations report clear skies |
| `pressure-precision` | `lib/observation_format.py` | on | Pressure to two decimals rather than three |
| `temp-whole-degrees` | `lib/observation_format.py` | **off** | Rounds temperature to whole degrees. Conflicts with `temp-decimal-size` |
| `temp-decimal-size` | `kvlang/temperature.kv` | on | Draws the decimal smaller, the unit small and raised, and tints both by value |
| `peak-sun-precision` | `lib/observation_format.py` | on | Peak Sun Hours to one decimal rather than two |
| `panel-accents` | `kvlang/*.kv` | on | Gives each panel heading its own colour |

---

## Install

```
bash install-wfpiconsole-patches.sh
```

Run it as your normal user, not with `sudo` — it calls `sudo` where
it needs to. It installs:

```
/usr/local/bin/wfpiconsole-patches       the patches, idempotent
/etc/wfpiconsole-patches.conf            on/off and tuning
wfpiconsole-patches.path / .service      re-run when PiConsole's files
                                         change, i.e. after an update
wfpiconsole.service.d/patches.conf       re-run before every autostart
```

Nothing is placed inside `~/wfpiconsole`, so `wfpiconsole update`
cannot remove any of it.

### Updating

Two different things, and the distinction matters:

- **Changed a setting in the conf file?** Run the installed copy:
  `sudo wfpiconsole-patches ~/wfpiconsole`
- **New version of this script?** Run the installer:
  `bash install-wfpiconsole-patches.sh`

The installed copy applies only the rules it already has. Running it
after dropping in a newer `.sh` will happily re-apply the old ones.

Either way, restart the console afterwards:
`sudo systemctl restart wfpiconsole`

### Turning one off

Set it to `off` in `/etc/wfpiconsole-patches.conf` and run the
script once. It **reverts** the patch, restoring that part of the
file exactly — not merely stopping at the next update.

The conf file is written on first install and never overwritten
afterwards, so your choices survive both updates and re-runs of the
installer. A setting absent from the file falls back to its default,
which is how new settings arrive without breaking an existing
install.

`square-dials` is the one exception: it rewrites three blocks with a
regex and has no automatic reverse. Turning it off stops it being
re-applied, and the next `wfpiconsole update` restores the stock
layout.

To remove everything: `bash install-wfpiconsole-patches.sh
--uninstall`. That leaves the patched files as they are; set every
patch to `off` and run once first if you want PiConsole back to
stock.

### If a patch stops matching

The script only rewrites a file it actually changes. If PiConsole's
code moves on far enough that a patch no longer applies, it says so
in its output rather than guessing, and never fails in a way that
would stop the console starting:

```
udp-obs-length: no match - PiConsole's code has changed upstream;
check whether this patch is still needed
```

---

## Settings reference

All in `/etc/wfpiconsole-patches.conf`.

| Setting | Default | Notes |
|---|---|---|
| `temp-decimal-scale` | `0.65` | Size of the decimal, as a fraction of the digits beside it. 0.3–1.0 |
| `temp-decimal-position` | `normal` | `baseline`, `normal` or `raised` |
| `temp-unit-superscript` | `on` | Draw the `℉` small and raised |
| `temp-unit-scale` | `0.45` | Size of that unit. 0.2–1.0 |
| `temp-unit-min-px` | `6` | Floor for the unit in pixels; only bites on the min/max fields |
| `temp-colour` | `on` | Tint each temperature by its value |
| `temp-colour-stops` | `45, 60, 78, 90` | In displayed units — Fahrenheit here |
| `temp-colour-values` | `00a4b4, 4fc3d7, c8c8c8, f0a050, f05e40` | One more colour than there are stops |
| `dewpoint-colour-stops` | `55, 65, 70` | |
| `dewpoint-colour-values` | `81c784, c8c8c8, f0a050, f05e40` | |
| `panel-accent-colours` | see below | `Name: hex` pairs; panels left out keep their default |

Everything under `temp-decimal-*`, `temp-unit-*` and `temp-colour*`
belongs to the `temp-decimal-size` patch, which owns those `.kv`
lines. Turning that patch off turns all of it off together.

---

## 1. Dials draw as ovals on anything that is not 5:3

**Symptom.** The wind rose, the barometer arc and the moon phase are
noticeably taller than they are wide — about 15% on a 1280x800
panel. Everything else looks right.

**Cause.** In `kvlang/layout.kv`, each dial is sized as a fraction
of its panel's width and height separately, then squared by capping
one side:

```
size_hint: (134/262, 134/202)
size_hint_max_x: self.height if self.parent.width  > self.parent.height else None
size_hint_max_y: self.width  if self.parent.height > self.parent.width  else None
```

Only one of those two lines ever fires, and which one is chosen from
the aspect ratio of the **panel** rather than from the two
proportional sizes actually being compared. On a landscape panel
`self.parent.width > self.parent.height` is true, so `size_hint_max_x`
is set and the *width* is capped at the height — right only while
the width is the longer side. Once the panel is proportionally
taller than the 262:202 design grid, the height is the longer side,
and nothing caps it, because `size_hint_max_y` is never set on a
landscape panel.

Walking the rules through by hand, with the wind rose's 134:

```
panel 262 x 202   (design grid)     ->  134.0 x 134.0   square
panel 419 x 323   (same 262:202)    ->  214.3 x 214.3   square
panel 419 x 336   (4% taller)       ->  214.3 x 222.9   1.04:1
panel 419 x 373   (15% taller)      ->  214.3 x 247.4   1.15:1
```

So the dial stretches by however much the panel departs from
262:202, which is why the console looks correct at 800x480 and wrong
on anything else.

**Fix.** Take the smaller of the two proportional sizes and use it
for both axes:

```
size_hint: (None, None)
size: [min((134/262)*self.parent.width, (134/202)*self.parent.height)] * 2
```

Wherever the current code already produces a square — which includes
every case at the design ratio — `min` returns that same number, so
800x480 is unaffected. Everywhere else it gives a true circle
instead of an ellipse. Applied to all three dials; the `x` and `y`
rules are untouched, so nothing moves.

---

## 2. UDP mode shows wind and nothing else

**Symptom.** With the connection type set to UDP, the wind panel
updates every three seconds but temperature, humidity, pressure,
solar and rain stay as dashes indefinitely. Nothing appears on
screen. `wfpiconsole.log` fills with:

```
File "lib/observation_parser.py", line 126, in parse_obs_st
    self.device_obs['dailyRain']  = [latest_ob[18], 'mm']
IndexError: list index out of range
```

**Cause.** A Tempest `obs_st` observation broadcast over UDP carries
18 values, indices 0 to 17, ending at the report interval. Here is
one, captured on firmware 193:

```json
{"serial_number":"ST-00222100","type":"obs_st","hub_sn":"HB-00224206",
 "obs":[[1790204135,0.09,1.28,3.22,221,3,953.64,35.08,26.15,67816,
         5.89,565,0.000000,0,0,0,2.768,1]],"firmware_revision":193}
```

The Websocket and REST forms of the same message carry up to 22:
index 18 is local daily rain accumulation, and 19 to 21 are the
Rain Check fields. `parse_obs_st` reads index 18 unconditionally, so
over UDP every observation raises `IndexError` and kills the parser
thread — before any of the other values are stored. Rapid wind
arrives on a different message and a different code path, which is
why wind alone keeps working.

**Fix.** Read the trailing fields only if they exist:

```python
def _field(index):
    return latest_ob[index] if index < len(latest_ob) else None
```

Nothing is lost. Over UDP, `rain_accumulation()` in
`derived_variables.py` already builds the day's total from the REST
API plus each minute's rain, and ignores `dailyRain` entirely — so
the field the parser was crashing on was never used in this mode.

This patch is matched by its code rather than by an exact text
match, so a file patched by an earlier version of this script, whose
comment was worded differently, is recognised and normalised instead
of being reported as a mismatch.

Related upstream: issues
[#173](https://github.com/peted-davis/WeatherFlow_PiConsole/issues/173)
and
[#177](https://github.com/peted-davis/WeatherFlow_PiConsole/issues/177).

---

## 3. Sager forecast fails whenever the sky is clear

**Symptom.** The Sager Weathercaster panel reads:

```
ERROR: Missing METAR cloud information. Forecast will be
regenerated in 60 minutes
```

and keeps reading it, hour after hour, on exactly the days the
weather is most settled. On an overcast day the same install
produces a forecast normally.

**Cause.** `lib/sager.py` asks CheckWX for decoded METARs within 100
miles, sorts them by distance, and keeps the nearest one that has a
`clouds` key:

```python
for METAR in METAR_data:
    if 'clouds' in METAR:
        self.sager_data['METAR'] = METAR['raw_text']
        break
```

`clouds` is a list of decoded cloud *layers*. A clear-sky report —
`SKC`, `CLR`, `CAVOK`, `NCD`, `NSC` — has no layers, so CheckWX
omits the key rather than returning an empty list, and the report is
thrown away. If every station in range is clear, nothing survives
the loop and the forecast is marked failed.

This looks like it was reached in two steps rather than intended.
Commit `faddb03` changed `if METAR['clouds']:` to `if 'clouds' in
METAR:` to fix a `KeyError` when the key was missing, and `e7db206`
added the explicit failure path. Both versions treat "the sky is
clear" as "the data is unusable".

Two things make it bite hard here. CheckWX's free tier returns a
single station regardless of the radius asked for — for Canyon
Country that is KWHP, Whiteman Airport — so there is no second
report to fall back on. And southern California is clear most of the
year, so the failure is the normal state rather than the exception.

**Fix.** Nothing downstream actually wants the decoded list.
`get_dial_setting()` a hundred lines later searches the *raw text*
for cloud codes, and its own list covers all five clear-sky ones:

```python
ccodes = ['CAVOK', 'CLR', 'NCD', 'NSC', 'SKC', 'FEW', 'SCT', 'BKN', 'OVC', 'VV']
```

which map to `pw = 'Clear'`. So a `SKC` report contains exactly what
the forecaster needs; it is just thrown away before it gets there.
Prefer a report with decoded layers when one exists, and otherwise
take the nearest report whose raw text carries any recognised cloud
group:

```python
for METAR in METAR_data:
    if METAR.get('clouds'):
        self.sager_data['METAR'] = METAR['raw_text']
        break
if self.sager_data['METAR'] is None:
    for METAR in METAR_data:
        raw = METAR.get('raw_text') or ''
        if any(code in raw for code in _ccodes):
            self.sager_data['METAR'] = raw
            break
```

`METAR.get('clouds')` also covers the present-but-empty case, so the
`KeyError` that `faddb03` fixed stays fixed. A report carrying no
cloud group at all still fails, which is correct — the dial
genuinely cannot be set without one.

This does not remove the value of a paid CheckWX tier. The free
tier's single station is 13 miles away across a ridge at a lower
elevation; a wider radius gives the forecaster a real choice of
nearest report, and covers the hours when a part-time field is not
reporting at all.

---

## 4. Precision the sensor cannot support

Not bugs — preferences. The console hardcodes the precision of every
reading, and two of them claim more than the Tempest can measure.

### pressure-precision

Pressure prints as `29.921 inHg` — a resolution of about 0.03 hPa
against a ±1 hPa sensor, and one decimal more than an altimeter
setting is read in anywhere else. Two decimals.

The hourly trend keeps all three: a few thousandths of an inch per
hour *is* the whole signal there.

### peak-sun-precision

Peak Sun Hours prints as `0.00 hrs`. Two decimals on a figure in
hours is more than the number carries. The battery voltage line
looks identical in the source and is deliberately left alone — two
decimals across a 2.4–2.8 V range is right there.

### Temperature: two answers, pick one

Temperature prints as `72.1℉`. The Tempest is spec'd at ±0.3 °C,
which is ±0.5 °F, so the tenth is below what the instrument can
resolve. There are two ways to deal with that, and they conflict — a
rounded value has no decimal left to shrink — so exactly one should
be on.

**`temp-whole-degrees`** (off by default) rounds it away in
`lib/observation_format.py`: `72.1℉` becomes `72℉`.

**`temp-decimal-size`** (on by default) keeps the tenth and draws it
smaller, so it stops competing with the number you actually read.
That is how the Ambient Weather WS-2902 console shows it, and it is
the better answer: no information is thrown away, but the display
reads as cleanly as if it had been.

---

## 5. How the temperature panel is drawn

All of this belongs to `temp-decimal-size`, which owns the `text:`
rules in `kvlang/temperature.kv`.

It has to be done per field. Kivy's `[size=]` takes an absolute
number, and only the `.kv` knows each field's `self.font_size`, so
doing it once in `observation_format.py` is not possible. Note too
that `font_size` is scaled: `scaleFactor = min(width/800,
height/480)`, so on a 1280x800 panel a `MediumField` declared as 20
is really 32.

It covers the eight values in the panel that can carry a decimal —
the large indoor and outdoor readings, Feels Like, Dew Point, and
the four min/max fields. Not the 24-hour difference or the trend:
those are rates, already drawn small, and on `-0.1℉` the whole
number part is a zero, so shrinking the decimal would demote the
only digit carrying information.

Handled along the way: the value is `-` when a sensor is down, and
negative temperatures split correctly (`-3.2` into `-3` and `.2`).

### The decimal

`temp-decimal-scale` sets how big it is drawn, and
`temp-decimal-position` picks one of the three placements Kivy
offers for inline text, with nothing available between them:

| value | tag | result |
|---|---|---|
| `baseline` | `[sub]` | bottom aligned with the digits — how the WS-2902 draws it |
| `normal` | none | the renderer's own placement, floating between middle and bottom |
| `raised` | `[sup]` | a true superscript, top aligned |

`[sub]` and `[sup]` halve the size on their own, but the explicit
`[size]` nested inside overrides that, so position and size stay
independent.

On `normal` the renderer places each span at `(line_height -
word_height) / 1.25`, so a *larger* span also sits *higher* — size
and height are the same dial there, and that coupling is the reason
there is no separate height setting. On `baseline` and `raised` the
position is fixed and the scale changes size only.

Defaults are `0.65` and `normal`, which is where a fair amount of
back and forth on a 1280x800 panel landed.

### The unit

`temp-unit-superscript` draws the `℉` small and lifted instead of
full size on the baseline. This is the one place Kivy's `[sup]` is
the right tool — it positions at the top of the line, which is
exactly where a unit belongs.

`temp-unit-scale` sets how small; `[sup]` alone would always give
0.5. Past about that it stops reading as a superscript. `℉` is a
single character (U+2109), not a degree sign plus an F, so the two
cannot be sized separately.

`temp-unit-min-px` floors it. The min/max fields already render at
0.88 of their font size, so the same fraction that looks right on
the big reading lands around 5px there — proportionally correct,
practically unreadable.

On the min/max fields the unit closes its own `[size]` inside
`[sup]`, so the tail carries one `[/size]` fewer than upstream's.
Kivy pops `font_size` once per closing tag, and if the count does
not come out even, the rest of the label inherits the wrong size.

### The colour

`temp-colour` tints each reading by its own value. The anchors are
the two accents the console already carries — `00a4b4` for a daily
minimum, `f05e40` for a maximum — with ordinary grey in the middle,
so a mild reading looks exactly as it did and only the ends of the
range pick up colour:

```
< 45    00a4b4      45–60   4fc3d7      60–78   c8c8c8
78–90   f0a050      > 90    f05e40
```

Dew point gets its own scale, because it says more about comfort
than humidity does — green below 55, grey to 65, amber to 70, orange
above.

Outdoor, Indoor, Feels Like and Dew Point. The min/max fields are
left out: they already use colour to say which is which, and a
second meaning on the same channel would collide.

Stops are in **displayed** units, Fahrenheit on this build. Each
scale needs exactly one more colour than it has stops; a mismatched
pair falls back to the defaults rather than drawing something
arbitrary.

---

## 6. panel-accents

Every panel heading is drawn white by `PanelTitle`. Colouring them
per panel is most of what gives the Ambient console its liveliness,
and `PanelTitle` inherits `markup` from `DisplayField`, so wrapping
the title string in a `[color]` tag is all it takes — no widget
changes.

```
Forecast  8ab4f8   Temperature f0a050   Wind Speed 9ccc65
Rainfall  4fc3d7   Barometer   b39ddb   Moon       b0bec5
Lightning ff8a65   Sager       80cbc4   Solar      ffca28
```

Chosen to read as one system rather than as confetti: similar
saturation and lightness throughout, each legible on black, and an
obvious colour where a panel has one. Override any subset —

```
panel-accent-colours = Temperature: f0a050, Rainfall: 4fc3d7
```

— and the panels you leave out keep their defaults.

Nine titles across seven files, and the only patch here that spans
more than one. Solar is the odd case: its title already carries
`[size]` markup for the divider between "Solar" and "UV", so the
colour wraps the whole expression rather than a plain string.

---

## What was already right

Left alone: humidity, solar radiation and wind direction are
integers; rain is two decimals in inches, the standard reporting
increment; battery is two decimals across a 2.4–2.8 V range; wind
drops to integers above 10 mph. The forecast high and low have
always used whole degrees — `forecastTemp` is `.0f` upstream.

---

## Things worth knowing about this build

**Install 64-bit Raspberry Pi OS.** The console does not run on the
32-bit version of Trixie. Check with `dpkg --print-architecture`; it
should say `arm64`. Preloaded cards from resellers are often 32-bit,
and the label is not always right.

**The window size settings in `wfpiconsole.ini` do nothing in
fullscreen.** `Width` and `Height` under `[Display]` apply only when
`Fullscreen = 0`. Changing them to match the panel is a red herring
— the oval dials above are a layout bug, not a resolution mismatch.

**Feels Like labels read one band warm.** Each value under
`[FeelsLike]` is the *maximum* temperature for that label, so `Warm
= 68` means warm stops at 68 and 70°F is reported as "Feeling hot".
Shift the whole scale up if the labels read oddly.

**`Cursor = 0` and `Border = 0`** under `[Display]` hide the mouse
pointer and the panel outlines. On a shelf console the pointer
parked mid-screen is the most obvious blemish.

**CheckWX's free tier ignores the radius** and returns one station.
Patch 3 makes the Sager forecaster work with that single station on
clear days, but a paid tier still gives it a genuine choice of
nearest report, and covers the hours when a part-time field is not
reporting at all.

**Turn off screen blanking** in `raspi-config` under Display
Options, or a shelf display goes dark after ten minutes.

**The console cannot be started over SSH**, only locally or via VNC.
With autostart enabled, `wfpiconsole stop` over SSH is the way to
stop it — quitting the app from the desktop just makes systemd start
it again.

**VNC is built in.** `raspi-config` → Interface Options → VNC. On
Trixie that sets up **wayvnc**, not RealVNC's server, so use a plain
VNC client — TigerVNC works, and RealVNC's viewer now wants an
account. It mirrors the real display, so you see the console itself.

---

## Related

[ha-rain-irrigation](https://github.com/hkaczmarek/ha-rain-irrigation)
— the irrigation system this console sits alongside, which reads the
same Tempest over the same UDP broadcast.
