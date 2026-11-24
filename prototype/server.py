"""Local HTTP, Range-capable MP4 video streamer, and SQLite REST server for Parchment & Ink."""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import difflib
import json
import mimetypes
import os
import re
import sqlite3
import threading
import time
import uuid
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, unquote, urlparse

import db
from gemini_recipes import (
    GeminiDiscoveryError,
    discover_recipes_via_hydrogen,
    save_compressed_image_bytes,
)

STATIC_DIR = Path(__file__).resolve().parent / "static"
DB_LOCK = threading.RLock()
CONN: sqlite3.Connection | None = None


def get_db() -> sqlite3.Connection:
    global CONN
    if CONN is None:
        CONN = db.init_db()
    return CONN


def _safe_child(base_dir: Path, rel_name: str) -> Path | None:
    clean = os.path.basename(unquote(rel_name))
    if not clean or clean in {".", ".."}:
        return None
    target = (base_dir / clean).resolve()
    try:
        base_resolved = base_dir.resolve()
        if os.path.commonpath([str(base_resolved), str(target)]) != str(base_resolved):
            return None
    except ValueError:
        return None
    return target


_EXERCISE_ALIASES = {
    "rdl": "romanian deadlift",
    "rdls": "romanian deadlift",
    "ohp": "overhead press",
    "db": "dumbbell",
    "bb": "barbell",
    "kb": "kettlebell",
    "bw": "bodyweight",
    "bicep": "curl arms",
    "biceps": "curl arms",
    "tricep": "tricep pushdown skullcrusher",
    "triceps": "tricep pushdown skullcrusher",
    "abs": "core abdominal",
    "pullup": "pull up",
    "pullups": "pull up",
    "pushup": "push up",
    "pushups": "push up",
    "chinup": "chin up",
    "chinups": "chin up",
}


def _norm_text(s: str) -> str:
    cleaned = re.sub(r"[^a-z0-9]+", " ", s.lower()).strip()
    return cleaned


def _singularize(tok: str) -> str:
    return tok[:-1] if len(tok) > 3 and tok.endswith("s") else tok


def _fuzzy_search_exercises(rows: list[sqlite3.Row], query: str, limit: int) -> list[sqlite3.Row]:
    q_norm = _norm_text(query)
    if not q_norm:
        return rows[:limit]

    raw_tokens = q_norm.split()
    expanded_tokens: list[str] = []
    for tok in raw_tokens:
        alias = _EXERCISE_ALIASES.get(tok)
        if alias:
            expanded_tokens.extend(alias.split())
        else:
            expanded_tokens.append(tok)
    q_tokens = [_singularize(t) for t in expanded_tokens]
    q_compact = "".join(q_tokens)

    scored: list[tuple[float, int, str, sqlite3.Row]] = []
    for r in rows:
        name = str(r["name"])
        muscle = str(r["muscle_hint"] or "")
        cand_norm = _norm_text(name)
        cand_tokens = [_singularize(t) for t in cand_norm.split()]
        cand_compact = "".join(cand_tokens)
        haystack = f"{cand_norm} {_norm_text(muscle)} {cand_compact}"

        score = 0.0
        if cand_norm == q_norm or cand_compact == q_compact:
            score = 100.0
        elif cand_norm.startswith(q_norm) or cand_compact.startswith(q_compact):
            score = 95.0
        elif all(t in haystack for t in q_tokens):
            in_name = sum(1 for t in q_tokens if t in cand_norm or t in cand_compact)
            score = 82.0 + (in_name / max(1, len(q_tokens))) * 10.0
        else:
            all_cand_tokens = cand_tokens + [_singularize(t) for t in _norm_text(muscle).split()]
            tok_ratios: list[float] = []
            for qt in q_tokens:
                best = 0.0
                for ct in all_cand_tokens:
                    if qt in ct:
                        best = max(best, 0.92)
                    else:
                        best = max(best, difflib.SequenceMatcher(None, qt, ct).ratio())
                tok_ratios.append(best)
            min_tok = min(tok_ratios) if tok_ratios else 0.0
            avg_tok = sum(tok_ratios) / max(1, len(tok_ratios))
            if min_tok >= 0.68 or avg_tok >= 0.74:
                score = 55.0 + avg_tok * 24.0
            else:
                full_ratio = difflib.SequenceMatcher(None, q_compact, cand_compact).ratio()
                if full_ratio >= 0.58:
                    score = 35.0 + full_ratio * 25.0

        if score > 0.0:
            scored.append((score, 1 if r["is_custom"] else 0, name, r))

    scored.sort(key=lambda item: (-item[0], -item[1], item[2]))
    return [item[3] for item in scored[:limit]]


