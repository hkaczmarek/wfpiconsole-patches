#!/bin/bash
# =============================================================
# install-wfpiconsole-patches.sh
#
# Keeps local fixes to WeatherFlow PiConsole applied, including
# after `wfpiconsole update`, which restores the stock files.
#
#   square-dials        kvlang/layout.kv
#   udp-obs-length      lib/observation_parser.py
#   sager-metar-clouds  lib/sager.py
#   pressure-precision  lib/observation_format.py
#   temp-whole-degrees  lib/observation_format.py   (off by default)
#   temp-decimal-size   kvlang/temperature.kv
#   peak-sun-precision  lib/observation_format.py
#   panel-accents       kvlang/*.kv
#
# Each is described in the patch script itself.
#
# Every patch can be switched on or off in
#   /etc/wfpiconsole-patches.conf
# Turning one off REVERTS it on the next run, so a patch you do
# not like can be undone without touching PiConsole by hand. The
# file is created with defaults on first install and is never
# overwritten afterwards, so your choices survive.
#
# Installs:
#   /usr/local/bin/wfpiconsole-patches        the idempotent fixes
#   /etc/wfpiconsole-patches.conf             on/off per patch
#   wfpiconsole-patches.path / .service       re-run them whenever
#                                             a patched file changes
#   wfpiconsole.service.d/patches.conf        run them before every
#                                             autostart, as a backstop
#
# Supersedes install-square-dials.sh, whose units this removes.
# Nothing is placed inside ~/wfpiconsole, so updates can't remove
# it. Run once, as your normal user (not with sudo):
#   bash install-wfpiconsole-patches.sh
#
# To remove:  bash install-wfpiconsole-patches.sh --uninstall
# =============================================================
set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
    echo "Run this as your normal user, not with sudo - it uses sudo where needed."
    exit 1
fi

CONSOLE_USER="$USER"
WFPC="$HOME/wfpiconsole"
SCRIPT=/usr/local/bin/wfpiconsole-patches
CONF=/etc/wfpiconsole-patches.conf
UNITS=/etc/systemd/system

# Retire the older square-dials-only installation, if present.
sudo systemctl disable --now wfpiconsole-square-dials.path 2>/dev/null || true
sudo rm -f "$UNITS/wfpiconsole-square-dials.path" \
           "$UNITS/wfpiconsole-square-dials.service" \
           "$UNITS/wfpiconsole.service.d/square-dials.conf" \
           /usr/local/bin/wfpiconsole-square-dials

if [ "${1:-}" = "--uninstall" ]; then
    sudo systemctl disable --now wfpiconsole-patches.path 2>/dev/null || true
    sudo rm -f "$UNITS/wfpiconsole-patches.path" \
               "$UNITS/wfpiconsole-patches.service" \
               "$UNITS/wfpiconsole.service.d/patches.conf" \
               "$SCRIPT"
    sudo rmdir "$UNITS/wfpiconsole.service.d" 2>/dev/null || true
    sudo systemctl daemon-reload
    echo "Removed. $CONF is left in place, and so are the patched files."
    echo "To put PiConsole back to stock first, set every patch to 'off'"
    echo "in $CONF and run $SCRIPT once before uninstalling."
    exit 0
fi

