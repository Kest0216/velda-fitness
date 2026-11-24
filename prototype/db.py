"""SQLite data layer, MoveKit 588-video indexer, progression analytics, and storage janitor."""

from __future__ import annotations

import datetime as dt
import json
import math
import os
import re
import shutil
import sqlite3
import subprocess
import tempfile
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

PROTOTYPE_DIR = Path(__file__).resolve().parent
MOVEKIT_DIR = Path(os.environ.get("MOVEKIT_SOURCE_DIR", str(PROTOTYPE_DIR.parent / "movekit_source")))
DATA_DIR = PROTOTYPE_DIR / "data"
SAVED_MEDIA_DIR = DATA_DIR / "media" / "saved"
CACHE_MEDIA_DIR = DATA_DIR / "media" / "cache"
DB_PATH = DATA_DIR / "ledger.db"

DAY_NAMES = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
DAY_FULL_NAMES = [
    "Monday",
    "Tuesday",
    "Wednesday",
    "Thursday",
    "Friday",
    "Saturday",
    "Sunday",
]

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

_MOVEKIT_STATS_CACHE: dict[str, int] | None = None


def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()


def today_str() -> str:
    return dt.date.today().isoformat()


def get_connection() -> sqlite3.Connection:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    SAVED_MEDIA_DIR.mkdir(parents=True, exist_ok=True)
    CACHE_MEDIA_DIR.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(DB_PATH), check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL;")
    conn.execute("PRAGMA foreign_keys=ON;")
    return conn


def humanize_exercise_name(stem: str) -> str:
    if stem.startswith("90-90-"):
        rest = stem[6:]
        return "90/90 " + humanize_exercise_name(rest)
    tokens = stem.split("-")
    out: list[str] = []
    # Preserve hyphenated prefixes like B-Stance, T-Bar, Z-Press, V-Up, L-Sit, Y-Raise, EZ-Bar
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


def create_tables(conn: sqlite3.Connection) -> None:
    conn.executescript(
        """
        CREATE TABLE IF NOT EXISTS exercises (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            video_filename TEXT,
            muscle_hint TEXT,
            is_custom INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS day_routines (
            day_of_week INTEGER PRIMARY KEY,
            title TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS routine_exercises (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            day_of_week INTEGER NOT NULL,
            exercise_id TEXT NOT NULL,
            sort_order INTEGER NOT NULL DEFAULT 0,
            UNIQUE(day_of_week, exercise_id)
        );

        CREATE TABLE IF NOT EXISTS workout_sets (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_date TEXT NOT NULL,
            exercise_id TEXT NOT NULL,
            set_number INTEGER NOT NULL,
            reps INTEGER NOT NULL,
            weight REAL NOT NULL,
            completed INTEGER NOT NULL DEFAULT 1,
            created_at TEXT NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_sets_ex_date
            ON workout_sets(exercise_id, session_date);

        CREATE TABLE IF NOT EXISTS recipes (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            source_url TEXT NOT NULL,
            source_domain TEXT NOT NULL,
            prep_time TEXT,
            servings INTEGER DEFAULT 2,
            kcal INTEGER,
            protein_g INTEGER,
            carbs_g INTEGER,
            fat_g INTEGER,
            meal_type TEXT NOT NULL DEFAULT '',
            dietary_tags TEXT NOT NULL DEFAULT '[]',
            allergens TEXT NOT NULL DEFAULT '[]',
            ingredients TEXT NOT NULL DEFAULT '[]',
            steps TEXT NOT NULL DEFAULT '[]',
            image_path TEXT,
            image_source TEXT DEFAULT 'placeholder',
            is_saved INTEGER NOT NULL DEFAULT 0,
            discovered_at TEXT NOT NULL,
            saved_at TEXT
        );

        CREATE TABLE IF NOT EXISTS app_settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """
    )
    cols = {row[1] for row in conn.execute("PRAGMA table_info(recipes)").fetchall()}
    if "meal_type" not in cols:
        conn.execute("ALTER TABLE recipes ADD COLUMN meal_type TEXT NOT NULL DEFAULT ''")
    missing = conn.execute(
        "SELECT id, title, ingredients FROM recipes WHERE COALESCE(meal_type, '') = ''"
    ).fetchall()
    for row in missing:
        conn.execute(
            "UPDATE recipes SET meal_type = ? WHERE id = ?",
            (infer_meal_type(row["title"], row["ingredients"] or ""), row["id"]),
        )
    conn.commit()


def infer_meal_type(title: str, ingredients_raw: str = "") -> str:
    text = f"{title} {ingredients_raw}".lower()
    if any(
        k in text
        for k in (
            "breakfast",
            "oat",
            "chia",
            "pancake",
            "waffle",
            "omelet",
            "scramble",
            "shakshuka",
            "granola",
            "toast",
            "yogurt",
            "frittata",
            "hash",
            "egg muffin",
        )
    ):
        return "Breakfast"
    if any(
        k in text
        for k in (
            "snack",
            "bite",
            "protein bar",
            "dip",
            "hummus",
            "muffin",
            "smoothie",
            "shake",
            "parfait",
        )
    ):
        return "Snacks"
    if any(
        k in text
        for k in (
            "taco",
            "wrap",
            "salad",
            "sandwich",
            "tofu",
            "meatball",
            "lunch",
            "grain bowl",
            "buckwheat bowl",
        )
    ):
        return "Lunch"
    return "Dinner"


