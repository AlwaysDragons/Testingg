"""Local dashboard — FastAPI + a single HTML page.

Everything is read-only JSON by default; action endpoints are POST and
protected by DASHBOARD_TOKEN (env). Live log stream is server-sent events
tailing /data/logs/app.log, which Loguru writes to in parallel to stderr.
"""
from __future__ import annotations

import asyncio
import datetime as dt
import os
from pathlib import Path
from typing import Any

from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse, StreamingResponse
from loguru import logger
from sqlalchemy import select, func, text

from src.config import settings
from src.db.models import (
    CompetitorListing,
    DmThread,
    MarketListing,
    Opportunity,
    OurListing,
    PnlDaily,
    PnlSkuRollup,
    PostingAccount,
    ProductCatalog,
    ProductSource,
    Sale,
    ScrapeRun,
    SupplierOrder,
)
from src.db.session import session_scope
from src.queue import QUEUES, get_queue, get_redis

LOG_FILE = Path("/data/logs/app.log")

app = FastAPI(title="dropship-mp dashboard", version="1.0")

HERE = Path(__file__).parent
INDEX_HTML = HERE / "index.html"


def _check_token(x_token: str | None) -> None:
    expected = os.environ.get("DASHBOARD_TOKEN", "")
    if not expected:
        return
    if x_token != expected:
        raise HTTPException(status_code=401, detail="bad token")


@app.get("/")
async def root() -> FileResponse:
    return FileResponse(INDEX_HTML)


@app.get("/api/health")
async def api_health() -> dict:
    db_ok = redis_ok = False
    db_detail = redis_detail = ""
    try:
        async with session_scope() as sess:
            await sess.execute(text("SELECT 1"))
        db_ok = True
    except Exception as exc:
        db_detail = str(exc)[:200]
    try:
        get_redis().ping()
        redis_ok = True
    except Exception as exc:
        redis_detail = str(exc)[:200]

    queue_depths = {}
    try:
        for name in QUEUES:
            queue_depths[name] = get_queue(name).count
    except Exception as exc:
        queue_depths = {"error": str(exc)}

    return {
        "env": settings.env,
        "db": {"ok": db_ok, "detail": db_detail},
        "redis": {"ok": redis_ok, "detail": redis_detail},
        "queues": queue_depths,
        "proxy_configured": bool(settings.proxy_host and settings.proxy_user),
    }


@app.get("/api/accounts")
async def api_accounts() -> list[dict]:
    async with session_scope() as sess:
        rows = (await sess.execute(select(PostingAccount))).scalars().all()
    return [
        {
            "id": a.id,
            "platform": a.platform,
            "handle": a.handle,
            "status": a.status,
            "listings_today": a.listings_today or 0,
            "daily_limit": a.daily_limit or 5,
            "warming_started_at": a.warming_started_at.isoformat() if a.warming_started_at else None,
            "activated_at": a.activated_at.isoformat() if a.activated_at else None,
            "last_posted": a.last_posted.isoformat() if a.last_posted else None,
            "cooldown_until": a.cooldown_until.isoformat() if a.cooldown_until else None,
        }
        for a in rows
    ]


@app.get("/api/opportunities")
async def api_opportunities(limit: int = 25) -> list[dict]:
    async with session_scope() as sess:
        rows = (
            await sess.execute(
                select(Opportunity).order_by(Opportunity.scored_at.desc()).limit(limit)
            )
        ).scalars().all()
    return [
        {
            "sku": o.sku,
            "scored_at": o.scored_at.isoformat() if o.scored_at else None,
            "market_price_median": float(o.market_price_median) if o.market_price_median else None,
            "supplier_cost_usd": float(o.supplier_cost_usd) if o.supplier_cost_usd else None,
            "margin_usd": float(o.margin_usd) if o.margin_usd else None,
            "velocity_score": float(o.velocity_score) if o.velocity_score else None,
            "saturation_count": o.saturation_count,
            "composite_score": float(o.composite_score) if o.composite_score else None,
            "recommended_action": o.recommended_action,
        }
        for o in rows
    ]


@app.get("/api/listings")
async def api_listings(limit: int = 50) -> list[dict]:
    async with session_scope() as sess:
        rows = (
            await sess.execute(
                select(OurListing).order_by(OurListing.posted_at.desc().nullslast()).limit(limit)
            )
        ).scalars().all()
    return [
        {
            "id": l.id,
            "sku": l.sku,
            "platform": l.platform,
            "platform_listing_id": l.platform_listing_id,
            "price_usd": float(l.price_usd) if l.price_usd else None,
            "status": l.status,
            "title": l.title,
            "url": l.url,
            "posted_at": l.posted_at.isoformat() if l.posted_at else None,
            "sold_at": l.sold_at.isoformat() if l.sold_at else None,
            "sold_price_usd": float(l.sold_price_usd) if l.sold_price_usd else None,
        }
        for l in rows
    ]