echo "Installing $SCRIPT"
sudo tee "$SCRIPT" > /dev/null << 'PYEOF'
#!/usr/bin/env python3
"""
Re-apply local fixes to WeatherFlow PiConsole after an update.

`wfpiconsole update` replaces the program files, so anything patched
by hand goes back to stock. This script re-applies the patches below.
It is idempotent: it only rewrites a file it actually changes, and it
never fails in a way that would stop the console from starting.

Each patch can be switched off in /etc/wfpiconsole-patches.conf, and
a patch switched off is REVERTED on the next run rather than merely
skipped - so anything here can be undone without editing PiConsole by
hand. square-dials is the one exception: it rewrites three blocks
with a regex and has no automatic reverse, so turning it off stops it
being re-applied but leaves the current file as it is. `wfpiconsole
update` restores stock in that case.

  square-dials (kvlang/layout.kv)
     The wind, moon and barometer dials are sized as fractions of
     their panel's width and height separately, then squared by
     capping one side - but which side is chosen from the PANEL's
     shape, and on a landscape panel only size_hint_max_x is ever
     set. That caps the width, which is right only while the width
     is the longer side. Once the panel is proportionally taller
     than the 262:202 design grid the height is the longer side and
     nothing caps it, so every dial draws stretched - about 15% on
     1280x800. Fix: both sides take the smaller proportional size,
     which is identical at 800x480 and a true circle everywhere.

  udp-obs-length (lib/observation_parser.py)
     A Tempest obs_st broadcast over UDP carries 18 fields (0-17),
     ending at the report interval. Indices 18-21 - local daily
     rain and the two Rain Check fields - exist only in the
     Websocket/REST form of the same message. parse_obs_st reads
     index 18 regardless, so over UDP every observation raised
     IndexError and killed the parser thread before temperature,
     humidity, pressure or solar were stored: wind updated, nothing
     else did. Nothing is lost by guarding it - over UDP,
     rain_accumulation() builds today's total from the REST API
     plus each minute's rain and ignores that field.
     Upstream: issues #173 and #177.

  sager-metar-clouds (lib/sager.py)
     The Sager forecaster asks CheckWX for decoded METARs within
     100 miles and keeps the nearest report that has a 'clouds'
     key. A clear-sky report - SKC, CLR, CAVOK, NCD, NSC - has no
     cloud layers to decode, so CheckWX omits that key entirely
     and every such report is discarded. With only one station in
     range, as on the CheckWX free tier, the forecast then fails
     with "Missing METAR cloud information" on exactly the days
     the sky is clearest. get_dial_setting() searches raw_text for
     cloud codes anyway and handles the clear ones explicitly, so
     nothing downstream needs the decoded list. Fix: fall back to
     the nearest report whose raw_text carries a recognised cloud
     group.

  pressure-precision (lib/observation_format.py)
     Pressure prints as 29.921 inHg - a resolution of about 0.03
     hPa against a +/-1 hPa sensor, and three decimals more than
     an altimeter setting is read in anywhere else. Two decimals.
     The hourly trend keeps all three: a few thousandths of an
     inch per hour IS the signal there.

  temp-whole-degrees (lib/observation_format.py)   DEFAULT OFF
     Temperature prints as 72.1 F, and the Tempest is spec'd at
     +/-0.3 C (+/-0.5 F), so that tenth is below what the
     instrument resolves. Rounding it away is one answer.
     temp-decimal-size below is the better one, and the two
     conflict - rounded values have no decimal left to shrink - so
     this is off unless you turn it on.

  temp-decimal-size (kvlang/temperature.kv)
     The nicer answer to the same problem, borrowed from the
     Ambient Weather WS-2902 console: keep the tenth, but draw it
     smaller than the whole degrees, so it stops competing with the
     number you actually read. The console already does this for
     the min/max units, and LargeField inherits markup from
     DisplayField, so nothing new is needed.

     Applies to every value in the temperature panel that can carry
     a decimal: the large indoor and outdoor readings, Feels Like,
     Dew Point, and all four min/max fields. Not the 24-hour
     difference or the trend - those are rates, already drawn
     small, and there the decimal IS the signal.

     temp-unit-superscript, also in the conf file, additionally
     draws the unit small and raised on the four plain fields -
     Kivy's [sup], which is the one place that tag is the right
     tool, since it positions at the top of the line rather than on
     the baseline. The min/max units are left alone: they are
     already reduced to 0.83 and raising them too reads as noise.

     temp-colour, also in the conf file, tints each reading by its
     own value, using the two accents the console already carries -
     00a4b4 for a minimum, f05e40 for a maximum - with ordinary grey
     in the middle, so a mild reading looks unchanged. Dew point
     gets its own scale, since it says more about comfort than
     humidity does. The min/max fields are left out: they use
     colour already, to say which is which. Stops are in displayed
     units, Fahrenheit on this build.

     Size, and height, are set by temp-decimal-scale in the conf
     file. Kivy offers inline text three vertical positions -
     superscript, normal, subscript - and no pixel offset, so on
     normal positioning the renderer places a span at
     (line_height - word_height) / 1.25. A larger span therefore
     sits higher, which makes the scale the only fine adjustment
     available for height as well as size.
  peak-sun-precision (lib/observation_format.py)
     Peak Sun Hours prints as 0.00 hrs. Two decimals on a figure in
     hours is more than the number carries; one is plenty. The
     battery voltage line looks identical and is left alone - two
     decimals across a 2.4-2.8 V range is right there.

  panel-accents (kvlang/*.kv)
     Every panel heading is drawn white. Colouring them per panel is
     most of what gives the Ambient WS-2902 console its liveliness.
     PanelTitle inherits markup from DisplayField, so wrapping the
     title string in a [color] tag is enough - no widget changes.
     Spans nine titles across seven files. Colours are set in the
     conf file.
"""
import os
import re
import sys

ROOT = os.path.expanduser(sys.argv[1] if len(sys.argv) > 1 else '~/wfpiconsole')
CONF = '/etc/wfpiconsole-patches.conf'

# Whether each patch should be applied, unless the conf file says
# otherwise. temp-whole-degrees is off because temp-decimal-size
# supersedes it.
DEFAULTS = {
    'square-dials':       True,
    'udp-obs-length':     True,
    'sager-metar-clouds': True,
    'pressure-precision': True,
    'temp-whole-degrees': False,
    'temp-decimal-size':  True,
    'peak-sun-precision': True,
    'panel-accents':      True,
}


