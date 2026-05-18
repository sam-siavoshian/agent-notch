#!/usr/bin/env python3
"""
AgentNotch · memory demo

Reads the real on-disk ContextMemory tree and prints a presentation-grade
summary of what the agent has learned — apps mapped, surfaces and
controls, the chronological story Gemini stitched together, recipes
that have graduated from the keystroke recorder, and the pitch line for
how all of this lands at Claude at long-press time.

Run before a demo to "open the hood" — single command, no deps, ~150ms.

    python3 scripts/demo-memory.py
"""

from __future__ import annotations

import json
import os
import sys
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path

# ───── ANSI ────────────────────────────────────────────────────────────────

_IS_TTY = sys.stdout.isatty()


def _ansi(code: str, s: str) -> str:
    if not _IS_TTY:
        return s
    return f"\033[{code}m{s}\033[0m"


def bold(s):    return _ansi("1", s)
def dim(s):     return _ansi("2", s)
def cyan(s):    return _ansi("36", s)
def green(s):   return _ansi("32", s)
def yellow(s):  return _ansi("33", s)
def magenta(s): return _ansi("35", s)


# ───── paths ───────────────────────────────────────────────────────────────

ROOT = Path.home() / "Library/Application Support/AgentNotch/ContextMemory"
SURFACES = ROOT / "surfaces"
ANCHORS = ROOT / "anchors"
SCREEN_OBS = ROOT / "screen_observations.jsonl"
RESOURCES_INDEX = ROOT.parent / "resources_index.json"
MERCURY_PAYLOADS = ROOT / "mercury-payloads.jsonl"


def today_jsonl(prefix: str) -> Path:
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    return ROOT / f"{prefix}-{today}.jsonl"


# ───── headers ─────────────────────────────────────────────────────────────

def banner():
    line = "─" * 64
    print()
    print(cyan(f"╭{line}╮"))
    print(cyan("│") + bold("  AgentNotch · what it remembers about you".ljust(64)) + cyan("│"))
    print(cyan(f"╰{line}╯"))
    print()


def section(label: str):
    print()
    print(magenta("▌ ") + bold(label))
    print()


# ───── load helpers ────────────────────────────────────────────────────────

def load_jsonl(path: Path) -> list[dict]:
    if not path.exists():
        return []
    out = []
    for line in path.read_text(errors="ignore").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return out


def load_surfaces() -> dict[str, list[dict]]:
    """{ bundle_id: [surface_json, ...] } sorted by observationCount desc."""
    by_bundle: dict[str, list[dict]] = defaultdict(list)
    if not SURFACES.exists():
        return by_bundle
    for bid_dir in sorted(SURFACES.iterdir()):
        if not bid_dir.is_dir():
            continue
        for f in bid_dir.glob("*.json"):
            try:
                d = json.loads(f.read_text())
                by_bundle[bid_dir.name].append(d)
            except (json.JSONDecodeError, OSError):
                continue
        by_bundle[bid_dir.name].sort(
            key=lambda s: s.get("observationCount", 0),
            reverse=True,
        )
    return by_bundle


def load_anchors() -> dict[str, list[dict]]:
    """{ bundle_id: [recipe_dict, ...] } only those promoted (seenCount >= 3 or marked promoted)."""
    out: dict[str, list[dict]] = {}
    if not ANCHORS.exists():
        return out
    for f in ANCHORS.glob("*.json"):
        bid = f.stem
        try:
            data = json.loads(f.read_text())
        except (json.JSONDecodeError, OSError):
            continue
        recipes = data.get("recipes", []) if isinstance(data, dict) else data
        if not isinstance(recipes, list):
            continue
        out[bid] = recipes
    return out


# ───── pretty helpers ──────────────────────────────────────────────────────

APP_NAME_FROM_BUNDLE = {
    "com.hnc.discord": "Discord",
    "com.hnc.discordcanary": "Discord Canary",
    "com.hnc.Discord": "Discord",
    "com.hnc.DiscordCanary": "Discord Canary",
    "com.googlecode.iterm2": "iTerm2",
    "com.brave.browser": "Brave",
    "com.brave.Browser": "Brave",
    "com.apple.notes": "Notes",
    "com.apple.Notes": "Notes",
    "com.apple.mail": "Mail",
    "com.apple.mobilesms": "Messages",
}


def pretty_app(bid: str) -> str:
    return APP_NAME_FROM_BUNDLE.get(bid, bid.split(".")[-1].capitalize())


def short_time(iso_str: str) -> str:
    try:
        if iso_str.endswith("Z"):
            iso_str = iso_str.replace("Z", "+00:00")
        dt = datetime.fromisoformat(iso_str).astimezone()
        return dt.strftime("%H:%M")
    except (ValueError, AttributeError):
        return "—"


