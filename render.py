#!/usr/bin/env python3
"""kindle-dash: render a 600x800 e-ink dashboard PNG from Home Assistant.

No HA credentials or config live on the Kindle: it fetches one PNG and blits it
to the framebuffer with eips. All state, maths and layout happen here.
"""
from __future__ import annotations

import datetime as dt
import functools
import json
import os
import sys
import time
import tomllib
import urllib.parse
import urllib.request
from pathlib import Path
from zoneinfo import ZoneInfo

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent

# The panel has exactly one hard external dependency besides Pillow: DejaVu.
# Do not assume one path - a Debian container without fonts-dejavu-core fails
# here with a bare "cannot open resource" from inside PIL.
FONT_DIRS = [
    "/usr/share/fonts/truetype/dejavu",
    "/usr/share/fonts/TTF",
    "/usr/share/fonts/truetype/ttf-dejavu",
    "/usr/share/fonts",
]


def find_font_dir(configured: str | None = None) -> str:
    for d in ([configured] if configured else []) + FONT_DIRS:
        if d and os.path.isfile(os.path.join(d, "DejaVuSans.ttf")):
            return d
    raise SystemExit(
        "DejaVuSans.ttf not found. Install it (apt-get install fonts-dejavu-core) "
        "or set [display].font_dir in config.toml."
    )


FONT_DIR = find_font_dir()

BLACK, DARK, MID, LIGHT = 0, 60, 120, 200

# Weather condition -> (glyph, label)
CONDITIONS = {
    "sunny": ("\u2600", "sunny"),
    "clear-night": ("\u263e", "clear"),
    "partlycloudy": ("\u2600\u2601", "partly cloudy"),
    "cloudy": ("\u2601", "cloudy"),
    "fog": ("\u2261", "fog"),
    "hail": ("\u2602", "hail"),
    "lightning": ("\u26a1", "thunder"),
    "lightning-rainy": ("\u26a1", "thunder"),
    "pouring": ("\u2602", "downpour"),
    "rainy": ("\u2602", "rain"),
    "snowy": ("\u2744", "snow"),
    "snowy-rainy": ("\u2744", "sleet"),
    "windy": ("\u2248", "windy"),
    "windy-variant": ("\u2248", "windy"),
    "exceptional": ("!", "exceptional"),
}

# All on-screen words live here so a different language is a config change.
DEFAULT_TEXT = {
    "feels": "feels",
    "today": "today",
    "tariff": "tariff",
    "sun": "sun",
    "sun_setting": "sunset",
    "active": "DRAWING NOW",
    "idle": "nothing drawing",
    "updated": "updated",
    "open": "OPEN",
    "doors_closed": "doors closed",
}

_NUM_DECIMAL = "."


# ---------------------------------------------------------------- helpers
@functools.lru_cache(maxsize=64)
def font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    name = "DejaVuSans-Bold.ttf" if bold else "DejaVuSans.ttf"
    return ImageFont.truetype(os.path.join(FONT_DIR, name), size)


def set_number_style(style: str) -> None:
    """'.' = 1,234.5 (english) · ',' = 1 234,5 (dutch)."""
    global _NUM_DECIMAL
    _NUM_DECIMAL = "," if style == "comma" else "."


def num(value, decimals=1, dash="\u2013") -> str:
    """Format a number with a real minus sign and no negative zero."""
    if value is None:
        return dash
    if abs(value) < 0.5 * 10 ** -decimals:
        value = 0.0
    s = f"{value:,.{decimals}f}"
    if _NUM_DECIMAL == ",":
        s = s.replace(",", "\u00a0").replace(".", ",")
    return s.replace("-", "\u2212")