def settings():
    """Read the conf file. Returns patches plus the five decimal settings."""
    state = dict(DEFAULTS)
    scale = DEC_SCALE_DEFAULT
    sup   = DEC_SUP_DEFAULT
    usc   = DEC_UNIT_SCALE_DEFAULT
    pos   = DEC_POS_DEFAULT
    umin  = DEC_UNIT_MIN_DEFAULT
    tint  = TEMP_COLOUR_DEFAULT
    phue  = dict(PANEL_HUES_DEFAULT)
    tstop, thue = list(TEMP_STOPS_DEFAULT), list(TEMP_HUES_DEFAULT)
    dstop, dhue = list(DEW_STOPS_DEFAULT),  list(DEW_HUES_DEFAULT)
    try:
        with open(CONF) as f:
            for line in f:
                line = line.split('#')[0].strip()
                if '=' not in line:
                    continue
                key, _, value = line.partition('=')
                key, value = key.strip(), value.strip()
                if key in state:
                    state[key] = value.lower() in ('on', 'true', 'yes', '1')
                elif key == 'temp-decimal-scale':
                    try:
                        scale = round(min(max(float(value), 0.3), 1.0), 3)
                    except ValueError:
                        pass
                elif key == 'temp-unit-superscript':
                    sup = value.lower() in ('on', 'true', 'yes', '1')
                elif key == 'temp-unit-scale':
                    try:
                        usc = round(min(max(float(value), 0.2), 1.0), 3)
                    except ValueError:
                        pass
                elif key == 'temp-decimal-position':
                    if value.lower() in DEC_POS_TAGS:
                        pos = value.lower()
                elif key == 'temp-unit-min-px':
                    try:
                        umin = min(max(int(value), 4), 40)
                    except ValueError:
                        pass
                elif key == 'temp-colour':
                    tint = value.lower() in ('on', 'true', 'yes', '1')
                elif key == 'temp-colour-stops':
                    tstop = parse_stops(value, tstop)
                elif key == 'temp-colour-values':
                    thue = parse_hues(value, thue)
                elif key == 'dewpoint-colour-stops':
                    dstop = parse_stops(value, dstop)
                elif key == 'dewpoint-colour-values':
                    dhue = parse_hues(value, dhue)
                elif key == 'panel-accent-colours':
                    # "Temperature: f0a050, Rainfall: 4fc3d7" - only the
                    # panels named are changed, the rest keep the default.
                    for item in value.split(','):
                        if ':' not in item:
                            continue
                        panel, _, hue = item.partition(':')
                        panel, hue = panel.strip(), hue.strip().lstrip('#').lower()
                        if panel in phue and re.fullmatch(r'[0-9a-f]{6}', hue):
                            phue[panel] = hue
    except OSError:
        pass
    # A scale needs one more colour than it has stops. If the two do
    # not line up, the pair is unusable - fall back rather than draw
    # something arbitrary.
    if len(thue) != len(tstop) + 1:
        phue  = dict(PANEL_HUES_DEFAULT)
    tstop, thue = list(TEMP_STOPS_DEFAULT), list(TEMP_HUES_DEFAULT)
    if len(dhue) != len(dstop) + 1:
        dstop, dhue = list(DEW_STOPS_DEFAULT), list(DEW_HUES_DEFAULT)
    scales = {'temp': (tstop, thue), 'dew': (dstop, dhue)}
    return state, scale, sup, usc, pos, umin, tint, scales, phue


# ---- square dials ---------------------------------------------------
DIALS_ORIGINAL = re.compile(
    r"    size_hint: \((\d+)/262, \1/202\)\n"
    r"(    x: .*\n    y: .*\n)"
    r"    size_hint_max_x: self\.height if self\.parent\.width  > self\.parent\.height else None\n"
    r"    size_hint_max_y: self\.width  if self\.parent\.height > self\.parent\.width  else None\n")
DIALS_DONE = re.compile(r"size: \[min\(\(\d+/262\)\*self\.parent\.width, \(\d+/202\)\*self\.parent\.height\)\] \* 2")


def dials_patch(m):
    n = m.group(1)
    return ("    size_hint: (None, None)\n"
            f"    size: [min(({n}/262)*self.parent.width, ({n}/202)*self.parent.height)] * 2\n"
            + m.group(2))


# ---- UDP observation length -----------------------------------------
UDP_STOCK = """        if bool(int(config['System']['nc_rain'])):
            self.device_obs['minuteRain'] = [latest_ob[19], 'mm']
            self.device_obs['dailyRain']  = [latest_ob[20], 'mm']
        else:
            self.device_obs['minuteRain'] = [latest_ob[12], 'mm']
            self.device_obs['dailyRain']  = [latest_ob[18], 'mm']
"""
UDP_PATCHED = """        # UDP obs_st carries 18 fields (0-17). Indices 18-21 exist
        # only in the Websocket/REST form of this message, so reading
        # them raised IndexError on every UDP observation and killed
        # the parser thread. Over UDP, rain_accumulation() builds
        # today's total from the REST API plus each minute's rain.
        def _field(index):
            return latest_ob[index] if index < len(latest_ob) else None

        if bool(int(config['System']['nc_rain'])):
            self.device_obs['minuteRain'] = [_field(19), 'mm']
            self.device_obs['dailyRain']  = [_field(20), 'mm']
        else:
            self.device_obs['minuteRain'] = [_field(12), 'mm']
            self.device_obs['dailyRain']  = [_field(18), 'mm']
"""

# Match the patch by its CODE, letting the comment above it say
# anything. Earlier versions of this script worded that comment
# differently, and an exact-text check would call those files
# unpatched, then fail to find the stock code to patch - reporting a
# spurious "PiConsole's code has changed upstream". Matching the code
# recognises them, and the rewrite normalises the wording.
UDP_ANY = re.compile(
    r"(?:^ {8}#.*\n)*"
    r" {8}def _field\(index\):\n"
    r" {12}return latest_ob\[index\] if index < len\(latest_ob\) else None\n"
    r"\n"
    r" {8}if bool\(int\(config\['System'\]\['nc_rain'\]\)\):\n"
    r" {12}self\.device_obs\['minuteRain'\] = \[_field\(19\), 'mm'\]\n"
    r" {12}self\.device_obs\['dailyRain'\]  = \[_field\(20\), 'mm'\]\n"
    r" {8}else:\n"
    r" {12}self\.device_obs\['minuteRain'\] = \[_field\(12\), 'mm'\]\n"
    r" {12}self\.device_obs\['dailyRain'\]  = \[_field\(18\), 'mm'\]\n",
    re.M)


