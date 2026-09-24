#!/bin/bash
# =============================================================
# install-wfpiconsole-patches.sh
#
# Keeps local fixes to WeatherFlow PiConsole applied, including
# after `wfpiconsole update`, which restores the stock files.
#
#   1. square dials      kvlang/layout.kv
#   2. udp obs length    lib/observation_parser.py
#
# Both are described in the patch script itself.
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
