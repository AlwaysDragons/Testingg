"""initial schema

Revision ID: 0001_initial
Revises:
Create Date: 2026-10-07 00:00:00.000000
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision: str = "0001_initial"
down_revision: Union[str, None] = None
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "product_catalog",
        sa.Column("sku", sa.Text(), nullable=False),
        sa.Column("display_name", sa.Text(), nullable=False),
        sa.Column("category", sa.Text(), nullable=False),
        sa.Column("variant_group", sa.Text()),
        sa.Column("sizes", postgresql.ARRAY(sa.Text())),
        sa.Column("stocking_mode", sa.Text(), server_default="dropship"),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now()),
        sa.PrimaryKeyConstraint("sku"),
    )

    op.create_table(
        "product_sources",
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("sku", sa.Text()),
        sa.Column("source", sa.Text(), nullable=False),
        sa.Column("product_url", sa.Text(), nullable=False),
        sa.Column("seller_id", sa.Text()),
        sa.Column("variant_sku", sa.Text()),
        sa.Column("color_option", sa.Text()),
        sa.Column("size_option", sa.Text()),
        sa.Column("expected_price_usd", sa.Numeric(10, 2)),
        sa.Column("max_price_usd", sa.Numeric(10, 2)),
        sa.Column("avg_ship_days", sa.Integer()),
        sa.Column("quality_tier", sa.Text()),
        sa.Column("priority", sa.Integer(), server_default="100"),
        sa.Column("status", sa.Text(), server_default="active"),
        sa.Column("last_verified", sa.DateTime(timezone=True)),
        sa.ForeignKeyConstraint(["sku"], ["product_catalog.sku"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint(
            "sku", "source", "product_url", name="uq_product_sources_sku_source_url"
        ),
    )

    op.create_table(
        "dhgate_sellers",
        sa.Column("seller_id", sa.Text(), nullable=False),
        sa.Column("store_name", sa.Text()),
        sa.Column("store_url", sa.Text()),
        sa.Column("rating", sa.Numeric(5, 2)),
        sa.Column("transaction_count", sa.Integer()),
        sa.Column("years_active", sa.Integer()),
        sa.Column("has_us_warehouse", sa.Boolean(), server_default=sa.false()),
        sa.Column("accepts_dropship", sa.Boolean(), server_default=sa.false()),
        sa.Column("response_rate", sa.Numeric(5, 2)),
        sa.Column("score", sa.Integer()),
        sa.Column("contact_whatsapp", sa.Text()),
        sa.Column("off_platform", sa.Boolean(), server_default=sa.false()),
        sa.Column("last_verified", sa.DateTime(timezone=True)),
        sa.Column("notes", sa.Text()),
        sa.PrimaryKeyConstraint("seller_id"),
    )

    op.create_table(
        "prestocked_inventory",
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("sku", sa.Text()),
        sa.Column("size", sa.Text(), nullable=False),
        sa.Column("reshipper", sa.Text(), nullable=False),
        sa.Column("reshipper_item_id", sa.Text()),
        sa.Column("qty_available", sa.Integer(), server_default="0"),
        sa.Column("unit_cost_landed_usd", sa.Numeric(10, 2)),
        sa.Column("received_at", sa.DateTime(timezone=True)),
        sa.Column("last_sold", sa.DateTime(timezone=True)),
        sa.ForeignKeyConstraint(["sku"], ["product_catalog.sku"]),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("sku", "size", "reshipper", name="uq_prestocked_sku_size_reshipper"),
    )

    op.create_table(
        "posting_accounts",
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("platform", sa.Text(), nullable=False),
        sa.Column("handle", sa.Text(), nullable=False),
        sa.Column("email", sa.Text()),
        sa.Column("phone", sa.Text()),
        sa.Column("session_file", sa.Text(), nullable=False),
        sa.Column("proxy_slot", sa.Text()),
        sa.Column("status", sa.Text(), server_default="warming"),
        sa.Column("warming_started_at", sa.DateTime(timezone=True)),
        sa.Column("activated_at", sa.DateTime(timezone=True)),
        sa.Column("listings_today", sa.Integer(), server_default="0"),
        sa.Column("daily_limit", sa.Integer(), server_default="5"),
        sa.Column("last_posted", sa.DateTime(timezone=True)),
        sa.Column("cooldown_until", sa.DateTime(timezone=True)),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("platform", "handle", name="uq_posting_accounts_platform_handle"),
    )

    op.create_table(
        "our_listings",
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("sku", sa.Text()),
        sa.Column("platform", sa.Text(), nullable=False),
        sa.Column("platform_listing_id", sa.Text()),
        sa.Column("posting_account_id", sa.Integer()),
        sa.Column("url", sa.Text()),
        sa.Column("price_usd", sa.Numeric(10, 2)),
        sa.Column("original_price_usd", sa.Numeric(10, 2)),
        sa.Column("status", sa.Text()),
        sa.Column("photo_set", postgresql.ARRAY(sa.Text())),
        sa.Column("title", sa.Text()),
        sa.Column("description", sa.Text()),
        sa.Column("posted_at", sa.DateTime(timezone=True)),
        sa.Column("sold_at", sa.DateTime(timezone=True)),
        sa.Column("sold_price_usd", sa.Numeric(10, 2)),
        sa.Column("last_repriced_at", sa.DateTime(timezone=True)),
        sa.ForeignKeyConstraint(["sku"], ["product_catalog.sku"]),
        sa.ForeignKeyConstraint(["posting_account_id"], ["posting_accounts.id"]),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("idx_our_listings_status", "our_listings", ["status", "platform"])

    op.create_table(
        "sales",
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("our_listing_id", sa.Integer()),
        sa.Column("platform", sa.Text(), nullable=False),
        sa.Column("platform_sale_id", sa.Text()),
        sa.Column("buyer_handle", sa.Text()),
        sa.Column("buyer_address", postgresql.JSONB()),
        sa.Column("sale_price_usd", sa.Numeric(10, 2)),
        sa.Column("platform_fee_usd", sa.Numeric(10, 2)),
        sa.Column("net_received_usd", sa.Numeric(10, 2)),
        sa.Column("sold_at", sa.DateTime(timezone=True)),
        sa.Column("detected_at", sa.DateTime(timezone=True), server_default=sa.func.now()),
        sa.Column("review_requested_at", sa.DateTime(timezone=True)),
        sa.Column("review_received", sa.Boolean(), server_default=sa.false()),
        sa.Column("review_stars", sa.Integer()),
        sa.ForeignKeyConstraint(["our_listing_id"], ["our_listings.id"]),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("platform_sale_id"),
    )

    op.create_table(
        "supplier_orders",
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("sale_id", sa.Integer()),
        sa.Column("sku", sa.Text()),
        sa.Column("source", sa.Text()),
        sa.Column("supplier_order_ref", sa.Text()),
        sa.Column("status", sa.Text(), server_default="queued"),
        sa.Column("cost_usd", sa.Numeric(10, 2)),
        sa.Column("tracking_number", sa.Text()),
        sa.Column("tracking_carrier", sa.Text()),
        sa.Column("tracking_pushed", sa.Boolean(), server_default=sa.false()),
        sa.Column("error_log", sa.Text()),
        sa.Column("attempts", sa.Integer(), server_default="0"),
        sa.Column("placed_at", sa.DateTime(timezone=True)),
        sa.Column("shipped_at", sa.DateTime(timezone=True)),
        sa.Column("delivered_at", sa.DateTime(timezone=True)),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now()),
        sa.ForeignKeyConstraint(["sale_id"], ["sales.id"]),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("idx_supplier_orders_status", "supplier_orders", ["status"])

    op.create_table(
        "market_listings",
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("platform", sa.Text(), nullable=False),
        sa.Column("platform_listing_id", sa.Text(), nullable=False),
        sa.Column("matched_sku", sa.Text()),
        sa.Column("title", sa.Text()),
        sa.Column("price_usd", sa.Numeric(10, 2)),
        sa.Column("seller_handle", sa.Text()),
        sa.Column("size", sa.Text()),
        sa.Column("category", sa.Text()),
        sa.Column("sold", sa.Boolean(), server_default=sa.false()),
        sa.Column("posted_at", sa.DateTime(timezone=True)),
        sa.Column("sold_at", sa.DateTime(timezone=True)),
        sa.Column("url", sa.Text()),
        sa.Column("image_url", sa.Text()),
        sa.Column("scraped_at", sa.DateTime(timezone=True), server_default=sa.func.now()),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint(
            "platform", "platform_listing_id", name="uq_market_listing_platform_id"
        ),
    )

    op.create_table(
        "opportunities",
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("sku", sa.Text()),
        sa.Column("scored_at", sa.DateTime(timezone=True), server_default=sa.func.now()),
        sa.Column("market_price_median", sa.Numeric(10, 2)),
        sa.Column("supplier_cost_usd", sa.Numeric(10, 2)),
        sa.Column("margin_usd", sa.Numeric(10, 2)),
        sa.Column("velocity_score", sa.Numeric(5, 2)),
        sa.Column("saturation_count", sa.Integer()),
        sa.Column("composite_score", sa.Numeric(8, 2)),
        sa.Column("recommended_action", sa.Text()),
        sa.ForeignKeyConstraint(["sku"], ["product_catalog.sku"]),
        sa.PrimaryKeyConstraint("id"),
    )

    op.create_table(
        "competitor_sellers",
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("platform", sa.Text(), nullable=False),
        sa.Column("seller_handle", sa.Text(), nullable=False),
        sa.Column("categories", postgresql.ARRAY(sa.Text())),
        sa.Column("monitored", sa.Boolean(), server_default=sa.true()),
        sa.Column("last_scanned", sa.DateTime(timezone=True)),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("platform", "seller_handle", name="uq_competitor_platform_handle"),
    )

    op.create_table(
        "competitor_listings",
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("competitor_id", sa.Integer()),
        sa.Column("platform_listing_id", sa.Text(), nullable=False),
        sa.Column("title", sa.Text()),
        sa.Column("price_usd", sa.Numeric(10, 2)),
        sa.Column("matched_sku", sa.Text()),
        sa.Column("first_seen", sa.DateTime(timezone=True), server_default=sa.func.now()),
        sa.Column("last_seen", sa.DateTime(timezone=True), server_default=sa.func.now()),
        sa.Column("sold", sa.Boolean(), server_default=sa.false()),
        sa.ForeignKeyConstraint(["competitor_id"], ["competitor_sellers.id"]),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("competitor_id", "platform_listing_id", name="uq_comp_listing_id"),
    )

    op.create_table(
        "dm_threads",
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("platform", sa.Text(), nullable=False),
        sa.Column("posting_account_id", sa.Integer()),
        sa.Column("buyer_handle", sa.Text()),
        sa.Column("related_listing_id", sa.Integer()),
        sa.Column("last_message_at", sa.DateTime(timezone=True)),
        sa.Column("last_responded_at", sa.DateTime(timezone=True)),
        sa.Column("needs_human_review", sa.Boolean(), server_default=sa.false()),
        sa.Column("review_reason", sa.Text()),
        sa.ForeignKeyConstraint(["posting_account_id"], ["posting_accounts.id"]),
        sa.ForeignKeyConstraint(["related_listing_id"], ["our_listings.id"]),
        sa.PrimaryKeyConstraint("id"),
    )

    op.create_table(
        "dm_messages",
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("thread_id", sa.Integer()),
        sa.Column("direction", sa.Text()),
        sa.Column("body", sa.Text()),
        sa.Column("classified_intent", sa.Text()),
        sa.Column("sent_at", sa.DateTime(timezone=True), server_default=sa.func.now()),
        sa.ForeignKeyConstraint(["thread_id"], ["dm_threads.id"]),
        sa.PrimaryKeyConstraint("id"),
    )

    op.create_table(
        "pnl_daily",
        sa.Column("date", sa.Date(), nullable=False),
        sa.Column("sales_count", sa.Integer()),
        sa.Column("gross_sales_usd", sa.Numeric(10, 2)),
        sa.Column("platform_fees_usd", sa.Numeric(10, 2)),
        sa.Column("supplier_costs_usd", sa.Numeric(10, 2)),
        sa.Column("shipping_costs_usd", sa.Numeric(10, 2)),
        sa.Column("reshipper_fees_usd", sa.Numeric(10, 2)),
        sa.Column("chargebacks_usd", sa.Numeric(10, 2)),
        sa.Column("net_profit_usd", sa.Numeric(10, 2)),
        sa.Column("computed_at", sa.DateTime(timezone=True), server_default=sa.func.now()),
        sa.PrimaryKeyConstraint("date"),
    )

    op.create_table(
        "pnl_sku_rollup",
        sa.Column("sku", sa.Text(), nullable=False),
        sa.Column("period_start", sa.Date(), nullable=False),
        sa.Column("period_end", sa.Date(), nullable=False),
        sa.Column("sales_count", sa.Integer()),
        sa.Column("gross_usd", sa.Numeric(10, 2)),
        sa.Column("cost_usd", sa.Numeric(10, 2)),
        sa.Column("fees_usd", sa.Numeric(10, 2)),
        sa.Column("net_usd", sa.Numeric(10, 2)),
        sa.Column("avg_margin_pct", sa.Numeric(5, 2)),
        sa.Column("recommendation", sa.Text()),
        sa.PrimaryKeyConstraint("sku", "period_start", "period_end"),
    )

    op.create_table(
        "disputes",
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("sale_id", sa.Integer()),
        sa.Column("platform", sa.Text()),
        sa.Column("dispute_ref", sa.Text()),
        sa.Column("reason", sa.Text()),
        sa.Column("status", sa.Text()),
        sa.Column("opened_at", sa.DateTime(timezone=True)),
        sa.Column("evidence_packet_path", sa.Text()),
        sa.Column("resolved_at", sa.DateTime(timezone=True)),
        sa.Column("outcome", sa.Text()),
        sa.ForeignKeyConstraint(["sale_id"], ["sales.id"]),
        sa.PrimaryKeyConstraint("id"),
    )

    op.create_table(
        "scrape_runs",
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("platform", sa.Text()),
        sa.Column("query", sa.Text()),
        sa.Column("listings_found", sa.Integer()),
        sa.Column("errors", sa.Integer()),
        sa.Column("duration_sec", sa.Integer()),
        sa.Column("ran_at", sa.DateTime(timezone=True), server_default=sa.func.now()),
        sa.PrimaryKeyConstraint("id"),
    )

    op.create_table(
        "system_events",
        sa.Column("id", sa.BigInteger(), autoincrement=True, nullable=False),
        sa.Column("level", sa.String(16)),
        sa.Column("component", sa.Text()),
        sa.Column("message", sa.Text()),
        sa.Column("payload", postgresql.JSONB()),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now()),
        sa.PrimaryKeyConstraint("id"),
    )


def downgrade() -> None:
    for t in [
        "system_events",
        "scrape_runs",
        "disputes",
        "pnl_sku_rollup",
        "pnl_daily",
        "dm_messages",
        "dm_threads",
        "competitor_listings",
        "competitor_sellers",
        "opportunities",
        "market_listings",
        "supplier_orders",
        "sales",
        "our_listings",
        "posting_accounts",
        "prestocked_inventory",
        "dhgate_sellers",
        "product_sources",
        "product_catalog",
    ]:
        op.drop_table(t)