def udp_patch():
    def forward(text):
        if UDP_STOCK in text:
            return text.replace(UDP_STOCK, UDP_PATCHED), text.count(UDP_STOCK)
        new_text, count = UDP_ANY.subn(lambda m: UDP_PATCHED, text)
        return new_text, count

    def backward(text):
        return UDP_ANY.subn(lambda m: UDP_STOCK, text)

    def applied(text):
        return UDP_PATCHED in text

    def present(text):
        return bool(UDP_ANY.search(text))

    return forward, backward, applied, present


# ---- Sager METAR clouds ---------------------------------------------
SAGER_PAIRS = [("""            self.sager_data['METAR'] = None
            for METAR in METAR_data:
                if 'clouds' in METAR:
                    self.sager_data['METAR'] = METAR['raw_text']
                    break
""", """            # A clear-sky report - SKC, CLR, CAVOK, NCD, NSC - has no
            # decoded 'clouds' list, so requiring that key throws away
            # a perfectly usable report and the forecast fails with
            # "Missing METAR cloud information" on every clear day.
            # get_dial_setting() reads cloud cover out of raw_text
            # anyway, and handles the clear codes explicitly, so take
            # the nearest report whose raw_text carries any recognised
            # cloud group - preferring a decoded one when there is
            # both.
            _ccodes = ('CAVOK', 'CLR', 'NCD', 'NSC', 'SKC',
                       'FEW', 'SCT', 'BKN', 'OVC', 'VV')
            self.sager_data['METAR'] = None
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
""")]


# ---- pressure precision ---------------------------------------------
PRESSURE_PAIRS = [("""                        if P.strip() in ['inHg/hr', 'inHg']:
                            if round(cObs[ii - 1], 3) == 0.0:
                                cObs[ii - 1] = '{:.3f}'.format(abs(cObs[ii - 1]))
                            else:
                                cObs[ii - 1] = '{:.3f}'.format(cObs[ii - 1])
""", """                        if P.strip() == 'inHg':
                            if round(cObs[ii - 1], 2) == 0.0:
                                cObs[ii - 1] = '{:.2f}'.format(abs(cObs[ii - 1]))
                            else:
                                cObs[ii - 1] = '{:.2f}'.format(cObs[ii - 1])
                        elif P.strip() == 'inHg/hr':
                            if round(cObs[ii - 1], 3) == 0.0:
                                cObs[ii - 1] = '{:.3f}'.format(abs(cObs[ii - 1]))
                            else:
                                cObs[ii - 1] = '{:.3f}'.format(cObs[ii - 1])
""")]


# ---- temperature to whole degrees (off by default) -------------------
# The trailing "if T.strip() == 'c':" pins this to the temperature
# branch and away from the identical-looking rate-of-change branch
# just below it.
WHOLE_DEG_PAIRS = [("""                    elif round(cObs[ii - 1], 1) == 0.0:
                        cObs[ii - 1] = '{:.1f}'.format(abs(cObs[ii - 1]))
                    else:
                        cObs[ii - 1] = '{:.1f}'.format(cObs[ii - 1])
                    if T.strip() == 'c':
""", """                    elif round(cObs[ii - 1], 0) == 0.0:
                        cObs[ii - 1] = '{:.0f}'.format(abs(cObs[ii - 1]))
                    else:
                        cObs[ii - 1] = '{:.0f}'.format(cObs[ii - 1])
                    if T.strip() == 'c':
""")]


# ---- decimal at reduced size ----------------------------------------
# Split a formatted value at its decimal point and wrap the fractional
# part in a [size] tag, so the tenth stays readable without competing
# with the whole degrees. Kivy's [size=] takes an absolute number, so
# this has to be done per field in the .kv where self.font_size is
# known - it cannot be done once in observation_format.py.
#
# Guarded for the '-' shown when a sensor is down, and safe for
# negative temperatures: '-3.2' splits into '-3' and '.2'.
#
# Vertical position: Kivy offers inline text exactly three positions -
# superscript, normal, subscript - and no pixel offset. We are on
# normal, where the renderer uses (line_height - word_height) / 1.25,
# so a LARGER span sits higher. DEC_SCALE is therefore both the size
# and the only fine height adjustment: raise it to lift the decimal.
DEC_SCALE_DEFAULT = 0.65

# Draw the unit small and raised, the way the WS-2902 does, using
# Kivy's [sup] - the one place that tag is the right tool, since it
# positions at the top of the line rather than on the baseline.
# Applied to all eight fields. On the min/max ones the unit closes
# its own [size] inside [sup], so the tail needs one [/size] fewer
# than upstream's - Kivy pops font_size per tag and the count has to
# come out even, or the rest of the label inherits the wrong size.
DEC_SUP_DEFAULT = True

# Where the decimal sits. Kivy offers three positions and no pixel
# offset between them:
#   baseline  [sub] - bottom aligned with the digits, as the WS-2902
#                     draws it
#   normal          - the renderer's own placement for a smaller span,
#                     (line_height - word_height) / 1.25, which floats
#                     it between the middle and the bottom
#   raised    [sup] - top aligned, a true superscript
# [sub] and [sup] also halve the size on their own; the explicit
# [size] nested inside overrides that, so position and size stay
# independent.
DEC_POS_DEFAULT = 'normal'
DEC_POS_TAGS = {'baseline': ('sub', '/sub'),
                'raised':   ('sup', '/sup'),
                'normal':   (None, None)}

