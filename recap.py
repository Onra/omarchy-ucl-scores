#!/usr/bin/env python3
"""Find a YouTube highlights video for finished Champions League games.

Usage: recap.py '<json list>'   where each entry is
  {"id": "401915426", "date": 1788885900000, "season": "2026/27",
   "home": {"name": "Club Brugge", "aliases": ["Club Brugge", ...]},
   "away": {"name": "Aston Villa", "aliases": ["Aston Villa", ...]},
   "homeScore": 2, "awayScore": 3}

Prints one JSON line per game as soon as it is resolved:
  {"id": "401915426", "yt": "SEtYQhJAMTA", "title": "..."}   (yt is "" when none)

Unlike the NFL, the Champions League has no single channel that posts every
game, and YouTube search is full of re-uploads, PES simulations and fake
"highlights". So only a video that passes all of these checks is accepted:
  - it comes from the official channel of one of the two clubs, or from a
    broadcaster on TRUSTED;
  - the title says "highlights" (or a translation of it) and names both teams;
  - a score in the title, if any, is the score of the game;
  - it was uploaded within a couple of months after kickoff.
Clubs that do not upload highlights get no video, and the panel offers a
YouTube search instead.

Results are cached in ~/.cache/onra-ucl-scores/recaps.json. A found video is
kept forever; a miss is retried after 30 minutes for a game that just ended
(clubs post some hours later) and after 12 hours for an older one.
"""
import json
import os
import re
import subprocess
import sys
import time
import unicodedata