@app.get("/api/sales")
async def api_sales(limit: int = 50) -> list[dict]:
    async with session_scope() as sess:
        rows = (
            await sess.execute(
                select(Sale, SupplierOrder)
                .join(SupplierOrder, SupplierOrder.sale_id == Sale.id, isouter=True)
                .order_by(Sale.sold_at.desc().nullslast())
                .limit(limit)
            )
        ).all()
    return [
        {
            "sale_id": s.id,
            "platform": s.platform,
            "platform_sale_id": s.platform_sale_id,
            "buyer_handle": s.buyer_handle,
            "sale_price_usd": float(s.sale_price_usd) if s.sale_price_usd else None,
            "platform_fee_usd": float(s.platform_fee_usd) if s.platform_fee_usd else None,
            "sold_at": s.sold_at.isoformat() if s.sold_at else None,
            "has_address": bool(s.buyer_address),
            "review_requested_at": s.review_requested_at.isoformat() if s.review_requested_at else None,
            "supplier": {
                "source": o.source if o else None,
                "status": o.status if o else None,
                "supplier_order_ref": o.supplier_order_ref if o else None,
                "tracking_number": o.tracking_number if o else None,
                "tracking_pushed": o.tracking_pushed if o else None,
                "cost_usd": float(o.cost_usd) if o and o.cost_usd else None,
            } if o else None,
        }
        for s, o in rows
    ]


@app.get("/api/pnl")
async def api_pnl() -> dict:
    async with session_scope() as sess:
        daily = (
            await sess.execute(
                select(PnlDaily).order_by(PnlDaily.date.desc()).limit(14)
            )
        ).scalars().all()
        skus = (
            await sess.execute(
                select(PnlSkuRollup).order_by(PnlSkuRollup.net_usd.desc().nullslast()).limit(20)
            )
        ).scalars().all()
    return {
        "daily": [
            {
                "date": d.date.isoformat(),
                "sales_count": d.sales_count,
                "gross_sales_usd": float(d.gross_sales_usd) if d.gross_sales_usd else 0,
                "platform_fees_usd": float(d.platform_fees_usd) if d.platform_fees_usd else 0,
                "supplier_costs_usd": float(d.supplier_costs_usd) if d.supplier_costs_usd else 0,
                "net_profit_usd": float(d.net_profit_usd) if d.net_profit_usd else 0,
            }
            for d in daily
        ],
        "skus": [
            {
                "sku": s.sku,
                "sales_count": s.sales_count,
                "gross_usd": float(s.gross_usd) if s.gross_usd else 0,
                "cost_usd": float(s.cost_usd) if s.cost_usd else 0,
                "net_usd": float(s.net_usd) if s.net_usd else 0,
                "avg_margin_pct": float(s.avg_margin_pct) if s.avg_margin_pct else 0,
                "recommendation": s.recommendation,
            }
            for s in skus
        ],
    }


@app.get("/api/catalog")
async def api_catalog() -> list[dict]:
    async with session_scope() as sess:
        rows = (await sess.execute(select(ProductCatalog))).scalars().all()
        sources = (await sess.execute(select(ProductSource))).scalars().all()
    src_map: dict[str, list[dict]] = {}
    for s in sources:
        src_map.setdefault(s.sku, []).append(
            {
                "source": s.source,
                "product_url": s.product_url,
                "color": s.color_option,
                "size": s.size_option,
                "expected_price_usd": float(s.expected_price_usd) if s.expected_price_usd else None,
                "status": s.status,
            }
        )
    return [
        {
            "sku": p.sku,
            "display_name": p.display_name,
            "category": p.category,
            "variant_group": p.variant_group,
            "sizes": p.sizes,
            "stocking_mode": p.stocking_mode,
            "sources": src_map.get(p.sku, []),
        }
        for p in rows
    ]


@app.get("/api/scrape_runs")
async def api_scrape_runs(limit: int = 25) -> list[dict]:
    async with session_scope() as sess:
        rows = (
            await sess.execute(select(ScrapeRun).order_by(ScrapeRun.ran_at.desc()).limit(limit))
        ).scalars().all()
    return [
        {
            "platform": r.platform,
            "query": r.query,
            "listings_found": r.listings_found,
            "errors": r.errors,
            "duration_sec": r.duration_sec,
            "ran_at": r.ran_at.isoformat() if r.ran_at else None,
        }
        for r in rows
    ]