# How big the raised unit is drawn, as a fraction of the field's font
# size. [sup] on its own halves it; nesting an explicit [size] inside
# keeps the raised position and lets us pick the size instead.
DEC_UNIT_SCALE_DEFAULT = 0.45

# Smallest the unit is allowed to get, in pixels. The min/max fields
# already render at 0.88, so the same fraction that gives a good size
# on the big reading lands around 5px there. This stops it vanishing
# without overriding the proportion by much.
DEC_UNIT_MIN_DEFAULT = 6

# Tint each temperature by its own value. The anchors are the two
# accents the console already uses - 00a4b4 for a daily minimum,
# f05e40 for a maximum - with the ordinary text grey in the middle,
# so a mild reading looks exactly as it does now and only the ends of
# the range pick up colour. Stops are in DISPLAYED units, which for
# this build is Fahrenheit.
TEMP_COLOUR_DEFAULT = True
TEMP_STOPS_DEFAULT  = [45, 60, 78, 90]
TEMP_HUES_DEFAULT   = ['00a4b4', '4fc3d7', 'c8c8c8', 'f0a050', 'f05e40']

# Dew point says more about comfort than humidity does, so it gets
# its own scale: dry, unremarkable, humid, oppressive.
DEW_STOPS_DEFAULT = [55, 65, 70]
DEW_HUES_DEFAULT  = ['81c784', 'c8c8c8', 'f0a050', 'f05e40']

# Which scale each field is tinted by. The min/max fields are left
# out: they already use colour to say which is which.
TINT_SCALE = {'inTemp': 'temp', 'outTemp': 'temp',
              'FeelsLike': 'temp', 'DewPoint': 'dew'}


def parse_stops(value, fallback):
    try:
        out = [float(x) for x in value.split(',') if x.strip()]
    except ValueError:
        return fallback
    return out or fallback


def parse_hues(value, fallback):
    out = [x.strip().lstrip('#').lower() for x in value.split(',') if x.strip()]
    if all(re.fullmatch(r'[0-9a-f]{6}', x) for x in out) and out:
        return out
    return fallback


def colour_expr(key, stops, hues):
    """A .kv expression yielding '[color=xxxxxx]' for this field.

    The value arrives as the formatted string, so it is checked before
    float() sees it: '-' is what the console shows when a sensor is
    down, and a negative reading has to survive the test.
    """
    val = "float(app.CurrentConditions.Obs['%s'][0])" % key
    numeric = ("app.CurrentConditions.Obs['%s'][0].lstrip('-')"
               ".replace('.', '', 1).isdigit()" % key)
    chain = ''.join("'%s' if %s < %s else " % (hue, val, stop)
                    for stop, hue in zip(stops, hues))
    chain += "'%s'" % hues[-1]
    return ("'[color=' + ((%s) if %s else 'c8c8c8') + ']'" % (chain, numeric))

# Fields whose text rule is a plain value + unit.
DEC_SIMPLE = ['inTemp', 'outTemp', 'FeelsLike', 'DewPoint']

# The min/max fields, which already wrap value and unit in their own
# [size] and [color] tags. Their value renders at 0.88 of the field's
# font size, so the decimal is scaled against that, not against the
# raw font size.
DEC_MINMAX = [('inTempMin',  '00a4b4ff'), ('inTempMax',  'f05e40ff'),
              ('outTempMin', '00a4b4ff'), ('outTempMax', 'f05e40ff')]

# The 24-hour difference and the trend are left alone on purpose:
# they are rates, already drawn small, and the decimal is the signal.


def dec_marker(key):
    """Scale-independent way to spot an already-patched line."""
    return "Obs['%s'][0].split('.')[0]" % key


