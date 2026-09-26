# WeatherFlow PiConsole patches

Four patches for the [WeatherFlow
PiConsole](https://github.com/peted-davis/WeatherFlow_PiConsole),
plus the machinery to keep them applied across updates.

The first three are bugs in the console rather than configuration
problems. One makes every circular gauge draw as an oval; one makes
a station in UDP mode display wind and nothing else; one makes the
Sager forecaster fail on clear days, which is to say most days
here. The fourth is a matter of taste, and drops two readings to
the precision the instrument can actually support.

Tested against v26.4.2 on a Raspberry Pi 4 running 64-bit
Raspberry Pi OS Trixie, driving a 10.1 inch 1280x800 panel.

---

## Install

```
bash install-wfpiconsole-patches.sh
```

Run it as your normal user, not with `sudo` - it calls `sudo`
where it needs to. It installs:

```
/usr/local/bin/wfpiconsole-patches       the fixes, idempotent
wfpiconsole-patches.path / .service      re-run them when PiConsole's
                                         files change, i.e. after an update
wfpiconsole.service.d/patches.conf       re-run them before every autostart
```

Nothing is placed inside `~/wfpiconsole`, so `wfpiconsole update`
cannot remove any of it. The patch script only rewrites a file it
actually changes, and if PiConsole's code moves on far enough that
a patch no longer matches, it says so in the log rather than
guessing - and never fails in a way that would stop the console
starting.

To remove: `bash install-wfpiconsole-patches.sh --uninstall`

---

## 1. Dials draw as ovals on anything that is not 5:3

**Symptom.** The wind rose, the barometer arc and the moon phase
are noticeably taller than they are wide - about 15% on a 1280x800
panel. Everything else looks right.

**Cause.** In `kvlang/layout.kv`, each dial is sized as a fraction
of its panel's width and height separately:

```
size_hint: (134/262, 134/202)
size_hint_max_x: self.height if self.parent.width  > self.parent.height else None
size_hint_max_y: self.width  if self.parent.height > self.parent.width  else None
```

Those last two lines exist to force a square, but they choose
which side to trim from the shape of the *panel*, not the shape of
the *dial*. On the 800x480 display PiConsole was designed for, the
two fractions happen to produce an exact square and the guard
never matters. On a 1280x800 panel the panels are proportionally
taller, the dial's width becomes the shorter side, and nothing
trims the height.

**Fix.** Take the smaller of the two proportional sizes and use it
for both:

```
size_hint: (None, None)
size: [min((134/262)*self.parent.width, (134/202)*self.parent.height)] * 2
```

Applied to all three dials. Output on 800x480 is unchanged.

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

**Cause.** A Tempest `obs_st` observation broadcast over UDP
carries 18 values, indices 0 to 17, ending at the report interval.
Here is one, captured on firmware 193:

```json
{"serial_number":"ST-00222100","type":"obs_st","hub_sn":"HB-00224206",
 "obs":[[1790204135,0.09,1.28,3.22,221,3,953.64,35.08,26.15,67816,
         5.89,565,0.000000,0,0,0,2.768,1]],"firmware_revision":193}
```

The Websocket and REST forms of the same message carry up to 22:
index 18 is local daily rain accumulation, and 19 to 21 are the
RainCheck fields. `parse_obs_st` reads index 18 unconditionally, so
over UDP every observation raises `IndexError` and kills the parser
thread - before any of the other values are stored. Rapid wind
arrives on a different message and a different code path, which is
why wind alone keeps working.

**Fix.** Read the trailing fields only if they exist:

```python
def _field(index):
    return latest_ob[index] if index < len(latest_ob) else None
```

Nothing is lost. Over UDP, `rain_accumulation()` in
`derived_variables.py` already builds the day's total from the REST
API plus each minute's rain, and ignores `dailyRain` entirely - so
the field the parser was crashing on was never used in this mode.

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

**Cause.** `lib/sager.py` asks CheckWX for decoded METARs within
100 miles, sorts them by distance, and keeps the nearest one that
has a `clouds` key:

```python
for METAR in METAR_data:
    if 'clouds' in METAR:
        self.sager_data['METAR'] = METAR['raw_text']
        break
```

`clouds` is a list of decoded cloud *layers*. A clear-sky report -
`SKC`, `CLR`, `CAVOK`, `NCD`, `NSC` - has no layers, so CheckWX
omits the key rather than returning an empty list, and the report
is thrown away. If every station in range is clear, nothing
survives the loop and the forecast is marked failed.

Two things make this bite hard here. CheckWX's free tier returns a
single station regardless of the radius asked for - for Canyon
Country that is KWHP, Whiteman Airport - so there is no second
report to fall back on. And southern California is clear most of
the year, so the failure is the normal state rather than the
exception.

**Fix.** Nothing downstream actually wants the decoded list.
`get_dial_setting()` a hundred lines later searches the *raw text*
for cloud codes, and its list of codes includes all five clear-sky
ones:

```python
ccodes = ['CAVOK', 'CLR', 'NCD', 'NSC', 'SKC', 'FEW', 'SCT', 'BKN', 'OVC', 'VV']
```

A `SKC` report maps cleanly to the forecaster's "Clear" present
weather. So: prefer a report with decoded layers when one exists,
and otherwise take the nearest report whose raw text carries any
recognised cloud group.

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

A report carrying no cloud group at all still fails, which is
correct - the Sager dial genuinely cannot be set without it.

Note this does not remove the value of a paid CheckWX tier. The
free tier's single station is 13 miles away across the ridge at a
lower elevation; a wider radius gives the forecaster a real choice
of nearest report, and covers the case where KWHP - a part-time
field - is not reporting at all.

---

## 4. Decimals the sensor cannot support

Not a bug - a preference, and the one patch here you might not
want. `lib/observation_format.py` hardcodes the precision of every
reading. Two of them claim more than the Tempest can measure.

**Temperature** prints as `72.1℉`. The Tempest is spec'd at ±0.3 °C,
which is ±0.5 °F, so that tenth is noise wearing the costume of
precision. Whole degrees.

**Pressure** prints as `29.921 inHg` - a resolution of about 0.03
hPa against a ±1 hPa sensor. Two decimals, which is how an
altimeter setting is read everywhere else anyway.

Both rate-of-change figures keep their decimals. A trend of a few
tenths of a degree, or a few thousandths of an inch, per hour *is*
the signal; rounding it would flatten it to zero.

Before and after, through the console's own formatter:

```
temperature                    72.1℉  ->        72℉
temperature trend           +1.4℉/hr  ->  +1.4℉/hr
pressure                 29.921 inHg  ->  29.92 inHg
pressure trend         0.014 inHg/hr  ->  0.014 inHg/hr
```

Everything else was already right and is left alone: humidity,
solar radiation and wind direction are integers; rain is two
decimals in inches, the standard reporting increment; battery is
two decimals across a 2.4-2.8 V range; wind drops to integers above
10 mph. If you want the forecast to match, note it already uses
whole degrees - `forecastTemp` has always been `.0f`.

Skip this patch by deleting its entry from the `status` list in
the installer.

---

## Things worth knowing about this build

**Install 64-bit Raspberry Pi OS.** The console does not run on the
32-bit version of Trixie. Check with `dpkg --print-architecture`;
it should say `arm64`. Preloaded cards from resellers are often
32-bit, and the label is not always right.

**The window size settings in `wfpiconsole.ini` do nothing in
fullscreen.** `Width` and `Height` under `[Display]` apply only
when `Fullscreen = 0`. Changing them to match the panel is a red
herring - the oval dials above are a layout bug, not a resolution
mismatch.

**Feels Like labels read one band warm.** Each value under
`[FeelsLike]` is the *maximum* temperature for that label, so
`Warm = 68` means warm stops at 68 and 70°F is reported as
"Feeling hot". Shift the whole scale up if the labels read oddly.

**CheckWX's free tier ignores the radius** and returns one
station. Patch 3 above makes the Sager forecaster work with that
single station on clear days, but a paid tier still gives it a
genuine choice of nearest report, and covers the hours when a
part-time field is not reporting at all.

**Turn off screen blanking** in `raspi-config` under Display
Options, or a shelf display goes dark after ten minutes.

**The console cannot be started over SSH**, only locally or via
VNC. With autostart enabled, `wfpiconsole stop` over SSH is the way
to stop it.

---

## Related

[ha-rain-irrigation](https://github.com/hkaczmarek/ha-rain-irrigation)
- the irrigation system this console sits alongside, which reads
the same Tempest over the same UDP broadcast.
