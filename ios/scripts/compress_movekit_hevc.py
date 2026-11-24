"""Compress all 588 MoveKit MP4 videos to iOS-compatible hvc1 HEVC and generate movekit_manifest.json."""

from __future__ import annotations

import concurrent.futures
import json
import os
import subprocess
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SOURCE_DIR = Path(os.environ.get("MOVEKIT_SOURCE_DIR", str(REPO_ROOT / "movekit_source")))
IOS_APP_DIR = REPO_ROOT / "ios" / "ParchmentLedger"
OUT_VIDEO_DIR = IOS_APP_DIR / "MoveKitVideos"
MANIFEST_PATH = IOS_APP_DIR / "movekit_manifest.json"
FFMPEG_BIN = "/opt/homebrew/bin/ffmpeg"

ACRONYM_MAP = {
    "ez": "EZ",
    "db": "DB",
    "kb": "KB",
    "rdl": "RDL",
    "trx": "TRX",
    "it": "IT",
    "ghd": "GHD",
    "t": "T",
    "b": "B",
    "z": "Z",
    "v": "V",
    "l": "L",
    "y": "Y",
    "w": "W",
    "iso": "Iso",
}
LOWERCASE_WORDS = {"and", "to", "with", "of", "on", "in", "the", "for", "at", "or"}


def humanize_exercise_name(stem: str) -> str:
    if stem.startswith("90-90-"):
        return "90/90 " + humanize_exercise_name(stem[6:])
    tokens = stem.split("-")
    out: list[str] = []
    i = 0
    while i < len(tokens):
        tok = tokens[i].lower()
        next_tok = tokens[i + 1].lower() if i + 1 < len(tokens) else ""
        if tok in {"ez", "b", "t", "z", "v", "l", "y", "w"} and next_tok in {
            "bar",
            "stance",
            "press",
            "up",
            "ups",
            "sit",
            "raise",
            "raises",
            "t",
        }:
            left = ACRONYM_MAP.get(tok, tok.upper())
            right = next_tok.capitalize()
            out.append(f"{left}-{right}")
            i += 2
            continue
        if tok in ACRONYM_MAP:
            out.append(ACRONYM_MAP[tok])
        elif i > 0 and tok in LOWERCASE_WORDS:
            out.append(tok)
        else:
            out.append(tok.capitalize())
        i += 1
    return " ".join(out)


def infer_muscle_hint(stem: str) -> str:
    s = stem.lower()
    if any(k in s for k in ("stretch", "mobility", "90-90", "rock-back", "flexor-rock", "worlds-greatest")):
        return "Mobility"
    if any(k in s for k in ("squat", "lunge", "deadlift", "rdl", "hip-thrust", "glute", "calf", "soleus", "hamstring", "leg-curl", "tibialis", "step-up", "split-squat", "good-morning", "frog-pump")):
        return "Legs"
    if any(k in s for k in ("pull-up", "chin-up", "pulldown", "row", "shrug", "lat-", "pullover")):
        return "Pull"
    if any(k in s for k in ("bench", "push-up", "chest", "pec", "dip", "fly", "floor-press")):
        return "Push"
    if any(k in s for k in ("arnold", "overhead-press", "shoulder", "lateral-raise", "front-raise", "face-pull", "external-rotation", "rear-delt", "z-press", "anti-gravity")):
        return "Shoulders"
    if any(k in s for k in ("curl", "skullcrusher", "tricep", "pushdown", "wrist", "kickback")):
        return "Arms"
    if any(k in s for k in ("plank", "abdominal", "crunch", "pallof", "chop", "wood-chopper", "carry", "leg-raise", "sit-up", "v-up", "side-bend", "hollow")):
        return "Core"
    if any(k in s for k in ("bike", "swim", "run", "trainer", "jump", "burpee", "battle-rope", "sled", "thruster", "clean", "snatch", "swing")):
        return "Cardio"
    return "Strength"


def _compress_one(src_path: Path) -> tuple[str, int, str | None]:
    dst_path = OUT_VIDEO_DIR / src_path.name
    if dst_path.exists() and dst_path.stat().st_size > 1024:
        return src_path.name, dst_path.stat().st_size, None

    tmp_path = OUT_VIDEO_DIR / f".tmp_{src_path.name}"
    cmd = [
        FFMPEG_BIN,
        "-y",
        "-hide_banner",
        "-loglevel",
        "error",
        "-i",
        str(src_path),
        "-c:v",
        "libx265",
        "-preset",
        "veryfast",
        "-crf",
        "25",
        "-tag:v",
        "hvc1",
        "-vf",
        "scale='min(540,iw)':-2",
        "-an",
        "-movflags",
        "+faststart",
        str(tmp_path),
    ]
    res = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if res.returncode != 0 or not tmp_path.exists() or tmp_path.stat().st_size <= 1024:
        if tmp_path.exists():
            tmp_path.unlink(missing_ok=True)
        return src_path.name, 0, res.stderr.strip() or f"exit {res.returncode}"
    os.replace(tmp_path, dst_path)
    return src_path.name, dst_path.stat().st_size, None


def main() -> None:
    if not SOURCE_DIR.exists():
        raise SystemExit(f"Missing MoveKit source dir: {SOURCE_DIR}")

    OUT_VIDEO_DIR.mkdir(parents=True, exist_ok=True)
    mp4s = sorted(SOURCE_DIR.glob("*.mp4"))
    manifest = [
        {
            "id": f"mk_{p.stem}",
            "name": humanize_exercise_name(p.stem),
            "videoFilename": p.name,
            "muscleHint": infer_muscle_hint(p.stem),
        }
        for p in mp4s
    ]
    MANIFEST_PATH.write_text(json.dumps(manifest, indent=2), encoding="utf-8")

    failures: list[tuple[str, str]] = []
    total_bytes = 0
    done = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        for fname, size, err in pool.map(_compress_one, mp4s):
            done += 1
            total_bytes += size
            if err:
                failures.append((fname, err))
            if done % 100 == 0 or done == len(mp4s):
                print(f"Compressed {done}/{len(mp4s)} ({total_bytes / (1024 * 1024):.1f} MB)", flush=True)

    if failures:
        print("FAILURES:", failures[:10])
        raise SystemExit(1)

    print(
        f"Done: {len(mp4s)} videos -> {total_bytes / (1024 * 1024):.2f} MB; manifest at {MANIFEST_PATH}",
        flush=True,
    )


if __name__ == "__main__":
    main()