def dec_targets(scale, sup, unit_scale, pos, unit_min, tint, scales):
    """(stock line, patched line, marker) for every field we touch."""
    open_tag, close_tag = DEC_POS_TAGS.get(pos, (None, None))
    # Fragments of the .kv expression, written out in full rather than
    # assembled by slicing - an earlier version lost a bracket that way.
    dec_pre  = "'[%s][size='" % open_tag if open_tag else "'[size='"
    dec_post = "'[/size][/%s]'" % open_tag if open_tag else "'[/size]'"
    if sup:
        unit_pre  = "'[sup][size='"
        unit_post = "'[/size][/sup]'"
    out = []
    for key in DEC_SIMPLE:
        stock = ("        text: app.CurrentConditions.Obs['%s'][0]"
                 " + app.CurrentConditions.Obs['%s'][1]" % (key, key))
        frac = ("app.CurrentConditions.Obs['%s'][0].split('.')[0]"
                " + %s + str(int(self.font_size*%s)) + ']'"
                " + ('.' + app.CurrentConditions.Obs['%s'][0].split('.')[1]"
                " if '.' in app.CurrentConditions.Obs['%s'][0] else '')"
                " + %s" % (key, dec_pre, scale, key, key, dec_post))
        if sup:
            unit = ("%s + str(int(self.font_size*%s)) + ']'"
                    " + app.CurrentConditions.Obs['%s'][1] + %s"
                    % (unit_pre, unit_scale, key, unit_post))
        else:
            unit = "app.CurrentConditions.Obs['%s'][1]" % key
        if tint and key in TINT_SCALE:
            stops, hues = scales[TINT_SCALE[key]]
            body = ("%s + %s + %s + '[/color]'"
                    % (colour_expr(key, stops, hues), frac, unit))
        else:
            body = "%s + %s" % (frac, unit)
        out.append((stock, "        text: " + body, dec_marker(key)))
    for key, colour in DEC_MINMAX:
        stock = ("        text: '[size=' + str(int(self.font_size*0.88)) + '][color=%s]'"
                 " + app.CurrentConditions.Obs['%s'][0]"
                 " + '[size=' + str(int(self.font_size*0.83)) + ']'"
                 " + app.CurrentConditions.Obs['%s'][1] + '[/color][/size][/size]'"
                 % (colour, key, key))
        frac = ("'[size=' + str(int(self.font_size*0.88)) + '][color=%s]'"
                " + app.CurrentConditions.Obs['%s'][0].split('.')[0]"
                " + %s + str(int(self.font_size*0.88*%s)) + ']'"
                " + ('.' + app.CurrentConditions.Obs['%s'][0].split('.')[1]"
                " if '.' in app.CurrentConditions.Obs['%s'][0] else '')"
                " + %s" % (colour, key, dec_pre, scale, key, key, dec_post))
        if sup:
            # The unit closes its own [size] inside [sup], so the tail
            # carries one [/size] fewer than upstream's. Kivy pops
            # font_size once per closing tag: three pushes here (field,
            # decimal, unit) need exactly three pops, and [sub]/[sup]
            # balance their own.
            unit = ("%s + str(max(int(self.font_size*0.88*%s), %s)) + ']'"
                    " + app.CurrentConditions.Obs['%s'][1]"
                    " + %s + '[/color][/size]'"
                    % (unit_pre, unit_scale, unit_min, key, unit_post))
        else:
            unit = ("'[size=' + str(int(self.font_size*0.83)) + ']'"
                    " + app.CurrentConditions.Obs['%s'][1] + '[/color][/size][/size]'"
                    % key)
        out.append((stock, "        text: %s + %s" % (frac, unit), dec_marker(key)))
    return out


def decimal_patch(scale, sup, unit_scale, pos, unit_min, tint, scales):
    """Forward, reverse and 'is it applied' for the decimal-size patch.

    Line based rather than a literal swap, so that changing the scale
    re-writes a line already patched at the old value instead of
    reporting 'already applied' and doing nothing.
    """
    targets = dec_targets(scale, sup, unit_scale, pos, unit_min, tint, scales)

    def rewrite(text, pick):
        lines = text.split('\n')
        changed = 0
        for i, line in enumerate(lines):
            for stock, patched, marker in targets:
                if line == stock or marker in line:
                    want_line = pick(stock, patched)
                    if line != want_line:
                        lines[i] = want_line
                        changed += 1
                    break
        return '\n'.join(lines), changed

    def forward(text):
        return rewrite(text, lambda stock, patched: patched)

    def backward(text):
        return rewrite(text, lambda stock, patched: stock)

    def applied(text):
        """Patched AT THIS SCALE - so changing the scale re-writes."""
        lines = set(text.split('\n'))
        return all(patched in lines for _, patched, _ in targets)

    def present(text):
        """Patched at any scale - so a revert still finds it."""
        return all(marker in text for _, _, marker in targets)

    return forward, backward, applied, present


# ---- peak sun hours precision ---------------------------------------
# Two decimals on a figure in hours is more precision than the number
# carries. The 'hrs' test keeps this away from the identical battery
# voltage line, where two decimals across 2.4-2.8 V is right.
PEAK_SUN_PAIRS = [("""                if isinstance(psh, str) and psh.strip() == 'hrs':
                    if cObs[ii - 1] is None:
                        cObs[ii - 1] = '-'
                    else:
                        cObs[ii - 1] = '{:.2f}'.format(cObs[ii - 1])
""", """                if isinstance(psh, str) and psh.strip() == 'hrs':
                    if cObs[ii - 1] is None:
                        cObs[ii - 1] = '-'
                    else:
                        cObs[ii - 1] = '{:.1f}'.format(cObs[ii - 1])
""")]


# ---- panel accent colours -------------------------------------------
# Each panel's heading is drawn white by PanelTitle. Colouring them
# per panel is what gives the WS-2902 its liveliness. PanelTitle
# inherits markup from DisplayField, so wrapping the title string is
# enough - no widget changes.
#
# The set is chosen to read as one system rather than as confetti:
# similar saturation and lightness throughout, each one legible on
# black, and where a panel has an obvious colour it gets it (gold for
# solar, cyan for rain).
PANEL_HUES_DEFAULT = {
    'Forecast':    '8ab4f8',
    'Temperature': 'f0a050',
    'Wind Speed':  '9ccc65',
    'Rainfall':    '4fc3d7',
    'Barometer':   'b39ddb',
    'Moon':        'b0bec5',
    'Lightning':   'ff8a65',
    'Sager':       '80cbc4',
    'Solar':       'ffca28',
}