def load_config(path: Path | None = None, demo: bool = False) -> dict:
    if path is None:
        # a fresh clone has only the example: it is demo-safe as-is
        path = ROOT / "config.toml"
        if not path.exists():
            path = ROOT / "config.example.toml"
    with open(path, "rb") as fh:
        cfg = tomllib.load(fh)
    cfg["_text"] = {**DEFAULT_TEXT, **cfg.get("text", {})}
    if cfg.get("display", {}).get("font_dir"):
        global FONT_DIR
        FONT_DIR = find_font_dir(cfg["display"]["font_dir"])
    cfg["_demo"] = demo
    if demo:
        cfg["_token"] = ""
        return cfg
    token = os.environ.get(cfg["ha"].get("token_env", "HASS_TOKEN"))
    if not token:
        env_file = Path(os.path.expanduser(cfg["ha"].get("token_file", "~/.config/kindle-dash/token")))
        if env_file.exists():
            wanted = cfg["ha"].get("token_env", "HASS_TOKEN")
            for line in env_file.read_text().splitlines():
                if line.strip().startswith(wanted + "="):
                    token = line.split("=", 1)[1].strip().strip("'\"")
                    break
    if not token:
        sys.exit("no HA token: set HASS_TOKEN or point [ha].token_file at a dotenv")
    cfg["_token"] = token
    return cfg


