"""Gemini 4 Hydrogen grounded recipe discovery, URL verification, and sips image compression."""

from __future__ import annotations

import base64
import html
import json
import re
import socket
import ssl
import subprocess
import tempfile
import urllib.error
import urllib.request
import uuid
from pathlib import Path
from typing import Any
from urllib.parse import urljoin, urlparse

INTERACTIONS_URL = "https://generativelanguage.googleapis.com/v1beta/interactions"
API_REVISION = "2026-05-20"
BROWSER_UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"
)


class GeminiDiscoveryError(Exception):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


def _ssl_context() -> ssl.SSLContext:
    return ssl.create_default_context()


def save_compressed_image_bytes(raw_bytes: bytes, dest_jpg_path: Path) -> bool:
    """Compress arbitrary image bytes (PNG/JPEG/WebP/HEIC) to <=480px JPEG via macOS sips."""
    if not raw_bytes or len(raw_bytes) < 128:
        return False
    dest_jpg_path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(suffix=".img", delete=False) as tmp:
        tmp.write(raw_bytes)
        tmp_path = Path(tmp.name)

    try:
        res = subprocess.run(
            [
                "/usr/bin/sips",
                "-Z",
                "480",
                "-s",
                "format",
                "jpeg",
                "-s",
                "formatOptions",
                "75",
                str(tmp_path),
                "--out",
                str(dest_jpg_path),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        return res.returncode == 0 and dest_jpg_path.exists() and dest_jpg_path.stat().st_size > 0
    finally:
        if tmp_path.exists():
            tmp_path.unlink(missing_ok=True)


def _post_interaction(api_key: str, payload: dict[str, Any], timeout: int = 120) -> dict[str, Any]:
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        INTERACTIONS_URL,
        data=body,
        method="POST",
        headers={
            "x-goog-api-key": api_key,
            "Content-Type": "application/json",
            "Api-Revision": API_REVISION,
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=_ssl_context()) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        err_text = exc.read().decode("utf-8", errors="replace")
        raise GeminiDiscoveryError(
            "api_http_error",
            f"Gemini API HTTP {exc.code}: {err_text[:280]}",
        ) from exc
    except (TimeoutError, socket.timeout) as exc:
        raise GeminiDiscoveryError(
            "timeout",
            "Gemini API request timed out while crawling recipes. Please try again.",
        ) from exc
    except urllib.error.URLError as exc:
        raise GeminiDiscoveryError(
            "network_error",
            f"Network error contacting Gemini API: {exc.reason}",
        ) from exc


def _extract_model_text(interaction_resp: dict[str, Any]) -> str:
    texts: list[str] = []
    for step in interaction_resp.get("steps", []) or []:
        if step.get("type") == "model_output":
            for item in step.get("content", []) or []:
                if item.get("type") == "text" and item.get("text"):
                    texts.append(item["text"])
    if texts:
        return "\n".join(texts).strip()
    if interaction_resp.get("output_text"):
        return str(interaction_resp["output_text"]).strip()
    return ""


def _extract_model_image_bytes(interaction_resp: dict[str, Any]) -> bytes | None:
    for step in reversed(interaction_resp.get("steps", []) or []):
        if step.get("type") == "model_output":
            for item in step.get("content", []) or []:
                if item.get("type") == "image" and item.get("data"):
                    try:
                        return base64.b64decode(item["data"])
                    except Exception:
                        return None
    out_img = interaction_resp.get("output_image")
    if isinstance(out_img, dict) and out_img.get("data"):
        try:
            return base64.b64decode(out_img["data"])
        except Exception:
            return None
    return None


def _extract_og_or_recipe_image(page_html: str, base_url: str) -> str | None:
    patterns = [
        r'<meta[^>]+(?:property|name)=["\']og:image["\'][^>]+content=["\']([^"\']+)["\']',
        r'<meta[^>]+content=["\']([^"\']+)["\'][^>]+(?:property|name)=["\']og:image["\']',
        r'<meta[^>]+(?:property|name)=["\']twitter:image(?::src)?["\'][^>]+content=["\']([^"\']+)["\']',
        r'<meta[^>]+content=["\']([^"\']+)["\'][^>]+(?:property|name)=["\']twitter:image(?::src)?["\']',
    ]
    for pat in patterns:
        m = re.search(pat, page_html, flags=re.IGNORECASE)
        if m:
            raw = html.unescape(m.group(1).strip())
            if raw and not raw.startswith("data:"):
                return urljoin(base_url, raw)

    # Check JSON-LD Recipe blocks
    for block in re.findall(
        r'<script[^>]+type=["\']application/ld\+json["\'][^>]*>(.*?)</script>',
        page_html,
        flags=re.IGNORECASE | re.DOTALL,
    ):
        try:
            data = json.loads(block.strip())
        except Exception:
            continue
        items = data if isinstance(data, list) else [data]
        expanded: list[Any] = []
        for it in items:
            if isinstance(it, dict) and isinstance(it.get("@graph"), list):
                expanded.extend(it["@graph"])
            else:
                expanded.append(it)
        for node in expanded:
            if not isinstance(node, dict):
                continue
            node_type = str(node.get("@type", ""))
            if "Recipe" in node_type:
                img = node.get("image")
                if isinstance(img, str) and img.startswith("http"):
                    return img
                if isinstance(img, list) and img:
                    first = img[0]
                    if isinstance(first, str):
                        return urljoin(base_url, first)
                    if isinstance(first, dict) and first.get("url"):
                        return urljoin(base_url, str(first["url"]))
                if isinstance(img, dict) and img.get("url"):
                    return urljoin(base_url, str(img["url"]))
    return None


def _verify_url_and_fetch_image(source_url: str) -> tuple[bool, str, bytes | None]:
    """Perform HTTP GET (timeout=6) to verify real page reachability and extract page photo."""
    parsed = urlparse(source_url)
    if parsed.scheme not in ("http", "https") or not parsed.netloc:
        return False, source_url, None

    req = urllib.request.Request(
        source_url,
        method="GET",
        headers={
            "User-Agent": BROWSER_UA,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=6, context=_ssl_context()) as resp:
            status = getattr(resp, "status", 200)
            if status < 200 or status >= 400:
                return False, source_url, None
            final_url = resp.geturl() or source_url
            raw_html = resp.read(350_000).decode("utf-8", errors="ignore")
    except urllib.error.HTTPError as exc:
        # Food blogs often block bot user-agents with 401/403/429 even when live; reject 404/410/5xx
        if exc.code in (401, 403, 429):
            return True, exc.geturl() or source_url, None
        return False, source_url, None
    except Exception:
        return False, source_url, None

    img_url = _extract_og_or_recipe_image(raw_html, final_url)
    if not img_url:
        return True, final_url, None

    img_req = urllib.request.Request(
        img_url,
        method="GET",
        headers={"User-Agent": BROWSER_UA, "Referer": final_url},
    )
    try:
        with urllib.request.urlopen(img_req, timeout=8, context=_ssl_context()) as img_resp:
            if getattr(img_resp, "status", 200) >= 400:
                return True, final_url, None
            ctype = (img_resp.headers.get("Content-Type") or "").lower()
            if ctype and "image" not in ctype and "octet-stream" not in ctype:
                return True, final_url, None
            img_bytes = img_resp.read(8_000_000)
            return True, final_url, img_bytes
    except Exception:
        return True, final_url, None


def _generate_fallback_thumbnail(api_key: str, title: str) -> bytes | None:
    payload = {
        "model": "gemini-nano-banana-2.1",
        "input": (
            f"Overhead editorial food photography of {title}, plated cleanly on matte handmade stoneware "
            "with soft natural window daylight, minimalist styling, no text, no watermarks."
        ),
        "response_format": {
            "type": "image",
            "mime_type": "image/jpeg",
            "aspect_ratio": "1:1",
            "image_size": "1K",
        },
    }
    try:
        resp = _post_interaction(api_key, payload, timeout=45)
        return _extract_model_image_bytes(resp)
    except Exception:
        return None


def discover_recipes_via_hydrogen(
    api_key: str,
    query: str,
    dietary_filters: list[str],
    cache_media_dir: Path,
    meal_type: str = "",
) -> list[dict[str, Any]]:
    if not api_key.strip():
        raise GeminiDiscoveryError(
            "missing_api_key",
            "Add your Gemini API key in the Vault tab to crawl real recipes from the web.",
        )

    parts = [
        f"Use Google Search to find 7 real, well-rated web recipes matching: '{query}' (interpret casual phrasing, typos, or loose cravings naturally)."
    ]
    if meal_type and meal_type.lower() not in {"all", "all meals"}:
        parts.append(f"Meal category: {meal_type}.")
    if dietary_filters:
        parts.append(f"Dietary restrictions: {', '.join(dietary_filters)}.")
    parts.append(
        "Return live recipe URLs found in search results, concise ingredients and steps, per-serving macros, explicit food allergens (or [] if none), meal_type (Breakfast, Lunch, Dinner, or Snacks), and relevant dietary_tags."
    )
    prompt = " ".join(parts)

    schema = {
        "type": "object",
        "properties": {
            "recipes": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "title": {"type": "string"},
                        "source_url": {"type": "string"},
                        "prep_time": {"type": "string"},
                        "servings": {"type": "integer"},
                        "kcal": {"type": "integer"},
                        "protein_g": {"type": "integer"},
                        "carbs_g": {"type": "integer"},
                        "fat_g": {"type": "integer"},
                        "meal_type": {"type": "string", "enum": ["Breakfast", "Lunch", "Dinner", "Snacks"]},
                        "dietary_tags": {"type": "array", "items": {"type": "string"}},
                        "allergens": {"type": "array", "items": {"type": "string"}},
                        "ingredients": {"type": "array", "items": {"type": "string"}},
                        "steps": {"type": "array", "items": {"type": "string"}},
                    },
                    "required": [
                        "title",
                        "source_url",
                        "prep_time",
                        "servings",
                        "kcal",
                        "protein_g",
                        "carbs_g",
                        "fat_g",
                        "meal_type",
                        "dietary_tags",
                        "allergens",
                        "ingredients",
                        "steps",
                    ],
                },
            }
        },
        "required": ["recipes"],
    }

    payload = {
        "model": "gemini-4-hydrogen",
        "input": prompt,
        "tools": [{"type": "google_search"}],
        "generation_config": {
            "thinking_level": "low",
        },
        "response_format": {
            "type": "text",
            "mime_type": "application/json",
            "schema": schema,
        },
    }

    resp = _post_interaction(api_key.strip(), payload, timeout=120)
    raw_text = _extract_model_text(resp)
    if not raw_text:
        raise GeminiDiscoveryError("empty_response", "Gemini 4 Hydrogen returned an empty response.")

    cleaned = raw_text.strip()
    if cleaned.startswith("```"):
        cleaned = re.sub(r"^```(?:json)?\s*|\s*```$", "", cleaned, flags=re.DOTALL).strip()

    try:
        parsed = json.loads(cleaned)
    except json.JSONDecodeError as exc:
        raise GeminiDiscoveryError(
            "invalid_json",
            f"Could not parse structured recipe JSON from Gemini: {exc}",
        ) from exc

    raw_recipes = parsed.get("recipes", [])
    if not isinstance(raw_recipes, list) or not raw_recipes:
        raise GeminiDiscoveryError("no_recipes", "No recipes matched that search query.")

    verified_results: list[dict[str, Any]] = []
    valid_meals = {"Breakfast", "Lunch", "Dinner", "Snacks"}
    for item in raw_recipes[:10]:
        if len(verified_results) >= 5:
            break
        src_url = str(item.get("source_url", "")).strip()
        is_live, final_url, page_img_bytes = _verify_url_and_fetch_image(src_url)
        if not is_live:
            continue

        rec_id = f"rec_{uuid.uuid4().hex[:10]}"
        fname = f"{rec_id}.jpg"
        dest_jpg = cache_media_dir / fname
        image_path = None
        image_source = "placeholder"

        if page_img_bytes and save_compressed_image_bytes(page_img_bytes, dest_jpg):
            image_path = f"cache/{fname}"
            image_source = "source_og"
        else:
            gen_bytes = _generate_fallback_thumbnail(api_key.strip(), str(item.get("title", "Meal")))
            if gen_bytes and save_compressed_image_bytes(gen_bytes, dest_jpg):
                image_path = f"cache/{fname}"
                image_source = "generated"

        raw_meal = str(item.get("meal_type", "")).strip().title()
        chosen_meal = raw_meal if raw_meal in valid_meals else (meal_type if meal_type in valid_meals else "Dinner")
        domain = urlparse(final_url).netloc.replace("www.", "")
        verified_results.append(
            {
                "id": rec_id,
                "title": str(item.get("title", "Untitled Recipe")).strip(),
                "source_url": final_url,
                "source_domain": domain,
                "prep_time": str(item.get("prep_time", "25 min")).strip(),
                "servings": max(1, int(item.get("servings") or 2)),
                "kcal": max(0, int(item.get("kcal") or 0)),
                "protein_g": max(0, int(item.get("protein_g") or 0)),
                "carbs_g": max(0, int(item.get("carbs_g") or 0)),
                "fat_g": max(0, int(item.get("fat_g") or 0)),
                "meal_type": chosen_meal,
                "dietary_tags": [str(x).strip() for x in (item.get("dietary_tags") or []) if str(x).strip()],
                "allergens": [str(x).strip() for x in (item.get("allergens") or []) if str(x).strip()],
                "ingredients": [str(x).strip() for x in (item.get("ingredients") or []) if str(x).strip()],
                "steps": [str(x).strip() for x in (item.get("steps") or []) if str(x).strip()],
                "image_path": image_path,
                "image_source": image_source,
            }
        )

    if not verified_results:
        raise GeminiDiscoveryError(
            "verification_failed",
            "Found candidate links, but none returned an active reachable recipe page (HTTP 200). Try a broader dish query.",
        )

    return verified_results