# Which file each title lives in, and the exact stock line. Solar is
# the odd one out - its title already carries [size] markup for the
# divider between "Solar" and "UV".
PANEL_FILES = {
    'Forecast':    ('kvlang/forecast.kv',    "        _panelTitle: 'Forecast'"),
    'Temperature': ('kvlang/temperature.kv', "        _panelTitle: 'Temperature'"),
    'Wind Speed':  ('kvlang/wind.kv',        "        _panelTitle: 'Wind Speed'"),
    'Rainfall':    ('kvlang/rainfall.kv',    "        _panelTitle: 'Rainfall'"),
    'Barometer':   ('kvlang/barometer.kv',   "        _panelTitle: 'Barometer'"),
    'Moon':        ('kvlang/astro.kv',       "        _panelTitle: 'Moon'"),
    'Lightning':   ('kvlang/lightning.kv',   "        _panelTitle: 'Lightning'"),
    'Sager':       ('kvlang/forecast.kv',    "        _panelTitle: 'Sager'"),
    'Solar':       ('kvlang/astro.kv',
                    "        _panelTitle: 'Solar  [size=' + str(int(self.ids.Title.font_size*0.8))"
                    " + ']|[/size]  UV'"),
}


def panel_pairs(hues):
    """(path, stock line, patched line) for every panel title."""
    out = []
    for name, (path, stock) in sorted(PANEL_FILES.items()):
        hue = hues.get(name)
        if not hue:
            continue
        body = stock.split('_panelTitle: ', 1)[1]
        patched = "        _panelTitle: '[color=%s]' + %s + '[/color]'" % (hue, body)
        out.append((path, stock, patched))
    return out


PANEL_MARK = "        _panelTitle: '[color="


def panel_patch(hues):
    """Forward, reverse and state checks for the panel title colours.

    Line based, and a patched line is recognised by its marker plus
    the original title text rather than by an exact match, so that
    changing a colour rewrites the line instead of being read as
    "already applied".
    """
    pairs = panel_pairs(hues)
    paths = sorted({path for path, _, _ in pairs})

    def rewrite(text, path, pick):
        lines = text.split('\n')
        count = 0
        for i, line in enumerate(lines):
            for target, stock, patched in pairs:
                if target != path:
                    continue
                body = stock.split('_panelTitle: ', 1)[1]
                if line == stock or (line.startswith(PANEL_MARK) and body in line):
                    want = pick(stock, patched)
                    if line != want:
                        lines[i] = want
                        count += 1
                    break
        return '\n'.join(lines), count

    def forward(text, path):
        return rewrite(text, path, lambda stock, patched: patched)

    def backward(text, path):
        return rewrite(text, path, lambda stock, patched: stock)

    def applied(text, path):
        return all(patched in text for target, _, patched in pairs if target == path)

    def present(text, path):
        return any(line.startswith(PANEL_MARK) for line in text.split('\n'))

    return paths, forward, backward, applied, present


def run_panels(name, paths, forward, backward, applied, present, want):
    """Apply or revert a patch that spans several files."""
    results = []
    for rel in paths:
        path = os.path.join(ROOT, rel)
        try:
            with open(path) as f:
                text = f.read()
        except OSError as err:
            results.append('cannot read %s: %s' % (rel, err))
            continue
        if want:
            if applied(text, rel):
                continue
            new_text, count = forward(text, rel)
        else:
            if not present(text, rel):
                continue
            new_text, count = backward(text, rel)
        if count:
            with open(path, 'w') as f:
                f.write(new_text)
            results.append('%s (%d)' % (rel.split('/')[-1], count))
    if not want:
        return '%s: off%s' % (name, ' - reverted ' + ', '.join(results) if results else '')
    if not results:
        return '%s: already applied' % name
    return '%s: applied %s' % (name, ', '.join(results))


def text_patch(pairs):
    """Forward, reverse and 'is it applied' for a set of literal swaps."""
    def forward(text):
        n = 0
        for original, patched in pairs:
            count = text.count(original)
            if count:
                text = text.replace(original, patched)
                n += count
        return text, n

    def backward(text):
        n = 0
        for original, patched in pairs:
            count = text.count(patched)
            if count:
                text = text.replace(patched, original)
                n += count
        return text, n

    def applied(text):
        return all(patched in text for _, patched in pairs)

    # For these, "patched at the current setting" and "patched at all"
    # are the same question.
    return forward, backward, applied, applied


def run(name, relpath, forward, backward, applied, present, want):
    """Apply or revert one patch. Returns a short status line."""
    path = os.path.join(ROOT, relpath)
    try:
        with open(path) as f:
            text = f.read()
    except OSError as err:
        return f"{name}: cannot read {path}: {err}"

    if want:
        if applied(text):
            return f"{name}: already applied"
        new_text, count = forward(text)
        if not count:
            return (f"{name}: no match - PiConsole's code has changed "
                    "upstream; check whether this patch is still needed")
        with open(path, 'w') as f:      # in place: keeps owner and mode
            f.write(new_text)
        return f"{name}: applied ({count})"

    if not present(text):
        return f"{name}: off"
    if backward is None:
        return (f"{name}: off, but this one has no automatic reverse - "
                "'wfpiconsole update' will restore the stock file")
    new_text, count = backward(text)
    with open(path, 'w') as f:
        f.write(new_text)
    return f"{name}: reverted ({count})"


(want, dec_scale, dec_sup, dec_unit, dec_pos, dec_umin,
 dec_tint, dec_scales, panel_hues) = settings()