def truncate(s: str, n: int) -> str:
    s = (s or "").strip()
    if len(s) <= n:
        return s
    return s[: n - 1].rstrip() + "…"


def step_summary(step: dict) -> str:
    for k in ("shortcut", "type", "key", "menu", "url", "shellCmd", "openFile"):
        if k in step:
            v = step[k]
            if isinstance(v, dict):
                v = v.get("value") or v.get("keys") or str(v)
            return f"{k}={truncate(str(v), 36)}"
    return "?"


# ───── sections ────────────────────────────────────────────────────────────

def section_headline(surfaces: dict, anchors: dict, screen_obs: list, story: list, events: list):
    section("Memory snapshot")
    total_surfaces = sum(len(v) for v in surfaces.values())
    total_controls = sum(
        len(s.get("controls", []))
        for arr in surfaces.values() for s in arr
    )
    promoted_recipes = sum(
        1 for arr in anchors.values()
        for r in arr if (r.get("seenCount") or r.get("seen_count") or 0) >= 3
    )
    candidate_recipes = sum(
        1 for arr in anchors.values()
        for r in arr if (r.get("seenCount") or r.get("seen_count") or 0) < 3
    )
    rows = [
        ("apps observed",            str(len(surfaces))),
        ("surfaces mapped",          str(total_surfaces)),
        ("controls labelled",        str(total_controls)),
        ("recipes promoted",         str(promoted_recipes)),
        ("recipe candidates",        str(candidate_recipes)),
        ("observations on disk",     str(len(screen_obs))),
        ("story entries today",      str(len(story))),
        ("events today",             str(len(events))),
    ]
    for k, v in rows:
        print(f"    {k:.<28}{green(v.rjust(8))}")


def section_top_app(surfaces: dict):
    if not surfaces:
        return
    # Pick the app with the most controls, not just the most surfaces — that's
    # the deeper signal of "we know this app's UI."
    def total_controls(bid):
        return sum(len(s.get("controls", [])) for s in surfaces[bid])
    top_bid = max(surfaces, key=total_controls)
    arr = surfaces[top_bid]
    n_surfaces = len(arr)
    n_controls = total_controls(top_bid)

    section(f"Deepest-learned app: {pretty_app(top_bid)} ({dim(top_bid)})")
    print(f"    {n_surfaces} surfaces · {n_controls} labelled controls")
    print()

    # Pick the surface with the most controls as the example.
    if not arr:
        return
    example = max(arr, key=lambda s: len(s.get("controls", [])))
    name = example.get("surface", "?")
    print(f"    {dim('example surface:')} {bold(truncate(name, 60))}")
    for c in example.get("controls", [])[:6]:
        label = truncate(c.get("label", "?"), 26)
        loc = truncate(c.get("location", "?"), 28)
        purpose = truncate(c.get("purpose", "?"), 38)
        seen = c.get("seenCount", "?")
        print(f"      {cyan('·')} {label:26} {dim(f'seen {seen}x'):14} {loc:28} {dim(purpose)}")


def section_story(story: list):
    section("Continuity · what Gemini watched you do (last 5 captures)")
    if not story:
        print(dim("    no story entries today"))
        return
    for o in story[-5:]:
        t = short_time(o.get("t", ""))
        app = truncate(o.get("frontmost_app", "?"), 18)
        narr = truncate(o.get("narrative", ""), 96)
        goal = truncate(o.get("current_goal_guess", ""), 96)
        link = truncate(o.get("continuity_link", ""), 96)
        print(f"    {dim('[' + t + ']')} {yellow(app):24} {narr}")
        if goal:
            print(f"      {dim('↳ goal:')} {dim(goal)}")
        if link:
            print(f"      {dim('↳ continuity:')} {dim(link)}")


def section_recipes(anchors: dict):
    section("Learned recipes (promoted at 3+ observations)")
    promoted = []
    for bid, recipes in anchors.items():
        for r in recipes:
            seen = r.get("seenCount") or r.get("seen_count") or 0
            if seen >= 3:
                promoted.append((bid, r, seen))
    promoted.sort(key=lambda t: t[2], reverse=True)
    if not promoted:
        print(dim("    no recipes have hit the 3× promotion threshold yet"))
        return
    for bid, r, seen in promoted[:5]:
        name = r.get("name", "auto-shortcut")
        steps = r.get("steps", [])
        steps_s = " → ".join(step_summary(s) for s in steps[:4])
        print(f"    {green('▸')} {pretty_app(bid):18} {bold(name):24} {dim(f'seen {seen}×')}   {steps_s}")


