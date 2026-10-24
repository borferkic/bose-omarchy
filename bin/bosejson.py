#!/usr/bin/env python3
"""JSON front end to the bundled pybmap library, for the Omarchy widget.

One invocation opens the RFCOMM link, does one thing and closes it, so the
headphones stay free for the phone app in between. Always prints a single JSON
object on stdout: {"ok": true, ...} or {"ok": false, "error": CODE, "message": TEXT}.
Run it as `python3 -I bosejson.py ...`; the bundled library is found next to it.
"""

import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))

import pybmap  # noqa: E402
from pybmap import errors  # noqa: E402

SPATIAL = {0: "off", 1: "room", 2: "head"}
BOOLS = {"on": True, "off": False, "1": True, "0": False, "true": True, "false": False}


def out(obj):
    print(json.dumps(obj, ensure_ascii=False))


def fail(code, message):
    out({"ok": False, "error": code, "message": str(message)})
    sys.exit(1)


def safe(fn, default=None):
    try:
        return fn()
    except errors.BmapError:
        return default
    except Exception:
        return default


def status(dev):
    s = dev.status()
    audio = safe(dev.audio_settings)
    modes = safe(dev.modes, {}) or {}
    profiles = []
    for idx in sorted(modes):
        m = modes[idx]
        if not m.editable and not m.configured and idx > 4:
            continue
        if m.editable and not m.configured:
            continue
        profiles.append({
            "idx": idx, "name": m.name, "preset": not m.editable,
            "cnc": m.cnc_level, "spatial": SPATIAL.get(m.spatial, "off"),
            "wind": bool(m.wind_block),
        })
    btn = safe(dev.buttons)
    src = safe(dev.source)
    return {
        "ok": True,
        "model": dev.device_info.get("name", "Bose"),
        "battery": s.battery,
        "mode": s.mode,
        "modeIdx": s.mode_idx,
        "cnc": s.cnc_level,
        "cncMax": s.cnc_max,
        "eq": [{"name": b.name, "min": b.min_val, "max": b.max_val, "value": b.current}
               for b in (s.eq or [])],
        "name": s.name,
        "firmware": s.firmware,
        "sidetone": s.sidetone,
        "multipoint": bool(s.multipoint),
        "autoPause": bool(s.auto_pause),
        "autoAnswer": bool(safe(dev.auto_answer, False)),
        "prompts": bool(s.prompts_enabled),
        "promptsLanguage": s.prompts_language,
        "spatial": SPATIAL.get(audio.spatial, "off") if audio else None,
        "wind": bool(audio.wind_block) if audio else None,
        "anc": bool(audio.anc_toggle) if audio else None,
        "presets": list(dev.preset_modes.keys()),
        "profiles": profiles,
        "button": ({"name": btn.button_name, "event": btn.event_name,
                    "action": btn.action_name, "supported": list(btn.supported_actions or [])}
                   if btn else None),
        "source": ({"type": src.source_type, "mac": src.source_mac} if src else None),
    }


def need(args, n, usage):
    if len(args) < n:
        fail("usage", usage)


def flag(value):
    if value.lower() not in BOOLS:
        fail("usage", "expected on|off, got %r" % value)
    return BOOLS[value.lower()]


def act(dev, cmd, args):
    if cmd == "status":
        return status(dev)
    if cmd == "battery":
        return {"ok": True, "battery": dev.battery()}
    if cmd == "mode":
        need(args, 1, "mode NAME")
        dev.set_mode(" ".join(args))
    elif cmd == "cnc":
        need(args, 1, "cnc 0-10")
        dev.set_cnc(int(args[0]))
    elif cmd == "eq":
        need(args, 3, "eq BASS MID TREBLE")
        dev.set_eq(*[int(a) for a in args[:3]])
    elif cmd == "spatial":
        need(args, 1, "spatial off|room|head")
        dev.set_spatial(args[0].lower())
    elif cmd == "anc":
        need(args, 1, "anc on|off")
        dev.set_anc(flag(args[0]))
    elif cmd == "wind":
        need(args, 1, "wind on|off")
        dev.set_wind(flag(args[0]))
    elif cmd == "sidetone":
        need(args, 1, "sidetone off|low|medium|high")
        dev.set_sidetone(args[0].lower())
    elif cmd == "multipoint":
        need(args, 1, "multipoint on|off")
        dev.set_multipoint(flag(args[0]))
    elif cmd == "autopause":
        need(args, 1, "autopause on|off")
        dev.set_auto_pause(flag(args[0]))
    elif cmd == "autoanswer":
        need(args, 1, "autoanswer on|off")
        dev.set_auto_answer(flag(args[0]))
    elif cmd == "prompts":
        need(args, 1, "prompts on|off")
        dev.set_prompts(flag(args[0]))
    elif cmd == "name":
        need(args, 1, "name TEXT")
        dev.set_name(" ".join(args))
    elif cmd == "button":
        need(args, 1, "button ACTION")
        btn = dev.buttons()
        if btn is None:
            fail("unsupported", "button config not readable")
        dev.set_buttons(btn.button_id, btn.event, args[0])
    elif cmd == "route":
        need(args, 1, "route MAC")
        dev.route(args[0])
    elif cmd == "pair":
        dev.pair()
    elif cmd == "off":
        dev.power_off()
    else:
        fail("usage", "unknown command %r" % cmd)
    return {"ok": True}


def main():
    if len(sys.argv) < 2:
        fail("usage", "bosejson.py COMMAND [ARGS]")
    cmd, args = sys.argv[1].lower(), sys.argv[2:]
    try:
        dev = pybmap.connect(mac=os.environ.get("BMAP_MAC") or None,
                             device_type=os.environ.get("BMAP_DEVICE") or None)
    except errors.BmapNotFoundError as e:
        fail("not_found", e)
    except errors.BmapBusyError as e:
        fail("busy", e)
    except errors.BmapError as e:
        fail("connection", e)
    try:
        out(act(dev, cmd, args))
    except errors.BmapError as e:
        fail("device", e)
    except ValueError as e:
        fail("usage", e)
    finally:
        dev.close()


if __name__ == "__main__":
    main()