CACHE_DIR = os.path.join(os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache")), "onra-ucl-scores")
CACHE = os.path.join(CACHE_DIR, "recaps.json")
FRESH = 2 * 24 * 3600
RETRY_FRESH = 30 * 60
RETRY_OLD = 12 * 3600
MAX_AGE_DAYS = 60
VERIFY_LIMIT = 3

TRUSTED = {
    "uefa", "cbs sports golazo", "cbs sports", "tnt sports", "tnt sports football",
    "sky sports football", "canal+ sport", "bein sports", "dazn", "paramount+",
}
# Words that are not part of a club's name, in channel names and team names.
GENERIC = {"fc", "cf", "sc", "afc", "official", "club", "football", "the", "channel",
           "de", "del", "sl", "ssc", "1899", "1907", "1909"}
# Native spellings that channel names use for clubs ESPN names in English.
EXONYMS = {
    "bayern": {"munchen"}, "inter": {"internazionale", "milano", "milan"},
    "internazionale": {"inter", "milano", "milan"}, "atletico": {"madrid"},
    "cologne": {"koln"}, "koln": {"cologne"}, "lisbon": {"lisboa"},
}
TRANSLIT = str.maketrans({"ø": "o", "æ": "ae", "œ": "oe", "ł": "l", "đ": "d", "ð": "d", "ß": "ss", "ı": "i", "þ": "th"})
HIGHLIGHT = ("highlight", "recap", "resumen", "resume", "resumo", "zusammenfassung", "sintesi", "samenvatting")
REJECT = re.compile(
    r"\b(simulation|prediction|pes|efootball|fifa|fc ?2\d|preview|reaction|press conference|training|"
    r"full match|live|women|u21|u19|youth|compilation|every goal|all goals from)\b"
)


def norm(s):
    s = unicodedata.normalize("NFKD", (s or "").lower())
    s = "".join(c for c in s if not unicodedata.combining(c)).translate(TRANSLIT)
    return re.sub(r"[^a-z0-9+]+", " ", s).strip()


def words(s):
    return [w for w in norm(s).split() if w not in GENERIC]


def load_cache():
    try:
        with open(CACHE) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_cache(cache):
    os.makedirs(CACHE_DIR, exist_ok=True)
    tmp = CACHE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(cache, f)
    os.replace(tmp, CACHE)


def run(cmd, timeout):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except (OSError, subprocess.TimeoutExpired):
        return None


def search(query, n=12):
    out = run(["yt-dlp", "--flat-playlist", "--no-warnings",
               "--print", "%(id)s\t%(channel)s\t%(title)s", "ytsearch%d:%s" % (n, query)], 30)
    if out is None:
        return None
    rows = []
    for line in out.splitlines():
        parts = line.split("\t", 2)
        if len(parts) == 3:
            rows.append({"id": parts[0], "channel": parts[1], "title": parts[2]})
    return rows


def upload_date(video_id):
    """Days since epoch of the upload, None if it cannot be told."""
    out = run(["yt-dlp", "--no-warnings", "--skip-download", "--print", "%(upload_date)s",
               "https://www.youtube.com/watch?v=" + video_id], 25)
    out = (out or "").strip()
    if not re.fullmatch(r"\d{8}", out):
        return None
    return time.mktime(time.strptime(out, "%Y%m%d")) / 86400


class Team:
    def __init__(self, t, other):
        self.name = t["name"]
        # Every spelling of the club: "Man City", "Manchester City", ...
        self.aliases = set()
        for raw in [t["name"]] + list(t.get("aliases") or []):
            n = norm(raw)
            if len(n) >= 3:
                self.aliases.add(n)
            stripped = " ".join(words(raw))
            if len(stripped) >= 3:
                self.aliases.add(stripped)
            # "AS Roma" is "Roma" in most titles, "FK Bodo/Glimt" is "Bodo/Glimt".
            ws = norm(raw).split()
            while len(ws) > 1 and len(ws[0]) <= 2 and len(" ".join(ws[1:])) >= 4:
                ws = ws[1:]
                self.aliases.add(" ".join(ws))
        self.tokens = {w for a in self.aliases for w in a.split()}
        for w in list(self.tokens):
            self.tokens |= EXONYMS.get(w, set())
        # "AEK Athens" is "AEK" in most titles, but "Manchester" alone would be
        # ambiguous next to another Manchester club.
        first = words(t["name"])[:1]
        other_first = words(other["name"])[:1]
        if first and len(first[0]) >= 3 and first != other_first:
            self.aliases.add(first[0])

    def in_title(self, title):
        padded = " %s " % norm(title)
        return any(" %s " % a in padded for a in self.aliases)

    def owns_channel(self, channel):
        toks = words(channel)
        return bool(toks) and all(w in self.tokens for w in toks) and any(len(w) >= 3 for w in toks)


def score_ok(title, hs, aw):
    if hs < 0 or aw < 0:
        return True
    pairs = re.findall(r"(?<![\d/])(\d{1,2})\s*(?:-|–|:|vs\.?|v)\s*(\d{1,2})(?![\d/])", title.lower())
    pairs = [(int(a), int(b)) for a, b in pairs if int(a) <= 15 and int(b) <= 15]
    if not pairs:
        return True
    return any(p in ((hs, aw), (aw, hs)) for p in pairs)


def rank(row, g, teams):
    """0 = a club's own channel, 1 = trusted broadcaster, None = reject."""
    t = row["title"]
    tl = t.lower()
    if not any(k in tl for k in HIGHLIGHT) or REJECT.search(tl):
        return None
    if not all(team.in_title(t) for team in teams):
        return None
    if not score_ok(t, g["homeScore"], g["awayScore"]):
        return None
    if any(team.owns_channel(row["channel"]) for team in teams):
        return 0
    if norm(row["channel"]) in TRUSTED:
        return 1
    return None


def fresh_enough(video_id, kickoff_days):
    up = upload_date(video_id)
    if up is None:
        return None
    return kickoff_days - 1 <= up <= kickoff_days + MAX_AGE_DAYS


def resolve(g):
    home, away = g["home"], g["away"]
    teams = [Team(home, away), Team(away, home)]
    kickoff_days = g["date"] / 1000 / 86400
    queries = [
        "%s vs %s highlights UEFA Champions League %s" % (home["name"], away["name"], g["season"]),
        "%s %s Champions League highlights" % (teams[0].name, teams[1].name),
    ]
    tried = set()
    for q in queries:
        rows = search(q)
        if rows is None:
            return None  # network/tool failure: do not cache
        ranked = []
        for i, row in enumerate(rows):
            r = rank(row, g, teams)
            if r is not None and row["id"] not in tried:
                ranked.append((r, i, row))
        ranked.sort(key=lambda x: (x[0], x[1]))
        for _, _, row in ranked[:VERIFY_LIMIT]:
            tried.add(row["id"])
            ok = fresh_enough(row["id"], kickoff_days)
            if ok is None:
                return None
            if ok:
                return row
    return {"id": "", "title": ""}


def main():
    games = json.loads(sys.argv[1])
    cache = load_cache()
    now = time.time()
    for g in games:
        gid = str(g["id"])
        hit = cache.get(gid)
        if hit:
            age = now - g["date"] / 1000
            retry = RETRY_FRESH if age < FRESH else RETRY_OLD
            if hit.get("yt") or now - hit.get("at", 0) < retry:
                print(json.dumps({"id": gid, "yt": hit.get("yt", ""), "title": hit.get("title", "")}), flush=True)
                continue
        row = resolve(g)
        if row is None:
            continue
        cache[gid] = {"yt": row["id"], "title": row["title"], "at": now}
        print(json.dumps({"id": gid, "yt": row["id"], "title": row["title"]}), flush=True)
        save_cache(cache)


if __name__ == "__main__":
    main()