def sync_movekit_exercises(conn: sqlite3.Connection) -> int:
    global _MOVEKIT_STATS_CACHE
    if not MOVEKIT_DIR.exists():
        return 0

    mp4s = sorted(MOVEKIT_DIR.glob("*.mp4"))
    total_bytes = 0
    rows: list[tuple[str, str, str, str, int, str]] = []
    stamp = now_iso()
    for p in mp4s:
        try:
            total_bytes += p.stat().st_size
        except OSError:
            pass
        stem = p.stem
        ex_id = f"mk_{stem}"
        rows.append((ex_id, humanize_exercise_name(stem), p.name, infer_muscle_hint(stem), 0, stamp))

    _MOVEKIT_STATS_CACHE = {
        "count": len(mp4s),
        "bytes": total_bytes,
    }

    conn.executemany(
        """
        INSERT OR IGNORE INTO exercises (id, name, video_filename, muscle_hint, is_custom, created_at)
        VALUES (?, ?, ?, ?, ?, ?)
        """,
        rows,
    )
    conn.commit()
    return len(rows)


def get_movekit_dir_stats() -> dict[str, int]:
    global _MOVEKIT_STATS_CACHE
    if _MOVEKIT_STATS_CACHE is not None:
        return _MOVEKIT_STATS_CACHE
    if not MOVEKIT_DIR.exists():
        _MOVEKIT_STATS_CACHE = {"count": 0, "bytes": 0}
        return _MOVEKIT_STATS_CACHE
    mp4s = list(MOVEKIT_DIR.glob("*.mp4"))
    total = 0
    for p in mp4s:
        try:
            total += p.stat().st_size
        except OSError:
            pass
    _MOVEKIT_STATS_CACHE = {"count": len(mp4s), "bytes": total}
    return _MOVEKIT_STATS_CACHE


def _generate_starter_dish_jpg(dest_path: Path, bg_rgb: tuple[int, int, int], accent_rgb: tuple[int, int, int], garnish_rgb: tuple[int, int, int]) -> bool:
    """Create a 180x180 painterly parchment-plate PPM raster and compress to 480x480 JPEG via sips."""
    size = 180
    cx = cy = size / 2.0
    pixels = bytearray(size * size * 3)
    parchment = (224, 211, 189)
    ink = (36, 32, 28)

    for y in range(size):
        for x in range(size):
            dx = x - cx
            dy = y - cy
            dist = math.sqrt(dx * dx + dy * dy)
            idx = (y * size + x) * 3

            # Subtle organic paper grain
            grain = ((x * 37 + y * 91) % 11) - 5
            r, g, b = parchment

            if 73.0 <= dist <= 75.5:
                # Outer hand-drawn ink rim
                r, g, b = ink
            elif 65.0 <= dist <= 66.5:
                # Inner ceramic plate ring
                r, g, b = (78, 70, 60)
            elif dist < 60.0:
                # Dish centerpiece wash with radial shading
                shade = 1.0 - (dist / 60.0) * 0.16
                r = int(bg_rgb[0] * shade)
                g = int(bg_rgb[1] * shade)
                b = int(bg_rgb[2] * shade)
                # Accent culinary brushstroke inside plate
                ang = math.atan2(dy, dx)
                if 16.0 < dist < 42.0 and math.sin(ang * 3.0 + dist * 0.08) > 0.35:
                    r, g, b = accent_rgb
                # Center garnish dot/leaf cluster
                if dist < 13.0 or ((dx - 16) ** 2 + (dy + 12) ** 2 < 64) or ((dx + 14) ** 2 + (dy - 15) ** 2 < 49):
                    r, g, b = garnish_rgb

            pixels[idx] = max(0, min(255, r + grain))
            pixels[idx + 1] = max(0, min(255, g + grain))
            pixels[idx + 2] = max(0, min(255, b + grain))

    dest_path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(suffix=".ppm", delete=False) as tmp:
        tmp_path = Path(tmp.name)
        tmp.write(f"P6\n{size} {size}\n255\n".encode("ascii"))
        tmp.write(pixels)

    try:
        res = subprocess.run(
            ["/usr/bin/sips", "-Z", "480", "-s", "format", "jpeg", "-s", "formatOptions", "75", str(tmp_path), "--out", str(dest_path)],
            capture_output=True,
            text=True,
            check=False,
        )
        return res.returncode == 0 and dest_path.exists()
    finally:
        if tmp_path.exists():
            tmp_path.unlink(missing_ok=True)


def _find_exercise_id(conn: sqlite3.Connection, candidates: list[str]) -> str | None:
    for stem in candidates:
        row = conn.execute("SELECT id FROM exercises WHERE id = ?", (f"mk_{stem}",)).fetchone()
        if row:
            return row["id"]
    for stem in candidates:
        row = conn.execute(
            "SELECT id FROM exercises WHERE id LIKE ? LIMIT 1",
            (f"mk_%{stem}%",),
        ).fetchone()
        if row:
            return row["id"]
    return None