status = [
    run('square-dials', os.path.join('kvlang', 'layout.kv'),
        lambda t: DIALS_ORIGINAL.subn(dials_patch, t),
        None,
        lambda t: bool(DIALS_DONE.search(t)),
        lambda t: bool(DIALS_DONE.search(t)),
        want['square-dials']),
    run('udp-obs-length', os.path.join('lib', 'observation_parser.py'),
        *udp_patch(), want['udp-obs-length']),
    run('sager-metar-clouds', os.path.join('lib', 'sager.py'),
        *text_patch(SAGER_PAIRS), want['sager-metar-clouds']),
    run('pressure-precision', os.path.join('lib', 'observation_format.py'),
        *text_patch(PRESSURE_PAIRS), want['pressure-precision']),
    run('temp-whole-degrees', os.path.join('lib', 'observation_format.py'),
        *text_patch(WHOLE_DEG_PAIRS), want['temp-whole-degrees']),
    run('temp-decimal-size', os.path.join('kvlang', 'temperature.kv'),
        *decimal_patch(dec_scale, dec_sup, dec_unit, dec_pos, dec_umin,
                       dec_tint, dec_scales),
        want['temp-decimal-size']),
    run('peak-sun-precision', os.path.join('lib', 'observation_format.py'),
        *text_patch(PEAK_SUN_PAIRS), want['peak-sun-precision']),
    run_panels('panel-accents', *panel_patch(panel_hues), want['panel-accents']),
]
for line in status:
    print(line)
sys.exit(0)
PYEOF
sudo chmod 755 "$SCRIPT"

if [ -f "$CONF" ]; then
    echo "Keeping your existing $CONF"
else
    echo "Creating $CONF"
    sudo tee "$CONF" > /dev/null << 'EOF'
# Which PiConsole patches to apply. Set one to 'off' and run
#   sudo wfpiconsole-patches ~/wfpiconsole
# to undo it - the script reverts a patch you switch off, it does
# not merely stop re-applying it. Then restart the console.
#
# square-dials is the exception: it has no automatic reverse.
# Turning it off stops it being re-applied, and the next
# 'wfpiconsole update' restores the stock layout.

square-dials       = on
udp-obs-length     = on
sager-metar-clouds = on
pressure-precision = on

# Two answers to the same thing - temperature showing more decimals
# than the sensor can resolve. Turn ONE of them on, not both:
#   temp-whole-degrees   72.1 F becomes 72 F
#   temp-decimal-size    72.1 F keeps the .1, drawn smaller
temp-whole-degrees = off
temp-decimal-size  = on

# How big the decimal is drawn, as a fraction of the digits beside
# it. This also sets its height: Kivy places a smaller span lower on
# the line, so a LARGER value sits HIGHER. Raise it if the decimal
# reads too low, lower it if it reads too heavy. Allowed 0.3 to 1.0;
# re-run the script after changing it.
temp-decimal-scale = 0.65

# Where the decimal sits. Kivy offers three positions and nothing
# between them:
#   baseline  bottom aligned with the digits, as the WS-2902 draws it
#   normal    the renderer's own placement, floating between middle
#             and bottom
#   raised    a true superscript, top aligned
temp-decimal-position = normal

# Draw the unit small and raised, the way the WS-2902 does, on the
# outdoor, indoor, Feels Like and Dew Point readings. Off leaves it
# full size on the baseline, as upstream has it.
temp-unit-superscript = on

# How big that raised unit is, as a fraction of the digits beside it.
# [sup] alone would give 0.5. Allowed 0.2 to 1.0.
temp-unit-scale = 0.45

# Smallest the unit may get, in pixels. Only bites on the min/max
# fields, whose digits are already reduced.
temp-unit-min-px = 6

# Peak Sun Hours to one decimal instead of two.
peak-sun-precision = on
EOF
fi

echo "Installing systemd watcher"
sudo tee "$UNITS/wfpiconsole-patches.service" > /dev/null << EOF
[Unit]
Description=Re-apply local PiConsole patches

[Service]
Type=oneshot
User=$CONSOLE_USER
ExecStart=$SCRIPT $WFPC
EOF

sudo tee "$UNITS/wfpiconsole-patches.path" > /dev/null << EOF
[Unit]
Description=Watch PiConsole files and re-apply local patches when they change

[Path]
PathChanged=$WFPC/kvlang/layout.kv
PathChanged=$WFPC/kvlang/temperature.kv
PathChanged=$WFPC/lib/observation_parser.py
PathChanged=$WFPC/lib/observation_format.py
PathChanged=$WFPC/lib/sager.py
Unit=wfpiconsole-patches.service

[Install]
WantedBy=multi-user.target
EOF

echo "Installing autostart backstop"
sudo mkdir -p "$UNITS/wfpiconsole.service.d"
sudo tee "$UNITS/wfpiconsole.service.d/patches.conf" > /dev/null << EOF
# Re-apply local patches before every autostart. Lives in a drop-in,
# so 'wfpiconsole autostart-enable' rewriting the main unit can't
# remove it.
[Service]
ExecStartPre=$SCRIPT $WFPC
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now wfpiconsole-patches.path

echo
echo "Applying now:"
"$SCRIPT" "$WFPC"
echo
echo "Done. Restart the console for any change to take effect."
echo "To turn a patch on or off, edit $CONF and run:"
echo "  $SCRIPT $WFPC"
