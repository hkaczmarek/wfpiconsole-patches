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

     Size, and height, are set by temp-decimal-scale in the conf
     file. Kivy offers inline text three vertical positions -
     superscript, normal, subscript - and no pixel offset, so on
     normal positioning the renderer places a span at
     (line_height - word_height) / 1.25. A larger span therefore
     sits higher, which makes the scale the only fine adjustment
     available for height as well as size.
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
}


def settings():
    """Read the conf file. Returns (on/off per patch, decimal scale)."""
    state = dict(DEFAULTS)
    scale = DEC_SCALE_DEFAULT
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
    except OSError:
        pass
    return state, scale


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
UDP_PAIRS = [("""        if bool(int(config['System']['nc_rain'])):
            self.device_obs['minuteRain'] = [latest_ob[19], 'mm']
            self.device_obs['dailyRain']  = [latest_ob[20], 'mm']
        else:
            self.device_obs['minuteRain'] = [latest_ob[12], 'mm']
            self.device_obs['dailyRain']  = [latest_ob[18], 'mm']
""", """        # UDP obs_st carries 18 fields (0-17). Indices 18-21 exist
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
""")]


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


def dec_targets(scale):
    """(stock line, patched line, marker) for every field we touch."""
    out = []
    for key in DEC_SIMPLE:
        stock = ("        text: app.CurrentConditions.Obs['%s'][0]"
                 " + app.CurrentConditions.Obs['%s'][1]" % (key, key))
        patched = ("        text: app.CurrentConditions.Obs['%s'][0].split('.')[0]"
                   " + '[size=' + str(int(self.font_size*%s)) + ']'"
                   " + ('.' + app.CurrentConditions.Obs['%s'][0].split('.')[1]"
                   " if '.' in app.CurrentConditions.Obs['%s'][0] else '')"
                   " + '[/size]' + app.CurrentConditions.Obs['%s'][1]"
                   % (key, scale, key, key, key))
        out.append((stock, patched, dec_marker(key)))
    for key, colour in DEC_MINMAX:
        stock = ("        text: '[size=' + str(int(self.font_size*0.88)) + '][color=%s]'"
                 " + app.CurrentConditions.Obs['%s'][0]"
                 " + '[size=' + str(int(self.font_size*0.83)) + ']'"
                 " + app.CurrentConditions.Obs['%s'][1] + '[/color][/size][/size]'"
                 % (colour, key, key))
        patched = ("        text: '[size=' + str(int(self.font_size*0.88)) + '][color=%s]'"
                   " + app.CurrentConditions.Obs['%s'][0].split('.')[0]"
                   " + '[size=' + str(int(self.font_size*0.88*%s)) + ']'"
                   " + ('.' + app.CurrentConditions.Obs['%s'][0].split('.')[1]"
                   " if '.' in app.CurrentConditions.Obs['%s'][0] else '')"
                   " + '[/size]' + '[size=' + str(int(self.font_size*0.83)) + ']'"
                   " + app.CurrentConditions.Obs['%s'][1] + '[/color][/size][/size]'"
                   % (colour, key, scale, key, key, key))
        out.append((stock, patched, dec_marker(key)))
    return out


def decimal_patch(scale):
    """Forward, reverse and 'is it applied' for the decimal-size patch.

    Line based rather than a literal swap, so that changing the scale
    re-writes a line already patched at the old value instead of
    reporting 'already applied' and doing nothing.
    """
    targets = dec_targets(scale)

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


want, dec_scale = settings()
status = [
    run('square-dials', os.path.join('kvlang', 'layout.kv'),
        lambda t: DIALS_ORIGINAL.subn(dials_patch, t),
        None,
        lambda t: bool(DIALS_DONE.search(t)),
        lambda t: bool(DIALS_DONE.search(t)),
        want['square-dials']),
    run('udp-obs-length', os.path.join('lib', 'observation_parser.py'),
        *text_patch(UDP_PAIRS), want['udp-obs-length']),
    run('sager-metar-clouds', os.path.join('lib', 'sager.py'),
        *text_patch(SAGER_PAIRS), want['sager-metar-clouds']),
    run('pressure-precision', os.path.join('lib', 'observation_format.py'),
        *text_patch(PRESSURE_PAIRS), want['pressure-precision']),
    run('temp-whole-degrees', os.path.join('lib', 'observation_format.py'),
        *text_patch(WHOLE_DEG_PAIRS), want['temp-whole-degrees']),
    run('temp-decimal-size', os.path.join('kvlang', 'temperature.kv'),
        *decimal_patch(dec_scale), want['temp-decimal-size']),
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