def seed_initial_data(conn: sqlite3.Connection) -> None:
    existing_settings = conn.execute("SELECT COUNT(*) FROM app_settings").fetchone()[0]
    if existing_settings == 0:
        defaults = {
            "weight_unit": "lbs",
            "cache_ttl_days": "7",
            "cache_max_mb": "25",
        }
        env_key = os.environ.get("GEMINI_API_KEY", "").strip()
        if env_key:
            defaults["gemini_api_key"] = env_key
        conn.executemany(
            "INSERT OR IGNORE INTO app_settings (key, value) VALUES (?, ?)",
            list(defaults.items()),
        )

    existing_days = conn.execute("SELECT COUNT(*) FROM day_routines").fetchone()[0]
    if existing_days == 0:
        stamp = now_iso()
        day_specs: list[tuple[int, str, list[list[str]]]] = [
            (
                0,
                "Lower Strength",
                [
                    ["barbell-squat"],
                    ["barbell-romanian-deadlift"],
                    ["forward-lunge", "barbell-lunge"],
                    ["bodyweight-donkey-calf-raise", "bent-knee-soleus-raise"],
                ],
            ),
            (
                1,
                "Upper Push & Shoulders",
                [
                    ["barbell-bench-press", "wide-grip-barbell-bench-press"],
                    ["arnold-press", "barbell-overhead-press"],
                    ["cable-low-to-high-fly", "cable-pec-fly"],
                    ["ez-bar-skullcrusher", "cable-rope-pushdown"],
                ],
            ),
            (
                2,
                "Upper Pull & Arms",
                [
                    ["weighted-pull-ups", "chin-ups"],
                    ["barbell-bent-over-row", "chest-supported-dumbbell-row"],
                    ["cable-seated-rope-face-pull", "band-high-face-pull"],
                    ["alternating-hammer-curl", "barbell-curl"],
                ],
            ),
            (
                3,
                "Mobility & Core",
                [
                    ["90-90-hip-switches"],
                    ["worlds-greatest-stretch"],
                    ["cable-pallof-press", "front-plank"],
                    ["assault-bike", "arc-trainer"],
                ],
            ),
            (
                4,
                "Posterior Chain & Press",
                [
                    ["barbell-deadlift", "barbell-rack-pull"],
                    ["barbell-incline-bench-press", "floor-press"],
                    ["b-stance-hip-thrust", "barbell-hip-thrust"],
                    ["band-lateral-raise", "cable-low-single-arm-lateral-raise"],
                ],
            ),
            (
                5,
                "Kettlebell & Conditioning",
                [
                    ["double-kettlebell-clean-and-press", "kettlebell-swing"],
                    ["goblet-squat-prying-hold", "front-squat"],
                    ["archer-push-up", "wide-push-up"],
                    ["band-assisted-pull-up", "wide-grip-lat-pulldown"],
                ],
            ),
            (
                6,
                "Rest & Recovery",
                [],
            ),
        ]

        for dow, title, candidate_groups in day_specs:
            conn.execute(
                "INSERT INTO day_routines (day_of_week, title, updated_at) VALUES (?, ?, ?)",
                (dow, title, stamp),
            )
            order = 0
            for cands in candidate_groups:
                ex_id = _find_exercise_id(conn, cands)
                if ex_id:
                    conn.execute(
                        "INSERT OR IGNORE INTO routine_exercises (day_of_week, exercise_id, sort_order) VALUES (?, ?, ?)",
                        (dow, ex_id, order),
                    )
                    order += 1

        # Seed historical workout sets (4 prior weekly sessions + partial today) so volume trendlines render immediately
        today = dt.date.today()
        today_dow = today.weekday()

        # Find exact IDs across all days to ensure today's routine AND Wed routine both have rich history
        def get_day_ex_ids(dow: int) -> list[str]:
            return [
                r["exercise_id"]
                for r in conn.execute(
                    "SELECT exercise_id FROM routine_exercises WHERE day_of_week = ? ORDER BY sort_order",
                    (dow,),
                ).fetchall()
            ]

        wed_ex = get_day_ex_ids(2)
        today_ex = get_day_ex_ids(today_dow)

        # Build 4 past dates (28, 21, 14, 7 days ago)
        past_dates = [(today - dt.timedelta(days=7 * k)).isoformat() for k in (4, 3, 2, 1)]

        def seed_ex_history(ex_id: str, weights_reps_per_session: list[list[tuple[int, float]]]) -> None:
            for d_str, sets_list in zip(past_dates, weights_reps_per_session):
                for idx, (reps, wt) in enumerate(sets_list, start=1):
                    conn.execute(
                        """
                        INSERT INTO workout_sets (session_date, exercise_id, set_number, reps, weight, completed, created_at)
                        VALUES (?, ?, ?, ?, ?, 1, ?)
                        """,
                        (d_str, ex_id, idx, reps, wt, stamp),
                    )

        # Upward progression profiles + 1 flat/dip profile on 4th movement
        upward_profiles = [
            [
                [(6, 20), (6, 20), (5, 20)],
                [(6, 25), (6, 25), (6, 25)],
                [(7, 25), (7, 25), (6, 25)],
                [(8, 30), (7, 30), (7, 30)],
            ],
            [
                [(8, 135), (8, 135), (8, 135)],
                [(8, 145), (8, 145), (7, 145)],
                [(9, 145), (8, 145), (8, 145)],
                [(8, 155), (8, 155), (8, 155)],
            ],
            [
                [(12, 45), (12, 45), (12, 45)],
                [(14, 45), (14, 45), (12, 45)],
                [(12, 55), (12, 55), (12, 55)],
                [(15, 55), (14, 55), (14, 55)],
            ],
            # 4th exercise dips slightly / plateaus so user sees "NO" trendline contrast
            [
                [(10, 35), (10, 35), (10, 35)],
                [(10, 35), (10, 35), (9, 35)],
                [(10, 35), (9, 35), (9, 35)],
                [(9, 35), (9, 35), (8, 35)],
            ],
        ]

        seeded_set_ids: set[str] = set()
        for ex_list in (wed_ex, today_ex):
            for idx, ex_id in enumerate(ex_list):
                if ex_id in seeded_set_ids:
                    continue
                seeded_set_ids.add(ex_id)
                profile = upward_profiles[idx % len(upward_profiles)]
                seed_ex_history(ex_id, profile)

        # Seed partial sets for today (first 2 exercises completed, 3rd pending, 4th pending) so progress bar isn't 0% or 100%
        for idx, ex_id in enumerate(today_ex):
            if idx == 0:
                for s_no, (r, w) in enumerate([(8, 35), (8, 35), (7, 35)], start=1):
                    conn.execute(
                        "INSERT INTO workout_sets (session_date, exercise_id, set_number, reps, weight, completed, created_at) VALUES (?, ?, ?, ?, ?, 1, ?)",
                        (today.isoformat(), ex_id, s_no, r, w, stamp),
                    )
            elif idx == 1:
                conn.execute(
                    "INSERT INTO workout_sets (session_date, exercise_id, set_number, reps, weight, completed, created_at) VALUES (?, ?, 1, 8, 160, 1, ?)",
                    (today.isoformat(), ex_id, stamp),
                )
                conn.execute(
                    "INSERT INTO workout_sets (session_date, exercise_id, set_number, reps, weight, completed, created_at) VALUES (?, ?, 2, 8, 160, 0, ?)",
                    (today.isoformat(), ex_id, stamp),
                )
                conn.execute(
                    "INSERT INTO workout_sets (session_date, exercise_id, set_number, reps, weight, completed, created_at) VALUES (?, ?, 3, 8, 160, 0, ?)",
                    (today.isoformat(), ex_id, stamp),
                )

    existing_recipes = conn.execute("SELECT COUNT(*) FROM recipes").fetchone()[0]
    if existing_recipes == 0:
        stamp = now_iso()
        starter_recipes = [
            {
                "id": "rec_miso_salmon",
                "title": "Miso Glazed Salmon & Buckwheat Bowl",
                "source_url": "https://www.justonecookbook.com/miso-salmon/",
                "prep_time": "20 min",
                "servings": 2,
                "kcal": 590,
                "protein_g": 44,
                "carbs_g": 46,
                "fat_g": 24,
                "dietary_tags": ["High-Protein", "Dairy-Free", "Nut-Free", "Quick <25m"],
                "allergens": ["Fish", "Soy", "Sesame"],
                "ingredients": [
                    "2 wild salmon fillets (170g each)",
                    "2 tbsp white miso paste + 1 tbsp mirin",
                    "1 tsp toasted sesame oil + 1 tsp grated ginger",
                    "1 cup toasted buckwheat groats, cooked",
                    "2 cups baby bok choy, steamed",
                ],
                "steps": [
                    "Whisk white miso, mirin, ginger, and sesame oil; brush over salmon fillets.",
                    "Broil or pan-sear skin-side down 6–8 minutes until caramelized and flaky.",
                    "Serve over warm buckwheat with steamed bok choy and toasted sesame seeds.",
                ],
                "is_saved": 1,
                "colors": ((214, 138, 108), (168, 72, 48), (64, 92, 54)),
            },
            {
                "id": "rec_lemon_chicken",
                "title": "Cast-Iron Lemon Herb Chicken & Sweet Potato",
                "source_url": "https://www.seriouseats.com/crispy-pan-seared-chicken-breast-recipe",
                "prep_time": "25 min",
                "servings": 2,
                "kcal": 540,
                "protein_g": 49,
                "carbs_g": 48,
                "fat_g": 16,
                "dietary_tags": ["High-Protein", "Gluten-Free", "Dairy-Free", "Nut-Free"],
                "allergens": [],
                "ingredients": [
                    "400g boneless skinless chicken breast, butterflied",
                    "350g sweet potato, 1/2-inch cubes",
                    "2 tbsp extra-virgin olive oil",
                    "Fresh rosemary, thyme, 2 smashed garlic cloves",
                    "1 lemon (zest and juice) + flaky sea salt",
                ],
                "steps": [
                    "Roast cubed sweet potatoes with half the olive oil, rosemary, and salt at 425°F for 20 min.",
                    "Sear seasoned chicken in cast iron 4–5 min per side; finish off-heat with lemon juice and thyme.",
                    "Slice rested chicken and plate alongside crisp roasted sweet potatoes.",
                ],
                "is_saved": 1,
                "colors": ((202, 166, 104), (176, 118, 54), (72, 106, 58)),
            },
            {
                "id": "rec_matcha_chia",
                "title": "Matcha Chia Overnight Oats",
                "source_url": "https://www.budgetbytes.com/overnight-oats/",
                "prep_time": "5 min",
                "servings": 1,
                "kcal": 410,
                "protein_g": 28,
                "carbs_g": 48,
                "fat_g": 11,
                "dietary_tags": ["Gluten-Free", "Nut-Free", "Quick <25m"],
                "allergens": ["Dairy"],
                "ingredients": [
                    "60g rolled oats + 1 tbsp black chia seeds",
                    "1 tsp ceremonial matcha whisked in warm water",
                    "180ml oat milk + 120g Greek yogurt",
                    "1 tsp maple syrup + pinch of sea salt",
                ],
                "steps": [
                    "Whisk matcha smooth in 2 tbsp warm water with zero clumps.",
                    "Stir oats, chia, yogurt, milk, and matcha in a jar; refrigerate at least 4 hours.",
                    "Top with sliced banana or berries before serving.",
                ],
                "is_saved": 1,
                "colors": ((132, 164, 114), (88, 128, 76), (232, 224, 202)),
            },
            # Discover Hub cached items (is_saved = 0)
            {
                "id": "rec_crispy_tofu",
                "title": "Crispy Chili Garlic Tofu & Jasmine Rice",
                "source_url": "https://www.budgetbytes.com/pan-fried-sesame-tofu-with-broccoli/",
                "prep_time": "22 min",
                "servings": 2,
                "kcal": 480,
                "protein_g": 27,
                "carbs_g": 54,
                "fat_g": 18,
                "dietary_tags": ["Dairy-Free", "Nut-Free", "Quick <25m"],
                "allergens": ["Soy", "Sesame"],
                "ingredients": [
                    "400g extra-firm tofu, pressed and cubed",
                    "2 tbsp cornstarch + 2 tbsp tamari",
                    "1 tbsp chili crisp + 1 tsp rice vinegar",
                    "2 cups steamed broccoli florets",
                    "2 cups cooked jasmine rice",
                ],
                "steps": [
                    "Toss cubed tofu in cornstarch and crisp in a hot skillet until golden on all sides.",
                    "Whisk tamari, chili crisp, garlic, and vinegar; glaze tofu and broccoli for 60 seconds.",
                    "Serve immediately over steamed jasmine rice.",
                ],
                "is_saved": 0,
                "colors": ((188, 88, 62), (218, 164, 96), (62, 108, 56)),
            },
            {
                "id": "rec_turkey_meatballs",
                "title": "Mediterranean Herb Turkey Meatballs & Tzatziki",
                "source_url": "https://www.recipetineats.com/greek-turkey-meatballs/",
                "prep_time": "25 min",
                "servings": 3,
                "kcal": 465,
                "protein_g": 42,
                "carbs_g": 22,
                "fat_g": 22,
                "dietary_tags": ["High-Protein", "Gluten-Free", "Nut-Free"],
                "allergens": ["Dairy", "Eggs"],
                "ingredients": [
                    "500g lean ground turkey + 1 egg",
                    "2 tbsp chopped fresh dill, oregano, grated garlic",
                    "150g strained Greek yogurt + grated cucumber",
                    "Cherry tomatoes & Kalamata olives on the side",
                ],
                "steps": [
                    "Mix turkey, egg, oregano, dill, and salt; roll into 15 meatballs.",
                    "Bake at 425°F for 16 minutes until browned and cooked through.",
                    "Fold cucumber, lemon, and dill into yogurt; serve with tomatoes and olives.",
                ],
                "is_saved": 0,
                "colors": ((176, 138, 102), (226, 220, 206), (168, 62, 54)),
            },
            {
                "id": "rec_shrimp_tacos",
                "title": "Cilantro Lime Shrimp & Avocado Corn Tacos",
                "source_url": "https://www.pinchofyum.com/spicy-shrimp-tacos-with-garlic-cilantro-lime-slaw",
                "prep_time": "18 min",
                "servings": 2,
                "kcal": 430,
                "protein_g": 36,
                "carbs_g": 42,
                "fat_g": 14,
                "dietary_tags": ["High-Protein", "Gluten-Free", "Dairy-Free", "Nut-Free", "Quick <25m"],
                "allergens": ["Shellfish"],
                "ingredients": [
                    "340g peeled wild shrimp, patted dry",
                    "1 tsp smoked paprika + 1/2 tsp cumin",
                    "6 warm corn tortillas",
                    "Shredded red cabbage, cilantro, 1 avocado, lime juice",
                ],
                "steps": [
                    "Toss shrimp with paprika, cumin, olive oil, and salt; sear 2 minutes per side.",
                    "Toss cabbage with fresh lime juice and chopped cilantro.",
                    "Layer warm corn tortillas with slaw, charred shrimp, and sliced avocado.",
                ],
                "is_saved": 0,
                "colors": ((212, 128, 92), (144, 72, 104), (118, 152, 74)),
            },
            {
                "id": "rec_steak_chimichurri",
                "title": "Seared Flank Steak & Parsley Chimichurri",
                "source_url": "https://www.seriouseats.com/sauced-chimichurri-sauce-recipe",
                "prep_time": "20 min",
                "servings": 3,
                "kcal": 510,
                "protein_g": 46,
                "carbs_g": 8,
                "fat_g": 32,
                "dietary_tags": ["High-Protein", "Gluten-Free", "Dairy-Free", "Nut-Free", "Quick <25m"],
                "allergens": [],
                "ingredients": [
                    "550g flank steak, kosher salt & black pepper",
                    "1 cup flat-leaf parsley + 3 tbsp fresh oregano, finely chopped",
                    "3 garlic cloves + 2 tbsp red wine vinegar + 1/3 cup olive oil",
                    "Red pepper flakes to taste",
                ],
                "steps": [
                    "Combine finely chopped parsley, oregano, garlic, vinegar, olive oil, and chili flakes.",
                    "Sear salted flank steak in a smoking-hot cast-iron skillet 4 min per side; rest 8 min.",
                    "Slice thinly against the grain and spoon vibrant chimichurri over top.",
                ],
                "is_saved": 0,
                "colors": ((156, 86, 68), (64, 122, 58), (210, 192, 156)),
            },
            {
                "id": "rec_chickpea_shakshuka",
                "title": "Spiced Chickpea & Roasted Pepper Skillet",
                "source_url": "https://www.bonappetit.com/recipe/chickpea-shakshuka",
                "prep_time": "24 min",
                "servings": 2,
                "kcal": 395,
                "protein_g": 19,
                "carbs_g": 46,
                "fat_g": 15,
                "dietary_tags": ["Gluten-Free", "Dairy-Free", "Nut-Free", "Quick <25m"],
                "allergens": ["Eggs"],
                "ingredients": [
                    "1 can chickpeas, drained + 1 roasted red pepper, sliced",
                    "1 can crushed fire-roasted tomatoes",
                    "1 tsp smoked paprika + 1 tsp ground cumin + 2 garlic cloves",
                    "4 pasture-raised eggs + fresh parsley",
                ],
                "steps": [
                    "Simmer garlic, cumin, paprika, tomatoes, peppers, and chickpeas for 10 minutes until thick.",
                    "Make four wells and crack eggs into the skillet; cover 5 minutes until whites set.",
                    "Finish with cracked pepper and fresh parsley.",
                ],
                "is_saved": 0,
                "colors": ((194, 78, 52), (236, 198, 86), (76, 114, 58)),
            },
        ]

        for r in starter_recipes:
            sub = "saved" if r["is_saved"] else "cache"
            fname = f"{r['id']}.jpg"
            dest = (SAVED_MEDIA_DIR if r["is_saved"] else CACHE_MEDIA_DIR) / fname
            ok = _generate_starter_dish_jpg(dest, *r["colors"])
            img_path = f"{sub}/{fname}" if ok else None
            domain = urlparse(r["source_url"]).netloc.replace("www.", "")
            conn.execute(
                """
                INSERT INTO recipes (
                    id, title, source_url, source_domain, prep_time, servings,
                    kcal, protein_g, carbs_g, fat_g, meal_type, dietary_tags, allergens,
                    ingredients, steps, image_path, image_source, is_saved,
                    discovered_at, saved_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    r["id"],
                    r["title"],
                    r["source_url"],
                    domain,
                    r["prep_time"],
                    r["servings"],
                    r["kcal"],
                    r["protein_g"],
                    r["carbs_g"],
                    r["fat_g"],
                    r.get("meal_type") or infer_meal_type(r["title"], json.dumps(r["ingredients"])),
                    json.dumps(r["dietary_tags"]),
                    json.dumps(r["allergens"]),
                    json.dumps(r["ingredients"]),
                    json.dumps(r["steps"]),
                    img_path,
                    "generated" if img_path else "placeholder",
                    r["is_saved"],
                    stamp,
                    stamp if r["is_saved"] else None,
                ),
            )
    conn.commit()


def init_db() -> sqlite3.Connection:
    conn = get_connection()
    create_tables(conn)
    sync_movekit_exercises(conn)
    seed_initial_data(conn)
    run_storage_janitor(conn, aggressive=False)
    return conn


def get_setting(conn: sqlite3.Connection, key: str, default: str = "") -> str:
    row = conn.execute("SELECT value FROM app_settings WHERE key = ?", (key,)).fetchone()
    return row["value"] if row else default


def set_setting(conn: sqlite3.Connection, key: str, value: str) -> None:
    conn.execute(
        "INSERT INTO app_settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        (key, value),
    )
    conn.commit()


def compute_exercise_progression(conn: sqlite3.Connection, exercise_id: str) -> dict[str, Any]:
    rows = conn.execute(
        """
        SELECT session_date,
               SUM(reps * weight) AS total_volume,
               SUM(reps) AS total_reps,
               MAX(weight) AS max_weight,
               COUNT(*) AS set_count
        FROM workout_sets
        WHERE exercise_id = ? AND completed = 1
        GROUP BY session_date
        ORDER BY session_date DESC
        LIMIT 8
        """,
        (exercise_id,),
    ).fetchall()

    ordered = list(reversed(rows))
    if not ordered:
        return {
            "status": "baseline",
            "moving_more": None,
            "slope": 0.0,
            "delta_pct": 0.0,
            "metric_unit": "vol",
            "latest_volume": 0.0,
            "sessions": [],
            "trend_points": [],
        }

    use_reps_only = all((r["total_volume"] or 0.0) == 0.0 for r in ordered)
    metric_unit = "reps" if use_reps_only else "vol"
    sessions = []
    ys: list[float] = []
    for r in ordered:
        val = float(r["total_reps"] or 0) if use_reps_only else float(r["total_volume"] or 0.0)
        ys.append(round(val, 1))
        sessions.append(
            {
                "date": r["session_date"],
                "volume": round(val, 1),
                "max_weight": round(float(r["max_weight"] or 0.0), 1),
                "sets": int(r["set_count"] or 0),
            }
        )

    n = len(ys)
    if n < 2:
        return {
            "status": "baseline",
            "moving_more": None,
            "slope": 0.0,
            "delta_pct": 0.0,
            "metric_unit": metric_unit,
            "latest_volume": ys[-1],
            "sessions": sessions,
            "trend_points": ys[:],
        }

    x_mean = (n - 1) / 2.0
    y_mean = sum(ys) / n
    denom = sum((i - x_mean) ** 2 for i in range(n))
    slope = sum((i - x_mean) * (ys[i] - y_mean) for i in range(n)) / denom if denom else 0.0
    intercept = y_mean - slope * x_mean
    trend_points = [round(max(0.0, intercept + slope * i), 1) for i in range(n)]

    first_y = ys[0]
    last_y = ys[-1]
    delta_pct = round(((last_y - first_y) / first_y) * 100.0, 1) if first_y > 0 else 0.0

    if slope > 0.0001:
        moving_more = True
        status = "yes"
    else:
        moving_more = False
        status = "flat" if abs(delta_pct) <= 1.0 else "no"

    return {
        "status": status,
        "moving_more": moving_more,
        "slope": round(slope, 3),
        "delta_pct": delta_pct,
        "metric_unit": metric_unit,
        "latest_volume": ys[-1],
        "sessions": sessions,
        "trend_points": trend_points,
    }


def _dir_bytes(path: Path) -> tuple[int, int]:
    if not path.exists():
        return 0, 0
    total = 0
    count = 0
    for p in path.iterdir():
        if p.is_file():
            try:
                total += p.stat().st_size
                count += 1
            except OSError:
                pass
    return total, count


def _sqlite_bytes() -> int:
    total = 0
    for suffix in ("", "-wal", "-shm"):
        p = Path(str(DB_PATH) + suffix)
        if p.exists():
            try:
                total += p.stat().st_size
            except OSError:
                pass
    return total


def get_storage_metrics(conn: sqlite3.Connection) -> dict[str, Any]:
    db_bytes = _sqlite_bytes()
    saved_bytes, saved_files = _dir_bytes(SAVED_MEDIA_DIR)
    cache_bytes, cache_files = _dir_bytes(CACHE_MEDIA_DIR)
    mk = get_movekit_dir_stats()

    saved_recipes = conn.execute("SELECT COUNT(*) FROM recipes WHERE is_saved = 1").fetchone()[0]
    cached_recipes = conn.execute("SELECT COUNT(*) FROM recipes WHERE is_saved = 0").fetchone()[0]
    custom_ex = conn.execute("SELECT COUNT(*) FROM exercises WHERE is_custom = 1").fetchone()[0]
    total_sets = conn.execute("SELECT COUNT(*) FROM workout_sets").fetchone()[0]

    ttl_days = int(get_setting(conn, "cache_ttl_days", "7") or 7)
    max_mb = int(get_setting(conn, "cache_max_mb", "25") or 25)
    weight_unit = get_setting(conn, "weight_unit", "lbs") or "lbs"
    raw_key = get_setting(conn, "gemini_api_key", "") or os.environ.get("GEMINI_API_KEY", "").strip()
    masked_key = ""
    if raw_key:
        masked_key = f"{raw_key[:4]}••••{raw_key[-4:]}" if len(raw_key) > 8 else "••••"

    app_data_bytes = db_bytes + saved_bytes + cache_bytes
    return {
        "db_bytes": db_bytes,
        "saved_media_bytes": saved_bytes,
        "saved_media_files": saved_files,
        "cache_media_bytes": cache_bytes,
        "cache_media_files": cache_files,
        "app_data_bytes": app_data_bytes,
        "movekit_count": mk["count"],
        "movekit_bytes": mk["bytes"],
        "projected_ios_hevc_bytes": 350 * 1024 * 1024,
        "counts": {
            "saved_recipes": saved_recipes,
            "cached_recipes": cached_recipes,
            "custom_exercises": custom_ex,
            "total_sets": total_sets,
        },
        "settings": {
            "has_api_key": bool(raw_key),
            "masked_api_key": masked_key,
            "weight_unit": weight_unit,
            "cache_ttl_days": ttl_days,
            "cache_max_mb": max_mb,
        },
    }


def _unlink_recipe_image(image_path: str | None) -> None:
    if not image_path:
        return
    clean = image_path.lstrip("/")
    p = DATA_DIR / "media" / clean
    if p.exists() and p.is_file():
        p.unlink(missing_ok=True)


def run_storage_janitor(conn: sqlite3.Connection, aggressive: bool = False) -> dict[str, int]:
    before_bytes = _sqlite_bytes() + _dir_bytes(CACHE_MEDIA_DIR)[0]
    deleted_recipes = 0
    deleted_orphans = 0

    ttl_days = int(get_setting(conn, "cache_ttl_days", "7") or 7)
    max_mb = int(get_setting(conn, "cache_max_mb", "25") or 25)
    max_cache_bytes = max(1, max_mb) * 1024 * 1024

    if aggressive:
        rows = conn.execute("SELECT id, image_path FROM recipes WHERE is_saved = 0").fetchall()
        for r in rows:
            _unlink_recipe_image(r["image_path"])
        cur = conn.execute("DELETE FROM recipes WHERE is_saved = 0")
        deleted_recipes += cur.rowcount
    else:
        cutoff = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=ttl_days)).replace(microsecond=0).isoformat()
        expired = conn.execute(
            "SELECT id, image_path FROM recipes WHERE is_saved = 0 AND discovered_at < ?",
            (cutoff,),
        ).fetchall()
        for r in expired:
            _unlink_recipe_image(r["image_path"])
            conn.execute("DELETE FROM recipes WHERE id = ?", (r["id"],))
            deleted_recipes += 1

        # Enforce cache size cap by trimming oldest unsaved items
        while _dir_bytes(CACHE_MEDIA_DIR)[0] > max_cache_bytes:
            oldest = conn.execute(
                "SELECT id, image_path FROM recipes WHERE is_saved = 0 ORDER BY discovered_at ASC LIMIT 1"
            ).fetchone()
            if not oldest:
                break
            _unlink_recipe_image(oldest["image_path"])
            conn.execute("DELETE FROM recipes WHERE id = ?", (oldest["id"],))
            deleted_recipes += 1

    # Remove orphaned files in CACHE_MEDIA_DIR not referenced by any recipe
    referenced_cache_names = {
        Path(r["image_path"]).name
        for r in conn.execute("SELECT image_path FROM recipes WHERE image_path LIKE 'cache/%'").fetchall()
        if r["image_path"]
    }
    if CACHE_MEDIA_DIR.exists():
        for f in CACHE_MEDIA_DIR.iterdir():
            if f.is_file() and f.name not in referenced_cache_names:
                f.unlink(missing_ok=True)
                deleted_orphans += 1

    conn.commit()
    if aggressive or deleted_recipes > 0:
        conn.execute("VACUUM;")
        conn.commit()

    after_bytes = _sqlite_bytes() + _dir_bytes(CACHE_MEDIA_DIR)[0]
    return {
        "reclaimed_bytes": max(0, before_bytes - after_bytes),
        "deleted_recipes": deleted_recipes,
        "deleted_orphan_files": deleted_orphans,
    }


def _row_to_recipe(r: sqlite3.Row) -> dict[str, Any]:
    raw_meal = r["meal_type"] if "meal_type" in r.keys() else ""
    meal_type = raw_meal or infer_meal_type(r["title"], r["ingredients"] or "")
    return {
        "id": r["id"],
        "title": r["title"],
        "source_url": r["source_url"],
        "source_domain": r["source_domain"],
        "prep_time": r["prep_time"] or "",
        "servings": int(r["servings"] or 2),
        "kcal": int(r["kcal"] or 0),
        "protein_g": int(r["protein_g"] or 0),
        "carbs_g": int(r["carbs_g"] or 0),
        "fat_g": int(r["fat_g"] or 0),
        "meal_type": meal_type,
        "dietary_tags": json.loads(r["dietary_tags"] or "[]"),
        "allergens": json.loads(r["allergens"] or "[]"),
        "ingredients": json.loads(r["ingredients"] or "[]"),
        "steps": json.loads(r["steps"] or "[]"),
        "image_url": f"/media/{r['image_path']}" if r["image_path"] else None,
        "image_source": r["image_source"] or "placeholder",
        "is_saved": bool(r["is_saved"]),
        "discovered_at": r["discovered_at"],
        "saved_at": r["saved_at"],
    }


def list_recipes(conn: sqlite3.Connection) -> dict[str, list[dict[str, Any]]]:
    rows = conn.execute(
        "SELECT * FROM recipes ORDER BY is_saved DESC, COALESCE(saved_at, discovered_at) DESC"
    ).fetchall()
    saved: list[dict[str, Any]] = []
    discover: list[dict[str, Any]] = []
    for r in rows:
        item = _row_to_recipe(r)
        if item["is_saved"]:
            saved.append(item)
        else:
            discover.append(item)
    return {"saved": saved, "discover": discover}


def toggle_recipe_saved(conn: sqlite3.Connection, recipe_id: str) -> dict[str, Any] | None:
    row = conn.execute("SELECT * FROM recipes WHERE id = ?", (recipe_id,)).fetchone()
    if not row:
        return None
    new_saved = 0 if row["is_saved"] else 1
    img_path = row["image_path"]
    new_img_path = img_path

    if img_path:
        src = DATA_DIR / "media" / img_path
        fname = Path(img_path).name
        target_sub = "saved" if new_saved else "cache"
        dst = (SAVED_MEDIA_DIR if new_saved else CACHE_MEDIA_DIR) / fname
        if src.exists() and src != dst:
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(src), str(dst))
        if dst.exists():
            new_img_path = f"{target_sub}/{fname}"

    saved_at = now_iso() if new_saved else None
    conn.execute(
        "UPDATE recipes SET is_saved = ?, image_path = ?, saved_at = ? WHERE id = ?",
        (new_saved, new_img_path, saved_at, recipe_id),
    )
    conn.commit()
    updated = conn.execute("SELECT * FROM recipes WHERE id = ?", (recipe_id,)).fetchone()
    return _row_to_recipe(updated)


def get_day_workout(conn: sqlite3.Connection, day_of_week: int, session_date: str) -> dict[str, Any]:
    routine = conn.execute(
        "SELECT day_of_week, title FROM day_routines WHERE day_of_week = ?",
        (day_of_week,),
    ).fetchone()
    title = routine["title"] if routine else f"{DAY_FULL_NAMES[day_of_week]} Routine"

    ex_rows = conn.execute(
        """
        SELECT e.id, e.name, e.video_filename, e.muscle_hint, e.is_custom, re.sort_order
        FROM routine_exercises re
        JOIN exercises e ON e.id = re.exercise_id
        WHERE re.day_of_week = ?
        ORDER BY re.sort_order ASC, re.id ASC
        """,
        (day_of_week,),
    ).fetchall()

    exercises_payload: list[dict[str, Any]] = []
    total_sets_done = 0
    exercises_with_completed_set = 0

    for er in ex_rows:
        ex_id = er["id"]
        sets_rows = conn.execute(
            """
            SELECT id, set_number, reps, weight, completed
            FROM workout_sets
            WHERE session_date = ? AND exercise_id = ?
            ORDER BY set_number ASC, id ASC
            """,
            (session_date, ex_id),
        ).fetchall()

        sets_list = [
            {
                "id": s["id"],
                "set_number": s["set_number"],
                "reps": int(s["reps"]),
                "weight": float(s["weight"]),
                "completed": bool(s["completed"]),
            }
            for s in sets_rows
        ]
        done_here = sum(1 for s in sets_list if s["completed"])
        total_sets_done += done_here
        if done_here > 0:
            exercises_with_completed_set += 1

        # Also provide last recorded working set template from any prior session for quick prefill
        last_set = conn.execute(
            """
            SELECT reps, weight
            FROM workout_sets
            WHERE exercise_id = ? AND completed = 1
            ORDER BY session_date DESC, set_number DESC
            LIMIT 1
            """,
            (ex_id,),
        ).fetchone()

        prog = compute_exercise_progression(conn, ex_id)
        exercises_payload.append(
            {
                "id": ex_id,
                "name": er["name"],
                "video_url": f"/api/videos/{er['video_filename']}" if er["video_filename"] else None,
                "video_filename": er["video_filename"],
                "muscle_hint": er["muscle_hint"] or "Strength",
                "is_custom": bool(er["is_custom"]),
                "sets": sets_list,
                "suggested_reps": int(last_set["reps"]) if last_set else 8,
                "suggested_weight": float(last_set["weight"]) if last_set else 0.0,
                "progression": prog,
            }
        )

    total_exercises = len(exercises_payload)
    if total_exercises == 0:
        completion_pct = 100
    else:
        completion_pct = round((exercises_with_completed_set / total_exercises) * 100)

    return {
        "day_of_week": day_of_week,
        "day_name": DAY_NAMES[day_of_week],
        "day_full_name": DAY_FULL_NAMES[day_of_week],
        "session_date": session_date,
        "title": title,
        "exercises": exercises_payload,
        "completion_pct": completion_pct,
        "completed_exercises": exercises_with_completed_set,
        "total_exercises": total_exercises,
        "total_sets_done": total_sets_done,
    }


def get_all_day_summaries(conn: sqlite3.Connection) -> list[dict[str, Any]]:
    rows = conn.execute(
        """
        SELECT dr.day_of_week, dr.title, COUNT(re.id) AS ex_count
        FROM day_routines dr
        LEFT JOIN routine_exercises re ON re.day_of_week = dr.day_of_week
        GROUP BY dr.day_of_week
        ORDER BY dr.day_of_week ASC
        """
    ).fetchall()
    return [
        {
            "day_of_week": r["day_of_week"],
            "day_short": DAY_NAMES[r["day_of_week"]].upper(),
            "title": r["title"],
            "exercise_count": int(r["ex_count"]),
        }
        for r in rows
    ]