def section_resources():
    """Resource index — populated by adapters every capture (post-fix)."""
    if not RESOURCES_INDEX.exists():
        return
    try:
        refs = json.loads(RESOURCES_INDEX.read_text())
    except (json.JSONDecodeError, OSError):
        return
    if not refs:
        return
    refs.sort(key=lambda r: r.get("lastSeen", ""), reverse=True)
    section(f"Resource index · {len(refs)} URIs the agent can deref")
    by_kind = Counter(r.get("kind", "?") for r in refs)
    kinds_line = "  ·  ".join(f"{green(str(v))} {dim(k)}" for k, v in by_kind.most_common())
    print(f"    {kinds_line}")
    print()
    for r in refs[:6]:
        kind = r.get("kind", "?")
        label = truncate(r.get("label") or r.get("uri", "?"), 38)
        uri = truncate(r.get("uri", "?"), 60)
        app = truncate(r.get("app") or "?", 16)
        print(f"    {green('▸')} {bold(label):38}  {dim(f'[{kind}]'):10} {dim(app):16} {uri}")


def section_last_payload():
    """Peek at the most recent Mercury payload — proves cross-app surfaces
    + transcript-relevant resources actually reached Mercury."""
    if not MERCURY_PAYLOADS.exists():
        return
    last = None
    with open(MERCURY_PAYLOADS) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                last = json.loads(line)
            except json.JSONDecodeError:
                continue
    if not last:
        return
    section("Last Mercury payload (what the agent's brain actually got)")
    t = short_time(last.get("t", ""))
    transcript = truncate(last.get("transcript", ""), 78)
    print(f"    {dim('[' + t + ']')} {bold('transcript:')} \"{transcript}\"")
    payload = last.get("payload", {})
    if not isinstance(payload, dict):
        print(dim("    (payload not JSON-parseable — raw string)"))
        return
    learned = payload.get("learned_surfaces", []) or []
    resources = payload.get("recent_resources", []) or []
    story = payload.get("recent_story", []) or []
    apps_in_surfaces = sorted({s.get("app", "?") for s in learned})
    print(f"    {dim('learned_surfaces ('+str(len(learned))+'):')} {', '.join(apps_in_surfaces) or dim('(none)')}")
    if learned:
        for s in learned[:4]:
            print(f"      · {bold(s.get('app','?'))}: {truncate(s.get('surface','?'), 60)}")
    print(f"    {dim('recent_resources ('+str(len(resources))+'):')} top 3 by transcript-token score")
    for r in resources[:3]:
        print(f"      · {truncate(r.get('label') or r.get('uri',''), 60)}  {dim(truncate(r.get('uri',''), 40))}")
    print(f"    {dim('recent_story ('+str(len(story))+' entries):')} last narrative:")
    if story:
        s = story[-1]
        print(f"      {dim(short_time(s.get('t','')))} {yellow(s.get('app','?'))}: {truncate(s.get('narrative',''), 90)}")


def section_pitch(surfaces: dict, anchors: dict, story: list):
    section("How this lands at the agent")
    print(
        "    On long-press, the Selector hands Mercury "
        + green("top 8 surfaces") + " (current-app + cross-app entity matches, × 12 controls each),"
    )
    print(
        "    " + green("3 recipes") + " for the active app, "
        + green("20 ranked resources") + " (transcript-token boost),"
    )
    print(
        "    " + green("recent story entries") + " (5-minute window + older entries mentioning transcript tokens),"
    )
    print(
        "    and the live L2 snapshot. Mercury writes a brief that tells Claude:"
    )
    print()
    print(f"    {dim('• navigation_anchors:')} {bold('exact AX-style labels')} you have actually seen ({dim('e.g. \"Search (top-right)\"')})")
    print(f"    {dim('• resolved_references:')} deictic terms (\"phone1k\", \"the merge\") {bold('mapped to concrete surfaces / resources')}")
    print(f"    {dim('• recipes_for_active_app:')} promoted keystroke sequences {bold('Claude prefers over screenshot+click')}")
    print()
    print(
        "    Net: " + bold("the agent acts on names, not pixels") +
        " — fewer screenshots, fewer wrong clicks, more sub-second runs."
    )
    print()


# ───── main ────────────────────────────────────────────────────────────────

def main():
    if not ROOT.exists():
        print(f"no ContextMemory at {ROOT}")
        print("→ launch AgentNotch first to populate the stores.")
        sys.exit(1)

    surfaces = load_surfaces()
    anchors = load_anchors()
    screen_obs = load_jsonl(SCREEN_OBS)
    story = load_jsonl(today_jsonl("story"))
    events = load_jsonl(today_jsonl("events"))

    banner()
    section_headline(surfaces, anchors, screen_obs, story, events)
    section_top_app(surfaces)
    section_story(story)
    section_recipes(anchors)
    section_resources()
    section_last_payload()
    section_pitch(surfaces, anchors, story)


if __name__ == "__main__":
    main()
