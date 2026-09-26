#!/bin/bash
# =============================================================
# install-wfpiconsole-patches.sh
#
# Keeps local fixes to WeatherFlow PiConsole applied, including
# after `wfpiconsole update`, which restores the stock files.
#
#   1. square dials       kvlang/layout.kv
#   2. udp obs length     lib/observation_parser.py
#   3. sager metar clouds lib/sager.py
#   4. display precision  lib/observation_format.py
#
# All four are described in the patch script itself.
#
# Installs:
#   /usr/local/bin/wfpiconsole-patches        the idempotent fixes
#   wfpiconsole-patches.path/.service         re-run them whenever
#                                             either file changes
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
    echo "Removed. The patched files are left as-is; 'wfpiconsole update' restores stock."
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

  1. SQUARE DIALS (kvlang/layout.kv)
     The wind, moon and barometer dials are sized as fractions of
     their panel's width and height separately, then squared by
     trimming one side - but the side is chosen from the PANEL's
     shape, not the dial's. On the 800x480 display PiConsole was
     designed for, the result is square. On 1280x800 the dial's
     width is the shorter side and nothing trims the height, so
     every dial draws ~15% taller than wide. Fix: both sides take
     the smaller proportional size.

  2. UDP OBSERVATION LENGTH (lib/observation_parser.py)
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

  3. SAGER METAR CLOUDS (lib/sager.py)
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

  4. DISPLAY PRECISION (lib/observation_format.py)
     Two values are shown to more decimals than the instrument can
     resolve. Temperature prints as 72.1 F, but the Tempest is
     spec'd at +/-0.3 C (+/-0.5 F), so the tenth is noise wearing
     the costume of precision - integers. Pressure prints as
     29.921 inHg, a resolution of about 0.03 hPa against a +/-1
     hPa sensor, and two decimals is how everyone reads an
     altimeter setting anyway.

     Both rate-of-change figures keep their decimals: a trend of a
     few tenths of a degree, or a few thousandths of an inch, per
     hour IS the signal, and rounding it would flatten it to zero.
"""
import os
import re
import sys

ROOT = os.path.expanduser(sys.argv[1] if len(sys.argv) > 1 else '~/wfpiconsole')


# ---- 1. square dials ------------------------------------------------
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


# ---- 2. UDP observation length --------------------------------------
UDP_ORIGINAL = """        if bool(int(config['System']['nc_rain'])):
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
UDP_DONE = "def _field(index):"


# ---- 3. Sager METAR clouds ------------------------------------------
SAGER_ORIGINAL = """            self.sager_data['METAR'] = None
            for METAR in METAR_data:
                if 'clouds' in METAR:
                    self.sager_data['METAR'] = METAR['raw_text']
                    break
"""
SAGER_PATCHED = """            # A clear-sky report - SKC, CLR, CAVOK, NCD, NSC - has no
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
"""
SAGER_DONE = "_ccodes = ('CAVOK', 'CLR', 'NCD', 'NSC', 'SKC',"


# ---- 4. display precision -------------------------------------------
# Temperature to whole degrees. The trailing "if T.strip() == 'c':"
# pins this to the temperature branch and away from the identical
# looking rate-of-change branch just below it.
TEMP_ORIGINAL = """                    elif round(cObs[ii - 1], 1) == 0.0:
                        cObs[ii - 1] = '{:.1f}'.format(abs(cObs[ii - 1]))
                    else:
                        cObs[ii - 1] = '{:.1f}'.format(cObs[ii - 1])
                    if T.strip() == 'c':
"""
TEMP_PATCHED = """                    elif round(cObs[ii - 1], 0) == 0.0:
                        cObs[ii - 1] = '{:.0f}'.format(abs(cObs[ii - 1]))
                    else:
                        cObs[ii - 1] = '{:.0f}'.format(cObs[ii - 1])
                    if T.strip() == 'c':
"""
TEMP_DONE = """                        cObs[ii - 1] = '{:.0f}'.format(cObs[ii - 1])
                    if T.strip() == 'c':
"""

# Pressure in inHg to two decimals, splitting it from the hourly
# trend, which the original formats on the same branch.
PRES_ORIGINAL = """                        if P.strip() in ['inHg/hr', 'inHg']:
                            if round(cObs[ii - 1], 3) == 0.0:
                                cObs[ii - 1] = '{:.3f}'.format(abs(cObs[ii - 1]))
                            else:
                                cObs[ii - 1] = '{:.3f}'.format(cObs[ii - 1])
"""
PRES_PATCHED = """                        if P.strip() == 'inHg':
                            if round(cObs[ii - 1], 2) == 0.0:
                                cObs[ii - 1] = '{:.2f}'.format(abs(cObs[ii - 1]))
                            else:
                                cObs[ii - 1] = '{:.2f}'.format(cObs[ii - 1])
                        elif P.strip() == 'inHg/hr':
                            if round(cObs[ii - 1], 3) == 0.0:
                                cObs[ii - 1] = '{:.3f}'.format(abs(cObs[ii - 1]))
                            else:
                                cObs[ii - 1] = '{:.3f}'.format(cObs[ii - 1])
"""
PRES_DONE = "if P.strip() == 'inHg':"


def precision_patch(text):
    count = 0
    for original, patched in ((TEMP_ORIGINAL, TEMP_PATCHED),
                              (PRES_ORIGINAL, PRES_PATCHED)):
        n = text.count(original)
        if n:
            text = text.replace(original, patched)
            count += n
    return text, count


def apply(name, path, change, done_marker):
    """Apply one patch. Returns a short status line."""
    try:
        with open(path) as f:
            text = f.read()
    except OSError as err:
        return f"{name}: cannot read {path}: {err}"
    new_text, count = change(text)
    if count:
        with open(path, 'w') as f:      # in place: keeps owner and mode
            f.write(new_text)
        return f"{name}: applied ({count})"
    if done_marker(text):
        return f"{name}: already applied"
    return (f"{name}: no match - PiConsole's code has changed upstream; "
            "check whether this patch is still needed")


status = [
    apply("square-dials",
          os.path.join(ROOT, 'kvlang', 'layout.kv'),
          lambda t: DIALS_ORIGINAL.subn(dials_patch, t),
          lambda t: bool(DIALS_DONE.search(t))),
    apply("udp-obs-length",
          os.path.join(ROOT, 'lib', 'observation_parser.py'),
          lambda t: (t.replace(UDP_ORIGINAL, UDP_PATCHED), t.count(UDP_ORIGINAL)),
          lambda t: UDP_DONE in t),
    apply("sager-metar-clouds",
          os.path.join(ROOT, 'lib', 'sager.py'),
          lambda t: (t.replace(SAGER_ORIGINAL, SAGER_PATCHED), t.count(SAGER_ORIGINAL)),
          lambda t: SAGER_DONE in t),
    apply("display-precision",
          os.path.join(ROOT, 'lib', 'observation_format.py'),
          precision_patch,
          lambda t: TEMP_DONE in t and PRES_DONE in t),
]
for line in status:
    print(line)
sys.exit(0)
PYEOF
sudo chmod 755 "$SCRIPT"

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
PathChanged=$WFPC/lib/observation_parser.py
PathChanged=$WFPC/lib/sager.py
PathChanged=$WFPC/lib/observation_format.py
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