@app.get("/api/dm_threads")
async def api_dm_threads() -> list[dict]:
    async with session_scope() as sess:
        rows = (
            await sess.execute(
                select(DmThread).order_by(DmThread.last_message_at.desc().nullslast()).limit(50)
            )
        ).scalars().all()
    return [
        {
            "id": t.id,
            "platform": t.platform,
            "buyer_handle": t.buyer_handle,
            "needs_human_review": t.needs_human_review,
            "review_reason": t.review_reason,
            "last_message_at": t.last_message_at.isoformat() if t.last_message_at else None,
        }
        for t in rows
    ]


# ---------- actions (require token when DASHBOARD_TOKEN set) ----------

@app.post("/api/action/post")
async def action_post(req: Request, x_token: str | None = Header(default=None)) -> dict:
    _check_token(x_token)
    body = await req.json()
    sku = body.get("sku")
    platforms = body.get("platforms") or None
    if not sku:
        raise HTTPException(status_code=400, detail="sku required")
    job = get_queue("listing_posts").enqueue(
        "src.workers.listing_post.run", sku, platforms, job_timeout=900
    )
    return {"ok": True, "job_id": job.id, "sku": sku}


@app.post("/api/action/scrape")
async def action_scrape(x_token: str | None = Header(default=None)) -> dict:
    _check_token(x_token)
    job = get_queue("scraping").enqueue("src.workers.market_scrape.run", job_timeout=1800)
    return {"ok": True, "job_id": job.id}


@app.post("/api/action/pnl_rollup")
async def action_pnl_rollup(x_token: str | None = Header(default=None)) -> dict:
    _check_token(x_token)
    job = get_queue("pnl_rollup").enqueue("src.workers.pnl_rollup.run")
    return {"ok": True, "job_id": job.id}


@app.post("/api/action/dispute")
async def action_dispute(req: Request, x_token: str | None = Header(default=None)) -> dict:
    _check_token(x_token)
    body = await req.json()
    sale_id = body.get("sale_id")
    if not sale_id:
        raise HTTPException(status_code=400, detail="sale_id required")
    from src.disputes.evidence_packet import build_packet

    path = await build_packet(int(sale_id))
    if path is None:
        raise HTTPException(status_code=404, detail="sale not found")
    return {"ok": True, "pdf": str(path)}


@app.get("/api/dispute/{sale_id}.pdf")
async def dispute_pdf(sale_id: int) -> FileResponse:
    path = Path(f"/data/dispute_packets/{sale_id}.pdf")
    if not path.exists():
        raise HTTPException(status_code=404)
    return FileResponse(path, media_type="application/pdf")


# ---------- settings (edit .env from UI) ----------

def _resolve_env_path() -> Path:
    explicit = os.environ.get("DASHBOARD_ENV_PATH")
    if explicit:
        return Path(explicit).resolve()
    candidates = [Path("/app/.env"), Path.cwd() / ".env", Path(__file__).resolve().parents[2] / ".env"]
    for c in candidates:
        if c.exists():
            return c
    return candidates[0]


ENV_PATH = _resolve_env_path()

# Keys that are safe to expose + edit from the local dashboard. Anything not
# here is hidden to keep the surface small.
EDITABLE_KEYS = [
    "TELEGRAM_BOT_TOKEN",
    "TELEGRAM_CHAT_ID",
    "TELEGRAM_ADMIN_IDS",
    "SHIPITO_API_KEY",
    "SHIPITO_ACCOUNT_ID",
    "PROXY_PROVIDER",
    "PROXY_HOST",
    "PROXY_PORT",
    "PROXY_USER",
    "PROXY_PASS",
    "PROXY_SLOTS",
    "POLL_SOLD_INTERVAL_MINUTES",
    "SCRAPE_INTERVAL_HOURS",
    "TRACKING_POLL_INTERVAL_MINUTES",
    "REPRICE_INTERVAL_HOURS",
    "COMPETITOR_WATCH_INTERVAL_HOURS",
    "DM_POLL_INTERVAL_MINUTES",
    "REVIEW_SOLICIT_DELAY_DAYS",
    "DAILY_DIGEST_HOUR",
    "MAX_LISTINGS_PER_ACCOUNT_PER_DAY",
    "MAX_SIMULTANEOUS_BROWSERS",
    "WARMING_PERIOD_DAYS",
    "WARMING_ACTIONS_PER_DAY",
    "PRICE_BREACH_THRESHOLD_PCT",
    "REPRICE_FLOOR_MARGIN_PCT",
    "LOG_LEVEL",
]
# Mask these in GET responses — show only whether they're set.
MASKED_KEYS = {"TELEGRAM_BOT_TOKEN", "SHIPITO_API_KEY", "PROXY_USER", "PROXY_PASS"}


