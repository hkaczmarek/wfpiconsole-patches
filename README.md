# WeatherFlow PiConsole patches

Two fixes for the [WeatherFlow
PiConsole](https://github.com/peted-davis/WeatherFlow_PiConsole),
plus the machinery to keep them applied across updates.

Both are bugs in the console rather than configuration problems,
and both took a while to identify because neither shows an error
on screen. One makes every circular gauge draw as an oval; the
other makes a station in UDP mode display wind and nothing else.

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

**The Sager forecaster needs a nearby station reporting cloud.**
It asks CheckWX for decoded METARs within 100 miles and uses the
first with a `clouds` field. A station reporting SKC returns no
such field, and CheckWX's free tier returns a single station, so
on a clear day the forecast cannot be generated. Not a fault.

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
