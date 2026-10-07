"""Photo normalization pipeline.

Takes raw supplier photos, applies anti-duplicate transformations so the same
SKU looks different across accounts/platforms, picks 4-6 for a listing,
composites one hero onto a believable background.

Rotations: ±2°
Color balance: ±3 per channel
Micro-blur then sharpen
Edge crop: 3-5%
JPEG re-encode: quality 82-92

Writes to data/photos/processed/<sku>/<salt>/{01..06}.jpg.
Backgrounds library at data/photos/backgrounds/{wood,carpet,hanger,...}.jpg.
"""
from __future__ import annotations

import hashlib
import random
from pathlib import Path

from loguru import logger
from PIL import Image, ImageEnhance, ImageFilter, ImageOps


def _rng(sku: str, salt: str, idx: int) -> random.Random:
    h = hashlib.sha1(f"{sku}:{salt}:{idx}".encode()).digest()
    return random.Random(int.from_bytes(h[:8], "big"))


def _normalize_one(src_path: Path, dst_path: Path, rng: random.Random) -> None:
    img = Image.open(src_path).convert("RGB")

    angle = rng.uniform(-2.0, 2.0)
    img = img.rotate(angle, resample=Image.BICUBIC, expand=False)

    crop_pct = rng.uniform(0.03, 0.05)
    w, h = img.size
    cx = int(w * crop_pct)
    cy = int(h * crop_pct)
    img = img.crop((cx, cy, w - cx, h - cy))

    r = ImageEnhance.Color(img).enhance(1.0 + rng.uniform(-0.03, 0.03))
    r = ImageEnhance.Brightness(r).enhance(1.0 + rng.uniform(-0.03, 0.03))
    r = ImageEnhance.Contrast(r).enhance(1.0 + rng.uniform(-0.03, 0.03))

    r = r.filter(ImageFilter.GaussianBlur(radius=0.4))
    r = r.filter(ImageFilter.UnsharpMask(radius=1.2, percent=120, threshold=2))

    dst_path.parent.mkdir(parents=True, exist_ok=True)
    r.save(dst_path, "JPEG", quality=rng.randint(82, 92), optimize=True)


def _composite_hero(hero: Path, bg: Path, dst: Path) -> None:
    bg_img = Image.open(bg).convert("RGB")
    hero_img = Image.open(hero).convert("RGBA")
    # Scale hero to ~65% of background width, center horizontally, lower third vertically
    bw, bh = bg_img.size
    scale = (bw * 0.65) / hero_img.width
    new_size = (int(hero_img.width * scale), int(hero_img.height * scale))
    hero_img = hero_img.resize(new_size, Image.LANCZOS)
    pos = ((bw - new_size[0]) // 2, int(bh * 0.6) - new_size[1] // 2)
    bg_img.paste(hero_img, pos, hero_img if hero_img.mode == "RGBA" else None)
    dst.parent.mkdir(parents=True, exist_ok=True)
    bg_img.save(dst, "JPEG", quality=90)


def build_photo_set(
    sku: str,
    raw_dir: Path | str,
    out_dir: Path | str,
    salt: str,
    *,
    count: int = 5,
    backgrounds_dir: Path | str | None = None,
) -> list[str]:
    raw_dir = Path(raw_dir)
    out_dir = Path(out_dir) / sku / salt
    out_dir.mkdir(parents=True, exist_ok=True)

    raw = sorted(p for p in raw_dir.iterdir() if p.suffix.lower() in {".jpg", ".jpeg", ".png"})
    if not raw:
        logger.warning("no raw photos for {}", sku)
        return []

    rng = random.Random(hashlib.sha1(f"{sku}:{salt}:pick".encode()).digest())
    picks = rng.sample(raw, min(count, len(raw)))
    paths: list[str] = []
    for i, src in enumerate(picks, 1):
        dst = out_dir / f"{i:02d}.jpg"
        _normalize_one(src, dst, _rng(sku, salt, i))
        paths.append(str(dst))

    if backgrounds_dir and paths:
        bg_dir = Path(backgrounds_dir)
        bgs = sorted(p for p in bg_dir.iterdir() if p.suffix.lower() in {".jpg", ".jpeg", ".png"})
        if bgs:
            bg = rng.choice(bgs)
            hero_dst = out_dir / "00_hero.jpg"
            _composite_hero(Path(paths[0]), bg, hero_dst)
            paths.insert(0, str(hero_dst))

    logger.info("photo set for {}: {} images", sku, len(paths))
    return paths