def _safe_static_path(rel_path: str) -> Path | None:
    stripped = unquote(rel_path).lstrip("/")
    if not stripped:
        stripped = "index.html"
    target = (STATIC_DIR / stripped).resolve()
    try:
        base_resolved = STATIC_DIR.resolve()
        if os.path.commonpath([str(base_resolved), str(target)]) != str(base_resolved):
            return None
    except ValueError:
        return None
    return target


class LedgerHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format: str, *args: Any) -> None:
        # Suppress noisy broken-pipe / static logs while keeping genuine errors visible
        pass

    def _send_json(self, status: int, data: Any) -> None:
        payload = json.dumps(data).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _read_json_body(self) -> dict[str, Any]:
        length = int(self.headers.get("Content-Length", "0") or 0)
        if length <= 0:
            return {}
        if length > 20_000_000:
            raise ValueError("Payload too large")
        raw = self.rfile.read(length)
        if not raw:
            return {}
        data = json.loads(raw.decode("utf-8"))
        return data if isinstance(data, dict) else {}

    def _serve_file(self, path: Path, cache_control: str = "no-cache") -> None:
        if not path.exists() or not path.is_file():
            self._send_json(HTTPStatus.NOT_FOUND, {"error": "not_found"})
            return
        ctype, _ = mimetypes.guess_type(str(path))
        if not ctype:
            ctype = "application/octet-stream"
        data = path.read_bytes()
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", cache_control)
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _serve_video_range(self, path: Path) -> None:
        if not path.exists() or not path.is_file() or path.suffix.lower() != ".mp4":
            self._send_json(HTTPStatus.NOT_FOUND, {"error": "video_not_found"})
            return

        file_size = path.stat().st_size
        range_hdr = self.headers.get("Range")
        start = 0
        end = file_size - 1
        status = HTTPStatus.OK

        if range_hdr:
            m = re.match(r"bytes=(\d*)-(\d*)", range_hdr.strip())
            if m:
                s_str, e_str = m.groups()
                if s_str == "" and e_str != "":
                    suffix_len = int(e_str)
                    start = max(0, file_size - suffix_len)
                    end = file_size - 1
                else:
                    start = int(s_str) if s_str else 0
                    end = int(e_str) if e_str else file_size - 1
                if start >= file_size or end < start:
                    self.send_response(HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE)
                    self.send_header("Content-Range", f"bytes */{file_size}")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                end = min(end, file_size - 1)
                status = HTTPStatus.PARTIAL_CONTENT

        chunk_len = end - start + 1
        self.send_response(status)
        self.send_header("Content-Type", "video/mp4")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(chunk_len))
        self.send_header("Cache-Control", "public, max-age=86400")
        if status == HTTPStatus.PARTIAL_CONTENT:
            self.send_header("Content-Range", f"bytes {start}-{end}/{file_size}")
        self.end_headers()

        try:
            with path.open("rb") as fh:
                fh.seek(start)
                remaining = chunk_len
                while remaining > 0:
                    buf = fh.read(min(65536, remaining))
                    if not buf:
                        break
                    self.wfile.write(buf)
                    remaining -= len(buf)
        except (BrokenPipeError, ConnectionResetError):
            # Normal when browser pauses, loops, or collapses inline video player
            pass

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        path = parsed.path
        qs = parse_qs(parsed.query)

        if path == "/":
            self._serve_file(STATIC_DIR / "index.html")
            return

        if path.startswith("/static/"):
            target = _safe_static_path(path[len("/static/"):])
            if not target:
                self._send_json(HTTPStatus.FORBIDDEN, {"error": "forbidden"})
                return
            self._serve_file(target)
            return

        if path.startswith("/api/videos/"):
            fname = path[len("/api/videos/"):]
            target = _safe_child(db.MOVEKIT_DIR, fname)
            if not target:
                self._send_json(HTTPStatus.NOT_FOUND, {"error": "invalid_video"})
                return
            self._serve_video_range(target)
            return

        if path.startswith("/media/saved/"):
            target = _safe_child(db.SAVED_MEDIA_DIR, path[len("/media/saved/"):])
            if not target:
                self._send_json(HTTPStatus.NOT_FOUND, {"error": "not_found"})
                return
            self._serve_file(target, cache_control="no-cache")
            return

        if path.startswith("/media/cache/"):
            target = _safe_child(db.CACHE_MEDIA_DIR, path[len("/media/cache/"):])
            if not target:
                self._send_json(HTTPStatus.NOT_FOUND, {"error": "not_found"})
                return
            self._serve_file(target, cache_control="no-cache")
            return

        with DB_LOCK:
            conn = get_db()

            if path == "/api/bootstrap":
                s_date = (qs.get("date") or [db.today_str()])[0]
                try:
                    d_obj = dt.date.fromisoformat(s_date)
                except ValueError:
                    d_obj = dt.date.today()
                    s_date = d_obj.isoformat()
                dow = d_obj.weekday()
                self._send_json(
                    HTTPStatus.OK,
                    {
                        "today_date": s_date,
                        "today_dow": dow,
                        "day_summaries": db.get_all_day_summaries(conn),
                        "workout": db.get_day_workout(conn, dow, s_date),
                        "recipes": db.list_recipes(conn),
                        "storage": db.get_storage_metrics(conn),
                    },
                )
                return

            if path == "/api/exercises":
                q = (qs.get("q") or [""])[0].strip()
                limit = min(100, max(1, int((qs.get("limit") or ["40"])[0] or 40)))
                all_rows = conn.execute(
                    """
                    SELECT id, name, video_filename, muscle_hint, is_custom
                    FROM exercises
                    ORDER BY is_custom DESC, name ASC
                    """
                ).fetchall()
                if not q:
                    matched_rows = all_rows[:limit]
                else:
                    matched_rows = _fuzzy_search_exercises(all_rows, q, limit)
                items = [
                    {
                        "id": r["id"],
                        "name": r["name"],
                        "video_filename": r["video_filename"],
                        "video_url": f"/api/videos/{r['video_filename']}" if r["video_filename"] else None,
                        "muscle_hint": r["muscle_hint"] or "Strength",
                        "is_custom": bool(r["is_custom"]),
                    }
                    for r in matched_rows
                ]
                self._send_json(HTTPStatus.OK, {"exercises": items})
                return

            if path == "/api/workouts":
                s_date = (qs.get("date") or [db.today_str()])[0]
                try:
                    d_obj = dt.date.fromisoformat(s_date)
                except ValueError:
                    d_obj = dt.date.today()
                    s_date = d_obj.isoformat()
                day_raw = (qs.get("day") or [str(d_obj.weekday())])[0]
                dow = max(0, min(6, int(day_raw)))
                self._send_json(HTTPStatus.OK, db.get_day_workout(conn, dow, s_date))
                return

            if path == "/api/storage":
                self._send_json(HTTPStatus.OK, db.get_storage_metrics(conn))
                return

        self._send_json(HTTPStatus.NOT_FOUND, {"error": "unknown_route"})

    def do_PUT(self) -> None:
        parsed = urlparse(self.path)
        path = parsed.path
        try:
            body = self._read_json_body()
        except Exception as exc:
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": "invalid_json", "message": str(exc)})
            return

        m = re.match(r"^/api/routines/(\d+)$", path)
        if m:
            dow = int(m.group(1))
            if not (0 <= dow <= 6):
                self._send_json(HTTPStatus.BAD_REQUEST, {"error": "invalid_day"})
                return
            with DB_LOCK:
                conn = get_db()
                stamp = db.now_iso()
                if "title" in body:
                    title = str(body["title"]).strip() or f"{db.DAY_FULL_NAMES[dow]} Routine"
                    conn.execute(
                        "INSERT INTO day_routines (day_of_week, title, updated_at) VALUES (?, ?, ?) "
                        "ON CONFLICT(day_of_week) DO UPDATE SET title = excluded.title, updated_at = excluded.updated_at",
                        (dow, title, stamp),
                    )
                if "exercise_ids" in body and isinstance(body["exercise_ids"], list):
                    conn.execute("DELETE FROM routine_exercises WHERE day_of_week = ?", (dow,))
                    for idx, ex_id in enumerate(body["exercise_ids"]):
                        conn.execute(
                            "INSERT OR IGNORE INTO routine_exercises (day_of_week, exercise_id, sort_order) VALUES (?, ?, ?)",
                            (dow, str(ex_id), idx),
                        )
                conn.commit()
                s_date = str(body.get("session_date") or db.today_str())
                self._send_json(
                    HTTPStatus.OK,
                    {
                        "workout": db.get_day_workout(conn, dow, s_date),
                        "day_summaries": db.get_all_day_summaries(conn),
                    },
                )
            return

        self._send_json(HTTPStatus.NOT_FOUND, {"error": "unknown_route"})

    def do_DELETE(self) -> None:
        parsed = urlparse(self.path)
        path = parsed.path
        qs = parse_qs(parsed.query)

        m_ex = re.match(r"^/api/routines/(\d+)/exercises/([^/]+)$", path)
        if m_ex:
            dow = int(m_ex.group(1))
            ex_id = unquote(m_ex.group(2))
            s_date = (qs.get("date") or [db.today_str()])[0]
            with DB_LOCK:
                conn = get_db()
                conn.execute(
                    "DELETE FROM routine_exercises WHERE day_of_week = ? AND exercise_id = ?",
                    (dow, ex_id),
                )
                conn.commit()
                self._send_json(
                    HTTPStatus.OK,
                    {
                        "workout": db.get_day_workout(conn, dow, s_date),
                        "day_summaries": db.get_all_day_summaries(conn),
                    },
                )
            return

        m_set = re.match(r"^/api/workouts/sets/(\d+)$", path)
        if m_set:
            set_id = int(m_set.group(1))
            with DB_LOCK:
                conn = get_db()
                row = conn.execute(
                    "SELECT session_date, exercise_id FROM workout_sets WHERE id = ?",
                    (set_id,),
                ).fetchone()
                if not row:
                    self._send_json(HTTPStatus.NOT_FOUND, {"error": "set_not_found"})
                    return
                s_date = row["session_date"]
                ex_id = row["exercise_id"]
                conn.execute("DELETE FROM workout_sets WHERE id = ?", (set_id,))
                # Renumber remaining sets for cleanliness
                rem = conn.execute(
                    "SELECT id FROM workout_sets WHERE session_date = ? AND exercise_id = ? ORDER BY set_number ASC, id ASC",
                    (s_date, ex_id),
                ).fetchall()
                for idx, r in enumerate(rem, start=1):
                    conn.execute("UPDATE workout_sets SET set_number = ? WHERE id = ?", (idx, r["id"]))
                conn.commit()

                dow_param = (qs.get("day") or [None])[0]
                dow = int(dow_param) if dow_param is not None else dt.date.fromisoformat(s_date).weekday()
                self._send_json(
                    HTTPStatus.OK,
                    {
                        "workout": db.get_day_workout(conn, dow, s_date),
                        "storage": db.get_storage_metrics(conn),
                    },
                )
            return

        self._send_json(HTTPStatus.NOT_FOUND, {"error": "unknown_route"})

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        path = parsed.path
        try:
            body = self._read_json_body()
        except Exception as exc:
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": "invalid_json", "message": str(exc)})
            return

        if path == "/api/exercises/custom":
            name = str(body.get("name", "")).strip()
            if not name:
                self._send_json(HTTPStatus.BAD_REQUEST, {"error": "name_required"})
                return
            video_fn = body.get("video_filename")
            video_fn = os.path.basename(str(video_fn).strip()) if video_fn else None
            if video_fn and not (db.MOVEKIT_DIR / video_fn).exists():
                video_fn = None
            muscle_hint = str(body.get("muscle_hint") or "Custom").strip()
            ex_id = f"cust_{uuid.uuid4().hex[:8]}"
            with DB_LOCK:
                conn = get_db()
                conn.execute(
                    "INSERT INTO exercises (id, name, video_filename, muscle_hint, is_custom, created_at) VALUES (?, ?, ?, ?, 1, ?)",
                    (ex_id, name, video_fn, muscle_hint, db.now_iso()),
                )
                if "day_of_week" in body and body["day_of_week"] is not None:
                    dow = max(0, min(6, int(body["day_of_week"])))
                    max_ord = conn.execute(
                        "SELECT COALESCE(MAX(sort_order), -1) FROM routine_exercises WHERE day_of_week = ?",
                        (dow,),
                    ).fetchone()[0]
                    conn.execute(
                        "INSERT OR IGNORE INTO routine_exercises (day_of_week, exercise_id, sort_order) VALUES (?, ?, ?)",
                        (dow, ex_id, int(max_ord) + 1),
                    )
                conn.commit()
                s_date = str(body.get("session_date") or db.today_str())
                dow = int(body.get("day_of_week") if body.get("day_of_week") is not None else dt.date.fromisoformat(s_date).weekday())
                self._send_json(
                    HTTPStatus.OK,
                    {
                        "exercise": {
                            "id": ex_id,
                            "name": name,
                            "video_filename": video_fn,
                            "video_url": f"/api/videos/{video_fn}" if video_fn else None,
                            "muscle_hint": muscle_hint,
                            "is_custom": True,
                        },
                        "workout": db.get_day_workout(conn, dow, s_date),
                        "day_summaries": db.get_all_day_summaries(conn),
                    },
                )
            return

        m_add_ex = re.match(r"^/api/routines/(\d+)/exercises$", path)
        if m_add_ex:
            dow = int(m_add_ex.group(1))
            ex_id = str(body.get("exercise_id", "")).strip()
            if not (0 <= dow <= 6) or not ex_id:
                self._send_json(HTTPStatus.BAD_REQUEST, {"error": "invalid_params"})
                return
            with DB_LOCK:
                conn = get_db()
                exists = conn.execute("SELECT id FROM exercises WHERE id = ?", (ex_id,)).fetchone()
                if not exists:
                    self._send_json(HTTPStatus.NOT_FOUND, {"error": "exercise_not_found"})
                    return
                max_ord = conn.execute(
                    "SELECT COALESCE(MAX(sort_order), -1) FROM routine_exercises WHERE day_of_week = ?",
                    (dow,),
                ).fetchone()[0]
                conn.execute(
                    "INSERT OR IGNORE INTO routine_exercises (day_of_week, exercise_id, sort_order) VALUES (?, ?, ?)",
                    (dow, ex_id, int(max_ord) + 1),
                )
                conn.commit()
                s_date = str(body.get("session_date") or db.today_str())
                self._send_json(
                    HTTPStatus.OK,
                    {
                        "workout": db.get_day_workout(conn, dow, s_date),
                        "day_summaries": db.get_all_day_summaries(conn),
                    },
                )
            return

        if path == "/api/workouts/sets":
            ex_id = str(body.get("exercise_id", "")).strip()
            s_date = str(body.get("session_date") or db.today_str())
            reps = max(0, int(body.get("reps") or 0))
            weight = max(0.0, float(body.get("weight") or 0.0))
            completed = 1 if body.get("completed", True) else 0
            set_id = body.get("id")
            dow = int(body.get("day_of_week") if body.get("day_of_week") is not None else dt.date.fromisoformat(s_date).weekday())

            with DB_LOCK:
                conn = get_db()
                if set_id is not None:
                    conn.execute(
                        "UPDATE workout_sets SET reps = ?, weight = ?, completed = ? WHERE id = ?",
                        (reps, weight, completed, int(set_id)),
                    )
                else:
                    if not ex_id:
                        self._send_json(HTTPStatus.BAD_REQUEST, {"error": "exercise_id_required"})
                        return
                    next_num = conn.execute(
                        "SELECT COALESCE(MAX(set_number), 0) + 1 FROM workout_sets WHERE session_date = ? AND exercise_id = ?",
                        (s_date, ex_id),
                    ).fetchone()[0]
                    cur = conn.execute(
                        "INSERT INTO workout_sets (session_date, exercise_id, set_number, reps, weight, completed, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
                        (s_date, ex_id, int(next_num), reps, weight, completed, db.now_iso()),
                    )
                    set_id = cur.lastrowid
                conn.commit()
                self._send_json(
                    HTTPStatus.OK,
                    {
                        "set_id": set_id,
                        "workout": db.get_day_workout(conn, dow, s_date),
                        "storage": db.get_storage_metrics(conn),
                    },
                )
            return

        if path == "/api/recipes/discover":
            query = str(body.get("query", "")).strip()
            filters = body.get("dietary_filters") or []
            raw_meal = str(body.get("meal_type", "")).strip()
            meal_type = "" if raw_meal.lower() in {"", "all", "all meals"} else raw_meal
            if not query:
                self._send_json(HTTPStatus.BAD_REQUEST, {"error": "query_required", "message": "Enter a dish or ingredient to crawl."})
                return

            with DB_LOCK:
                conn = get_db()
                api_key = db.get_setting(conn, "gemini_api_key", "") or os.environ.get("GEMINI_API_KEY", "").strip()

            try:
                found = discover_recipes_via_hydrogen(
                    api_key=api_key,
                    query=query,
                    dietary_filters=[str(f) for f in filters],
                    cache_media_dir=db.CACHE_MEDIA_DIR,
                    meal_type=meal_type,
                )
            except GeminiDiscoveryError as exc:
                status = HTTPStatus.BAD_REQUEST if exc.code == "missing_api_key" else HTTPStatus.BAD_GATEWAY
                self._send_json(HTTPStatus.BAD_REQUEST if exc.code in {"missing_api_key", "no_recipes", "verification_failed"} else status, {"error": exc.code, "message": exc.message})
                return
            except Exception as exc:
                self._send_json(HTTPStatus.BAD_GATEWAY, {"error": "unexpected_discovery_error", "message": str(exc)})
                return

            with DB_LOCK:
                conn = get_db()
                stamp = db.now_iso()
                for r in found:
                    conn.execute(
                        """
                        INSERT INTO recipes (
                            id, title, source_url, source_domain, prep_time, servings,
                            kcal, protein_g, carbs_g, fat_g, meal_type, dietary_tags, allergens,
                            ingredients, steps, image_path, image_source, is_saved,
                            discovered_at, saved_at
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, NULL)
                        """,
                        (
                            r["id"],
                            r["title"],
                            r["source_url"],
                            r["source_domain"],
                            r["prep_time"],
                            r["servings"],
                            r["kcal"],
                            r["protein_g"],
                            r["carbs_g"],
                            r["fat_g"],
                            r["meal_type"],
                            json.dumps(r["dietary_tags"]),
                            json.dumps(r["allergens"]),
                            json.dumps(r["ingredients"]),
                            json.dumps(r["steps"]),
                            r["image_path"],
                            r["image_source"],
                            stamp,
                        ),
                    )
                conn.commit()
                db.run_storage_janitor(conn, aggressive=False)
                self._send_json(
                    HTTPStatus.OK,
                    {
                        "added_count": len(found),
                        "recipes": db.list_recipes(conn),
                        "storage": db.get_storage_metrics(conn),
                    },
                )
            return

        m_save = re.match(r"^/api/recipes/([^/]+)/toggle-save$", path)
        if m_save:
            rec_id = unquote(m_save.group(1))
            with DB_LOCK:
                conn = get_db()
                updated = db.toggle_recipe_saved(conn, rec_id)
                if not updated:
                    self._send_json(HTTPStatus.NOT_FOUND, {"error": "recipe_not_found"})
                    return
                self._send_json(
                    HTTPStatus.OK,
                    {
                        "recipe": updated,
                        "recipes": db.list_recipes(conn),
                        "storage": db.get_storage_metrics(conn),
                    },
                )
            return

        m_photo = re.match(r"^/api/recipes/([^/]+)/photo$", path)
        if m_photo:
            rec_id = unquote(m_photo.group(1))
            b64 = str(body.get("image_base64", "")).strip()
            if not b64:
                self._send_json(HTTPStatus.BAD_REQUEST, {"error": "image_required"})
                return
            if "," in b64 and b64.startswith("data:"):
                b64 = b64.split(",", 1)[1]
            try:
                raw_bytes = base64.b64decode(b64)
            except Exception:
                self._send_json(HTTPStatus.BAD_REQUEST, {"error": "invalid_base64"})
                return

            with DB_LOCK:
                conn = get_db()
                row = conn.execute("SELECT id, image_path, saved_at FROM recipes WHERE id = ?", (rec_id,)).fetchone()
                if not row:
                    self._send_json(HTTPStatus.NOT_FOUND, {"error": "recipe_not_found"})
                    return

                fname = f"{rec_id}_cooked_{int(time.time())}.jpg"
                dest = db.SAVED_MEDIA_DIR / fname
                if not save_compressed_image_bytes(raw_bytes, dest):
                    self._send_json(HTTPStatus.BAD_REQUEST, {"error": "image_processing_failed"})
                    return

                old_path = row["image_path"]
                new_rel = f"saved/{fname}"
                if old_path and old_path != new_rel:
                    old_file = db.DATA_DIR / "media" / old_path
                    if old_file.exists():
                        old_file.unlink(missing_ok=True)

                saved_at = row["saved_at"] or db.now_iso()
                conn.execute(
                    "UPDATE recipes SET image_path = ?, image_source = 'custom_photo', is_saved = 1, saved_at = ? WHERE id = ?",
                    (new_rel, saved_at, rec_id),
                )
                conn.commit()
                self._send_json(
                    HTTPStatus.OK,
                    {
                        "recipes": db.list_recipes(conn),
                        "storage": db.get_storage_metrics(conn),
                    },
                )
            return

        if path == "/api/storage/sweep":
            with DB_LOCK:
                conn = get_db()
                sweep = db.run_storage_janitor(conn, aggressive=True)
                self._send_json(
                    HTTPStatus.OK,
                    {
                        "sweep": sweep,
                        "recipes": db.list_recipes(conn),
                        "storage": db.get_storage_metrics(conn),
                    },
                )
            return

        if path == "/api/settings":
            with DB_LOCK:
                conn = get_db()
                if body.get("clear_api_key"):
                    db.set_setting(conn, "gemini_api_key", "")
                elif "gemini_api_key" in body and str(body["gemini_api_key"]).strip():
                    db.set_setting(conn, "gemini_api_key", str(body["gemini_api_key"]).strip())
                if body.get("weight_unit") in {"lbs", "kg"}:
                    db.set_setting(conn, "weight_unit", str(body["weight_unit"]))
                if "cache_ttl_days" in body:
                    ttl = max(1, min(90, int(body["cache_ttl_days"])))
                    db.set_setting(conn, "cache_ttl_days", str(ttl))
                if "cache_max_mb" in body:
                    cap = max(5, min(250, int(body["cache_max_mb"])))
                    db.set_setting(conn, "cache_max_mb", str(cap))
                self._send_json(HTTPStatus.OK, {"storage": db.get_storage_metrics(conn)})
            return

        self._send_json(HTTPStatus.NOT_FOUND, {"error": "unknown_route"})


def main() -> None:
    parser = argparse.ArgumentParser(description="Parchment & Ink Local Prototype Server")
    parser.add_argument("--port", type=int, default=8420)
    args = parser.parse_args()

    with DB_LOCK:
        get_db()

    server = ThreadingHTTPServer(("127.0.0.1", args.port), LedgerHandler)
    print(f"Parchment & Ink prototype listening on http://127.0.0.1:{args.port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