# ---------------------------------------------------------------- HA client
class HA:
    def __init__(self, url: str, token: str):
        self.base = url.rstrip("/")
        self.token = token

    def _req(self, path: str, data: dict | None = None):
        url = self.base + path
        body = json.dumps(data).encode() if data is not None else None
        req = urllib.request.Request(
            url,
            data=body,
            headers={"Authorization": f"Bearer {self.token}", "Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read() or b"null")

    def states(self) -> dict[str, dict]:
        return {s["entity_id"]: s for s in self._req("/api/states")}

    def forecast_daily(self, entity: str, days: int = 5) -> list[dict]:
        try:
            out = self._req(
                "/api/services/weather/get_forecasts?return_response=true",
                {"entity_id": entity, "type": "daily"},
            )
            return (out.get("service_response", {}).get(entity, {}) or {}).get("forecast", [])[:days]
        except Exception as exc:  # forecast is nice-to-have, never fatal
            print(f"forecast failed: {exc}", file=sys.stderr)
            return []

    def value_at(self, entities: list[str], when: dt.datetime) -> dict[str, float]:
        """First recorded state of each entity at/after `when`."""
        if not entities:
            return {}
        stamp = urllib.parse.quote(when.isoformat(), safe="")
        qs = urllib.parse.urlencode(
            {"filter_entity_id": ",".join(entities), "minimal_response": "", "no_attributes": ""}
        )
        rows = self._req(f"/api/history/period/{stamp}?{qs}")
        out: dict[str, float] = {}
        for series in rows:
            if not series:
                continue
            entity = series[0].get("entity_id")
            if not entity:
                continue
            out[entity] = _to_float(series[0].get("state"))
        return out


# ---------------------------------------------------------------- demo client
# Canned data so the panel can be rendered, screenshotted and regression checked
# without Home Assistant and without a token:
#
#   python3 render.py --demo out/demo.png
#
# The entity ids line up with config.example.toml, so `--demo` plus that config
# produces a representative frame.
_DEMO_MIDNIGHT = {
    "sensor.electricity_meter_tariff_1": 3421.40,
    "sensor.electricity_meter_tariff_2": 2890.10,
    "sensor.electricity_meter_tariff_1_cost": 1002.31,
    "sensor.electricity_meter_tariff_2_cost": 780.14,
    "sensor.gas_meter_gas": 1204.28,
    "sensor.gas_meter_gas_cost": 1519.90,
}
_DEMO_CONSUMED = {
    "sensor.electricity_meter_tariff_1": 9.42,
    "sensor.electricity_meter_tariff_2": 7.68,
    "sensor.electricity_meter_tariff_1_cost": 3.07,
    "sensor.electricity_meter_tariff_2_cost": 2.19,
    "sensor.gas_meter_gas": 2.05,
    "sensor.gas_meter_gas_cost": 3.28,
}
_DEMO_CONSUMERS = {
    "sensor.washer_power": 312.0,
    "sensor.fridge_power": 61.0,
    "sensor.server_power": 48.0,
    "sensor.office_plug_power": 22.0,
    "sensor.tv_power": 9.0,
    "sensor.living_room_lights_power": 4.0,
    "sensor.garden_plug_power": 0.0,
}
_DEMO_DAYS = [
    ("rainy", 7, 2), ("partlycloudy", 8, 3), ("cloudy", 6, 1),
    ("sunny", 4, -1), ("snowy", 3, -2),
]


class DemoHA:
    """Same interface as HA, canned contents. No network, no credentials."""

    def __init__(self, tz):
        self.tz = tz

    def states(self) -> dict[str, dict]:
        now = dt.datetime.now(self.tz)
        rising = now.replace(hour=8, minute=12, second=0, microsecond=0)
        setting = now.replace(hour=16, minute=48, second=0, microsecond=0)
        if rising <= now:
            rising += dt.timedelta(days=1)
        if setting <= now:
            setting += dt.timedelta(days=1)
        states = {
            "weather.home": {
                "state": "partlycloudy",
                "attributes": {"temperature": 6.3, "apparent_temperature": 2.1,
                               "humidity": 82, "wind_speed": 14},
            },
            "sun.sun": {
                "state": "above_horizon",
                "attributes": {"next_rising": rising.isoformat(),
                               "next_setting": setting.isoformat()},
            },
            "sensor.electricity_meter_tariff": {"state": "low", "attributes": {}},
        }
        for entity, base in _DEMO_MIDNIGHT.items():
            states[entity] = {"state": base + _DEMO_CONSUMED[entity], "attributes": {}}
        for entity, watts in _DEMO_CONSUMERS.items():
            states[entity] = {"state": watts, "attributes": {}}
        for entity in ("binary_sensor.front_door", "binary_sensor.garage_door"):
            states[entity] = {"state": "off", "attributes": {}}
        states["binary_sensor.garden_door"] = {"state": "on", "attributes": {}}
        return states

    def forecast_daily(self, entity: str, days: int = 5) -> list[dict]:
        today = dt.datetime.now(self.tz).replace(hour=12, minute=0, second=0, microsecond=0)
        return [
            {"datetime": (today + dt.timedelta(days=i)).isoformat(),
             "condition": condition, "temperature": high, "templow": low}
            for i, (condition, high, low) in enumerate(_DEMO_DAYS[:days])
        ]

    def value_at(self, entities: list[str], when: dt.datetime) -> dict[str, float]:
        return {e: _DEMO_MIDNIGHT[e] for e in entities if e in _DEMO_MIDNIGHT}


def _to_float(value) -> float | None:
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


# ---------------------------------------------------------------- drawing
class Canvas:
    def __init__(self, width: int, height: int, scale: int = 2, ox: int = 0, oy: int = 0):
        # draw at 2x and downsample: text and icons stay smooth on 16 greys
        self.s = scale
        self.w, self.h = width, height
        self.ox, self.oy = ox, oy          # whole-layout shift, for burn-in mitigation
        self.img = Image.new("L", (width * scale, height * scale), 255)
        self.d = ImageDraw.Draw(self.img)

    def text(self, xy, s, size, bold=False, fill=BLACK, anchor="la"):
        self.d.text(((xy[0] + self.ox) * self.s, (xy[1] + self.oy) * self.s), s,
                    font=font(int(size * self.s), bold), fill=fill, anchor=anchor)

    def text_width(self, s, size, bold=False) -> float:
        return font(int(size * self.s), bold).getlength(s) / self.s

    def glyph(self, xy, s, size, fill=BLACK, anchor="la"):
        self.text(xy, s, size, False, fill, anchor)

    def bar(self, x1, y1, x2, y2, fill=BLACK):
        self.d.rectangle([(x1 + self.ox) * self.s, (y1 + self.oy) * self.s,
                          (x2 + self.ox) * self.s, (y2 + self.oy) * self.s], fill=fill)

    def rule(self, x1, y1, x2, y2, width=1, fill=BLACK):
        self.d.line([((x1 + self.ox) * self.s, (y1 + self.oy) * self.s),
                     ((x2 + self.ox) * self.s, (y2 + self.oy) * self.s)],
                    fill=fill, width=max(1, int(width * self.s)))

    def finish(self, levels: int = 16) -> Image.Image:
        img = self.img.resize((self.w, self.h), Image.LANCZOS)
        if levels and levels < 256:
            step = 255 / (levels - 1)
            img = img.point(lambda v: int(round(v / step) * step))
        return img


def open_doors(cfg: dict, states: dict) -> list[str]:
    """Labels of doors/windows currently open (`on` for a door binary_sensor)."""
    return [label for entity, label in cfg.get("doors", {}).items()
            if states.get(entity, {}).get("state") == "on"]


def draw_open_bar(c: Canvas, cfg: dict, labels: list[str], y0: float) -> float:
    """Inverse bar, only when something is actually open: unmissable from 3 m."""
    height = 42
    c.bar(32, y0, 568, y0 + height, BLACK)

    room = 500
    shown: list[str] = []
    for label in labels:
        trial = " \u00b7 ".join(shown + [label])
        if shown and c.text_width(trial, 20, True) > room:
            break
        shown.append(label)
    extra = len(labels) - len(shown)
    body = " \u00b7 ".join(shown) + (f" +{extra}" if extra else "")
    c.text((44, y0 + 10), f"{cfg['_text']['open']}  {body}", 20, True, 255, "la")
    return height + 12


def draw_weather(c: Canvas, cfg: dict, states: dict, forecast: list[dict], y0: float) -> float:
    text = cfg["_text"]
    wx = states.get(cfg["weather"]["entity"], {})
    attrs = wx.get("attributes", {})
    cond = wx.get("state", "")
    glyph, label = CONDITIONS.get(cond, ("", cond))

    temp = _to_float(attrs.get("temperature"))
    feels = _to_float(attrs.get("apparent_temperature"))
    humidity = attrs.get("humidity")
    wind = _to_float(attrs.get("wind_speed"))

    c.text((26, y0 - 4), num(temp, 0) + "\u00b0", 104, True, BLACK, "la")
    c.text((26, y0 + 104), label.capitalize(), 26, True, BLACK, "la")

    sub = []
    if feels is not None:
        sub.append(f"{text['feels']} {num(feels, 0)}\u00b0")
    if humidity is not None:
        sub.append(f"{humidity:.0f}%")
    if wind is not None:
        sub.append(f"{num(wind, 0)} km/h")
    c.text((28, y0 + 138), " \u00b7 ".join(sub), 17, False, DARK, "la")

    if glyph:
        # composite glyphs ("sun + cloud") are drawn smaller so they stay inside
        # the column instead of colliding with the temperature block
        c.glyph((560, y0 + 6), glyph, 92 if len(glyph) == 1 else 62, BLACK, "ra")

    # day strip
    y = y0 + 176
    c.rule(32, y, 568, y, 1, LIGHT)
    if forecast:
        colw = 536 / len(forecast)
        for i, day in enumerate(forecast):
            x = 32 + colw * i
            try:
                name = cfg["display"]["locale_days"][dt.datetime.fromisoformat(day["datetime"]).weekday()]
            except (KeyError, ValueError):
                name = ""
            c.text((x + colw / 2, y + 12), name, 17, True, DARK, "ma")
            g, _ = CONDITIONS.get(day.get("condition", ""), ("", ""))
            if g:
                c.glyph((x + colw / 2, y + 46), g, 40 if len(g) == 1 else 28, BLACK, "ma")
            c.text((x + colw / 2, y + 96),
                   f"{num(_to_float(day.get('temperature')), 0)}\u00b0 "
                   f"{num(_to_float(day.get('templow')), 0)}\u00b0", 19, False, BLACK, "ma")
        y += 122
    return y


def draw_energy(c: Canvas, cfg: dict, states: dict, today: dict, y0: float, tz) -> float:
    en = cfg["energy"]
    text = cfg["_text"]

    def val(entity):
        return _to_float(states.get(entity, {}).get("state"))

    def delta(entities):
        total = 0.0
        for e in entities:
            now, base = val(e), today.get(e)
            if now is not None and base is not None:
                total += now - base
        return total

    power_kwh = delta(en["power_today"])
    power_cost = delta(en.get("power_today_cost", []))

    gas_now, gas_base = val(en["gas"]), today.get(en["gas"])
    gas_m3 = (gas_now - gas_base) if (gas_now is not None and gas_base is not None) else None
    gas_eur = None
    if en.get("gas_cost"):
        cg_now, cg_base = val(en["gas_cost"]), today.get(en["gas_cost"])
        if cg_now is not None and cg_base is not None:
            gas_eur = cg_now - cg_base

    tariff = states.get(en.get("tariff_state", ""), {}).get("state")
    tariff_txt = en.get("tariff_labels", {}).get(tariff, tariff or "")
    price = en["price_low"] if tariff == "low" else en["price_normal"]

    y = y0
    c.text((32, y), en["label_power"], 15, True, MID, "la")
    c.text((312, y), en["label_gas"], 15, True, MID, "la")

    # values share one baseline so 17.0 and 2.05 sit on the same line
    base = y + 96
    v = num(power_kwh, 1)
    c.text((30, base), v, 74, True, BLACK, "ls")
    c.text((30 + c.text_width(v, 74, True) + 8, base), "kWh", 22, True, DARK, "ls")
    c.text((32, base + 14), f"\u20ac {num(power_cost, 2)} {text['today']}", 19, False, BLACK, "la")

    v = num(gas_m3, 2)
    c.text((310, base), v, 74, True, BLACK, "ls")
    c.text((310 + c.text_width(v, 74, True) + 8, base), "m\u00b3", 22, True, DARK, "ls")
    c.text((312, base + 14), f"\u20ac {num(gas_eur, 2)} {text['today']}", 19, False, BLACK, "la")

    y = base + 56
    c.rule(32, y, 568, y, 1, LIGHT)
    if tariff_txt:
        c.text((32, y + 12), f"{text['tariff']} {tariff_txt} \u00b7 \u20ac {num(price, 3)}/kWh",
               17, False, DARK, "la")

    sun = states.get("sun.sun", {}).get("attributes", {})

    def hhmm(stamp):
        return dt.datetime.fromisoformat(stamp).astimezone(tz).strftime("%H:%M")

    sun_txt = ""
    if sun.get("next_rising") and sun.get("next_setting"):
        sun_txt = f"{text['sun']} {hhmm(sun['next_rising'])}\u2013{hhmm(sun['next_setting'])}"
    elif sun.get("next_setting"):
        sun_txt = f"{text['sun_setting']} {hhmm(sun['next_setting'])}"
    if sun_txt:
        c.text((568, y + 12), sun_txt, 17, False, DARK, "ra")
    return y + 42


def draw_consumers(c: Canvas, cfg: dict, states: dict, y0: float, bottom_limit: float) -> None:
    text = cfg["_text"]
    rows = []
    for entity, label in cfg.get("consumers", {}).items():
        w = _to_float(states.get(entity, {}).get("state"))
        if w:
            rows.append((w, label))
    rows.sort(reverse=True)

    c.text((32, y0), text["active"], 15, True, MID, "la")
    y = y0 + 26
    room = int((bottom_limit - y + 4) // 26)
    for w, label in rows[:max(1, room)]:
        c.text((32, y), label, 19, False, BLACK, "la")
        c.text((568, y), f"{num(w, 0)} W", 19, True, BLACK, "ra")
        y += 26
    if not rows:
        c.text((32, y), text["idle"], 19, False, DARK, "la")


def render(cfg: dict, out: Path | str | None, height: int | None = None,
           dx: int = 0, dy: int = 0, invert: bool = False):
    """Draw one frame. out=None returns a PIL image (used for burn-in variants)."""
    out = Path(out) if out is not None else None
    tz = ZoneInfo(cfg["display"]["timezone"])
    set_number_style(cfg["display"].get("number_style", "point"))
    ha = DemoHA(tz) if cfg.get("_demo") else HA(cfg["ha"]["url"], cfg["_token"])
    states = ha.states()
    forecast = ha.forecast_daily(cfg["weather"]["entity"], cfg["weather"].get("forecast_days", 5))

    now = dt.datetime.now(tz)
    midnight = now.replace(hour=0, minute=0, second=0, microsecond=0)
    tracked = list(cfg["energy"]["power_today"]) + list(cfg["energy"].get("power_today_cost", []))
    tracked += [e for e in (cfg["energy"].get("gas"), cfg["energy"].get("gas_cost")) if e]
    try:
        today = ha.value_at(tracked, midnight)
    except Exception as exc:
        print(f"history failed: {exc}", file=sys.stderr)
        today = {}

    width = cfg["display"]["width"]
    height = height or cfg["display"]["height"]
    c = Canvas(width, height, ox=dx, oy=dy)

    c.text((32, 26), f"{cfg['display']['locale_days'][now.weekday()]} {now.day} "
                     f"{cfg['display']['locale_months'][now.month - 1]}", 22, False, DARK, "la")
    c.text((568, 22), now.strftime("%H:%M"), 26, True, BLACK, "ra")
    c.rule(32, 68, 568, 68, 2, BLACK)

    y = 88.0
    opened = open_doors(cfg, states)
    if opened:
        y += draw_open_bar(c, cfg, opened, y - 4)

    y = draw_weather(c, cfg, states, forecast, y)
    c.rule(32, y + 6, 568, y + 6, 2, BLACK)
    y = draw_energy(c, cfg, states, today, y + 24, tz)
    c.rule(32, y, 568, y, 2, BLACK)

    footer = height - 48
    draw_consumers(c, cfg, states, y + 22, footer - 14)
    c.rule(32, footer, 568, footer, 1, LIGHT)
    status = f"{cfg['_text']['updated']} {now.strftime('%H:%M')}"
    if not opened and cfg.get("doors"):
        status += f" \u00b7 {cfg['_text']['doors_closed']}"
    c.text((32, footer + 12), status, 16, False, MID, "la")
    c.text((568, footer + 12), cfg["display"].get("footer_name") or os.uname().nodename,
           16, False, MID, "ra")

    img = c.finish(cfg["display"].get("gray_levels", 16))
    if cfg["display"].get("rotate"):
        img = img.rotate(cfg["display"]["rotate"], expand=True)
    if invert:
        img = img.point(lambda v: 255 - v)
    if out is None:
        return img
    out.parent.mkdir(parents=True, exist_ok=True)
    img.save(out, format="PNG", optimize=True)
    return out


def main(argv: list[str]) -> int:
    args = argv[1:]
    demo = "--demo" in args
    cfg_path = None
    for a in args:
        if a.startswith("--config="):
            cfg_path = Path(a.split("=", 1)[1])
    rest = [a for a in args if not a.startswith("--")]
    out = Path(rest[0]) if rest else ROOT / "out" / "dash.png"
    height = int(rest[1]) if len(rest) > 1 else None
    cfg = load_config(cfg_path, demo=demo)
    t0 = time.time()
    render(cfg, out, height)
    print(f"{out} ({out.stat().st_size} bytes, {time.time() - t0:.2f}s"
          f"{', demo data' if demo else ''})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