def _parse_env(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    if not path.exists():
        return out
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        k, _, v = line.partition("=")
        out[k.strip()] = v.strip()
    return out


def _write_env(path: Path, values: dict[str, str]) -> None:
    """Preserve comments + ordering; replace only matching keys. Append new ones at end."""
    existing_text = path.read_text() if path.exists() else ""
    lines = existing_text.splitlines() if existing_text else []
    seen: set[str] = set()
    new_lines: list[str] = []
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            new_lines.append(line)
            continue
        k = stripped.split("=", 1)[0].strip()
        if k in values:
            new_lines.append(f"{k}={values[k]}")
            seen.add(k)
        else:
            new_lines.append(line)
    for k, v in values.items():
        if k not in seen:
            new_lines.append(f"{k}={v}")
    path.write_text("\n".join(new_lines) + "\n")


@app.get("/api/settings")
async def api_settings(x_token: str | None = Header(default=None)) -> dict:
    _check_token(x_token)
    current = _parse_env(ENV_PATH)
    out: dict[str, dict] = {}
    for key in EDITABLE_KEYS:
        raw = current.get(key, "")
        is_set = bool(raw)
        if key in MASKED_KEYS:
            out[key] = {"set": is_set, "value": "••••••" if is_set else "", "masked": True}
        else:
            out[key] = {"set": is_set, "value": raw, "masked": False}
    out["_env_path"] = {"value": str(ENV_PATH), "exists": ENV_PATH.exists(), "masked": False, "set": True}
    return out


@app.post("/api/settings")
async def api_settings_write(req: Request, x_token: str | None = Header(default=None)) -> dict:
    _check_token(x_token)
    body = await req.json()
    if not isinstance(body, dict):
        raise HTTPException(status_code=400, detail="body must be an object")
    cleaned: dict[str, str] = {}
    for k, v in body.items():
        if k not in EDITABLE_KEYS:
            continue
        if v is None:
            continue
        # Allow blank through so user can clear a value, but skip the masked
        # placeholder so re-saves don't nuke a stored secret.
        s = str(v).strip()
        if k in MASKED_KEYS and s == "••••••":
            continue
        cleaned[k] = s
    _write_env(ENV_PATH, cleaned)
    logger.info("settings updated via dashboard: {} key(s)", len(cleaned))
    return {
        "ok": True,
        "written": sorted(cleaned.keys()),
        "note": "restart the stack for all services to pick up changes: docker compose restart",
    }


@app.post("/api/restart")
async def api_restart(x_token: str | None = Header(default=None)) -> dict:
    """Soft hint — tells the dashboard container to exit, docker's restart policy
    brings it back. For scheduler/worker/telegram the user runs `docker compose
    restart` from the host. We do NOT execute docker commands from inside the
    container (no socket mount by default)."""
    _check_token(x_token)
    return {
        "ok": True,
        "action": "please run: docker compose restart scheduler worker telegram dashboard",
    }


# ---------- live log stream (SSE) ----------

async def _tail_logs(request: Request):
    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    LOG_FILE.touch(exist_ok=True)
    f = LOG_FILE.open("r", encoding="utf-8", errors="replace")
    try:
        f.seek(0, 2)  # jump to end
        yield f'event: open\ndata: tailing {LOG_FILE}\n\n'
        while True:
            if await request.is_disconnected():
                return
            line = f.readline()
            if not line:
                await asyncio.sleep(0.4)
                continue
            payload = line.rstrip("\n").replace("\n", " ")
            yield f"data: {payload}\n\n"
    finally:
        f.close()


@app.get("/api/logs/stream")
async def logs_stream(request: Request) -> StreamingResponse:
    return StreamingResponse(_tail_logs(request), media_type="text/event-stream")


@app.get("/api/logs/tail")
async def logs_tail(lines: int = 200) -> JSONResponse:
    if not LOG_FILE.exists():
        return JSONResponse({"lines": []})
    with LOG_FILE.open("r", encoding="utf-8", errors="replace") as f:
        content = f.readlines()
    return JSONResponse({"lines": [ln.rstrip("\n") for ln in content[-lines:]]})
