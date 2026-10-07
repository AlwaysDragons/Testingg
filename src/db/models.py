from __future__ import annotations

import datetime as dt
from decimal import Decimal

from sqlalchemy import (
    ARRAY,
    JSON,
    BigInteger,
    Boolean,
    Date,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    Numeric,
    String,
    Text,
    UniqueConstraint,
    func,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship


class Base(DeclarativeBase):
    pass


class ProductCatalog(Base):
    __tablename__ = "product_catalog"
    sku: Mapped[str] = mapped_column(Text, primary_key=True)
    display_name: Mapped[str] = mapped_column(Text, nullable=False)
    category: Mapped[str] = mapped_column(Text, nullable=False)
    variant_group: Mapped[str | None] = mapped_column(Text)
    sizes: Mapped[list[str] | None] = mapped_column(ARRAY(Text))
    stocking_mode: Mapped[str] = mapped_column(Text, default="dropship")
    created_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )

    sources: Mapped[list[ProductSource]] = relationship(back_populates="product")


class ProductSource(Base):
    __tablename__ = "product_sources"
    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    sku: Mapped[str] = mapped_column(
        Text, ForeignKey("product_catalog.sku", ondelete="CASCADE")
    )
    source: Mapped[str] = mapped_column(Text, nullable=False)
    product_url: Mapped[str] = mapped_column(Text, nullable=False)
    seller_id: Mapped[str | None] = mapped_column(Text)
    variant_sku: Mapped[str | None] = mapped_column(Text)
    color_option: Mapped[str | None] = mapped_column(Text)
    size_option: Mapped[str | None] = mapped_column(Text)
    expected_price_usd: Mapped[Decimal | None] = mapped_column(Numeric(10, 2))
    max_price_usd: Mapped[Decimal | None] = mapped_column(Numeric(10, 2))
    avg_ship_days: Mapped[int | None] = mapped_column(Integer)
    quality_tier: Mapped[str | None] = mapped_column(Text)
    priority: Mapped[int] = mapped_column(Integer, default=100)
    status: Mapped[str] = mapped_column(Text, default="active")
    last_verified: Mapped[dt.datetime | None] = mapped_column(DateTime(timezone=True))

    product: Mapped[ProductCatalog] = relationship(back_populates="sources")

    __table_args__ = (
        UniqueConstraint("sku", "source", "product_url", name="uq_product_sources_sku_source_url"),
    )


class DhgateSeller(Base):
    __tablename__ = "dhgate_sellers"
    seller_id: Mapped[str] = mapped_column(Text, primary_key=True)
    store_name: Mapped[str | None] = mapped_column(Text)
    store_url: Mapped[str | None] = mapped_column(Text)
    rating: Mapped[Decimal | None] = mapped_column(Numeric(5, 2))
    transaction_count: Mapped[int | None] = mapped_column(Integer)
    years_active: Mapped[int | None] = mapped_column(Integer)
    has_us_warehouse: Mapped[bool] = mapped_column(Boolean, default=False)
    accepts_dropship: Mapped[bool] = mapped_column(Boolean, default=False)
    response_rate: Mapped[Decimal | None] = mapped_column(Numeric(5, 2))
    score: Mapped[int | None] = mapped_column(Integer)
    contact_whatsapp: Mapped[str | None] = mapped_column(Text)
    off_platform: Mapped[bool] = mapped_column(Boolean, default=False)
    last_verified: Mapped[dt.datetime | None] = mapped_column(DateTime(timezone=True))
    notes: Mapped[str | None] = mapped_column(Text)


class PrestockedInventory(Base):
    __tablename__ = "prestocked_inventory"
    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    sku: Mapped[str] = mapped_column(Text, ForeignKey("product_catalog.sku"))
    size: Mapped[str] = mapped_column(Text, nullable=False)
    reshipper: Mapped[str] = mapped_column(Text, nullable=False)
    reshipper_item_id: Mapped[str | None] = mapped_column(Text)
    qty_available: Mapped[int] = mapped_column(Integer, default=0)
    unit_cost_landed_usd: Mapped[Decimal | None] = mapped_column(Numeric(10, 2))
    received_at: Mapped[dt.datetime | None] = mapped_column(DateTime(timezone=True))
    last_sold: Mapped[dt.datetime | None] = mapped_column(DateTime(timezone=True))

    __table_args__ = (
        UniqueConstraint("sku", "size", "reshipper", name="uq_prestocked_sku_size_reshipper"),
    )


class PostingAccount(Base):
    __tablename__ = "posting_accounts"
    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    platform: Mapped[str] = mapped_column(Text, nullable=False)
    handle: Mapped[str] = mapped_column(Text, nullable=False)
    email: Mapped[str | None] = mapped_column(Text)
    phone: Mapped[str | None] = mapped_column(Text)
    session_file: Mapped[str] = mapped_column(Text, nullable=False)
    proxy_slot: Mapped[str | None] = mapped_column(Text)
    status: Mapped[str] = mapped_column(Text, default="warming")
    warming_started_at: Mapped[dt.datetime | None] = mapped_column(DateTime(timezone=True))
    activated_at: Mapped[dt.datetime | None] = mapped_column(DateTime(timezone=True))
    listings_today: Mapped[int] = mapped_column(Integer, default=0)
    daily_limit: Mapped[int] = mapped_column(Integer, default=5)
    last_posted: Mapped[dt.datetime | None] = mapped_column(DateTime(timezone=True))
    cooldown_until: Mapped[dt.datetime | None] = mapped_column(DateTime(timezone=True))

    __table_args__ = (
        UniqueConstraint("platform", "handle", name="uq_posting_accounts_platform_handle"),
    )


class OurListing(Base):
    __tablename__ = "our_listings"
    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    sku: Mapped[str | None] = mapped_column(Text, ForeignKey("product_catalog.sku"))
    platform: Mapped[str] = mapped_column(Text, nullable=False)
    platform_listing_id: Mapped[str | None] = mapped_column(Text)
    posting_account_id: Mapped[int | None] = mapped_column(
        Integer, ForeignKey("posting_accounts.id")
    )
    url: Mapped[str | None] = mapped_column(Text)
    price_usd: Mapped[Decimal | None] = mapped_column(Numeric(10, 2))
    original_price_usd: Mapped[Decimal | None] = mapped_column(Numeric(10, 2))
    status: Mapped[str | None] = mapped_column(Text)
    photo_set: Mapped[list[str] | None] = mapped_column(ARRAY(Text))
    title: Mapped[str | None] = mapped_column(Text)
    description: Mapped[str | None] = mapped_column(Text)
    posted_at: Mapped[dt.datetime | None] = mapped_column(DateTime(timezone=True))
    sold_at: Mapped[dt.datetime | None] = mapped_column(DateTime(timezone=True))
    sold_price_usd: Mapped[Decimal | None] = mapped_column(Numeric(10, 2))
    last_repriced_at: Mapped[dt.datetime | None] = mapped_column(DateTime(timezone=True))

    __table_args__ = (
        Index("idx_our_listings_status", "status", "platform"),
    )


class Sale(Base):
    __tablename__ = "sales"
    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    our_listing_id: Mapped[int | None] = mapped_column(Integer, ForeignKey("our_listings.id"))
    platform: Mapped[str] = mapped_column(Text, nullable=False)
    platform_sale_id: Mapped[str] = mapped_column(Text, unique=True)
    buyer_handle: Mapped[str | None] = mapped_column(Text)
    buyer_address: Mapped[dict | None] = mapped_column(JSONB)
    sale_price_usd: Mapped[Decimal | None] = mapped_column(Numeric(10, 2))
    platform_fee_usd: Mapped[Decimal | None] = mapped_column(Numeric(10, 2))
    net_received_usd: Mapped[Decimal | None] = mapped_column(Numeric(10, 2))
    sold_at: Mapped[dt.datetime | None] = mapped_column(DateTime(timezone=True))
    detected_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )
    review_requested_at: Mapped[dt.datetime | None] = mapped_column(DateTime(timezone=True))
    review_received: Mapped[bool] = mapped_column(Boolean, default=False)
    review_stars: Mapped[int | None] = mapped_column(Integer)


class SupplierOrder(Base):
    __tablename__ = "supplier_orders"
    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    sale_id: Mapped[int | None] = mapped_column(Integer, ForeignKey("sales.id"))
    sku: Mapped[str | None] = mapped_column(Text)
    source: Mapped[str | None] = mapped_column(Text)
    supplier_order_ref: Mapped[str | None] = mapped_column(Text)
    status: Mapped[str] = mapped_column(Text, default="queued")
    cost_usd: Mapped[Decimal | None] = mapped_column(Numeric(10, 2))
    tracking_number: Mapped[str | None] = mapped_column(Text)
    tracking_carrier: Mapped[str | None] = mapped_column(Text)
    tracking_pushed: Mapped[bool] = mapped_column(Boolean, default=False)
    error_log: Mapped[str | None] = mapped_column(Text)
    attempts: Mapped[int] = mapped_column(Integer, default=0)
    placed_at: Mapped[dt.datetime | None] = mapped_column(DateTime(timezone=True))
    shipped_at: Mapped[dt.datetime | None] = mapped_column(DateTime(timezone=True))
    delivered_at: Mapped[dt.datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )

    __table_args__ = (
        Index("idx_supplier_orders_status", "status"),
    )


class MarketListing(Base):
    __tablename__ = "market_listings"
    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    platform: Mapped[str] = mapped_column(Text, nullable=False)
    platform_listing_id: Mapped[str] = mapped_column(Text, nullable=False)
    matched_sku: Mapped[str | None] = mapped_column(Text)
    title: Mapped[str | None] = mapped_column(Text)
    price_usd: Mapped[Decimal | None] = mapped_column(Numeric(10, 2))
    seller_handle: Mapped[str | None] = mapped_column(Text)
    size: Mapped[str | None] = mapped_column(Text)
    category: Mapped[str | None] = mapped_column(Text)
    sold: Mapped[bool] = mapped_column(Boolean, default=False)
    posted_at: Mapped[dt.datetime | None] = mapped_column(DateTime(timezone=True))
    sold_at: Mapped[dt.datetime | None] = mapped_column(DateTime(timezone=True))
    url: Mapped[str | None] = mapped_column(Text)
    image_url: Mapped[str | None] = mapped_column(Text)
    scraped_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )

    __table_args__ = (
        UniqueConstraint("platform", "platform_listing_id", name="uq_market_listing_platform_id"),
    )


class Opportunity(Base):
    __tablename__ = "opportunities"
    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    sku: Mapped[str | None] = mapped_column(Text, ForeignKey("product_catalog.sku"))
    scored_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )
    market_price_median: Mapped[Decimal | None] = mapped_column(Numeric(10, 2))
    supplier_cost_usd: Mapped[Decimal | None] = mapped_column(Numeric(10, 2))
    margin_usd: Mapped[Decimal | None] = mapped_column(Numeric(10, 2))
    velocity_score: Mapped[Decimal | None] = mapped_column(Numeric(5, 2))
    saturation_count: Mapped[int | None] = mapped_column(Integer)
    composite_score: Mapped[Decimal | None] = mapped_column(Numeric(8, 2))
    recommended_action: Mapped[str | None] = mapped_column(Text)


class CompetitorSeller(Base):
    __tablename__ = "competitor_sellers"
    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    platform: Mapped[str] = mapped_column(Text, nullable=False)
    seller_handle: Mapped[str] = mapped_column(Text, nullable=False)
    categories: Mapped[list[str] | None] = mapped_column(ARRAY(Text))
    monitored: Mapped[bool] = mapped_column(Boolean, default=True)
    last_scanned: Mapped[dt.datetime | None] = mapped_column(DateTime(timezone=True))

    __table_args__ = (
        UniqueConstraint("platform", "seller_handle", name="uq_competitor_platform_handle"),
    )


class CompetitorListing(Base):
    __tablename__ = "competitor_listings"
    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    competitor_id: Mapped[int | None] = mapped_column(
        Integer, ForeignKey("competitor_sellers.id")
    )
    platform_listing_id: Mapped[str] = mapped_column(Text, nullable=False)
    title: Mapped[str | None] = mapped_column(Text)
    price_usd: Mapped[Decimal | None] = mapped_column(Numeric(10, 2))
    matched_sku: Mapped[str | None] = mapped_column(Text)
    first_seen: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )
    last_seen: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )
    sold: Mapped[bool] = mapped_column(Boolean, default=False)

    __table_args__ = (
        UniqueConstraint("competitor_id", "platform_listing_id", name="uq_comp_listing_id"),
    )


class DmThread(Base):
    __tablename__ = "dm_threads"
    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    platform: Mapped[str] = mapped_column(Text, nullable=False)
    posting_account_id: Mapped[int | None] = mapped_column(
        Integer, ForeignKey("posting_accounts.id")
    )
    buyer_handle: Mapped[str | None] = mapped_column(Text)
    related_listing_id: Mapped[int | None] = mapped_column(Integer, ForeignKey("our_listings.id"))
    last_message_at: Mapped[dt.datetime | None] = mapped_column(DateTime(timezone=True))
    last_responded_at: Mapped[dt.datetime | None] = mapped_column(DateTime(timezone=True))
    needs_human_review: Mapped[bool] = mapped_column(Boolean, default=False)
    review_reason: Mapped[str | None] = mapped_column(Text)


class DmMessage(Base):
    __tablename__ = "dm_messages"
    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    thread_id: Mapped[int | None] = mapped_column(Integer, ForeignKey("dm_threads.id"))
    direction: Mapped[str | None] = mapped_column(Text)
    body: Mapped[str | None] = mapped_column(Text)
    classified_intent: Mapped[str | None] = mapped_column(Text)
    sent_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )


class PnlDaily(Base):
    __tablename__ = "pnl_daily"
    date: Mapped[dt.date] = mapped_column(Date, primary_key=True)
    sales_count: Mapped[int | None] = mapped_column(Integer)
    gross_sales_usd: Mapped[Decimal | None] = mapped_column(Numeric(10, 2))
    platform_fees_usd: Mapped[Decimal | None] = mapped_column(Numeric(10, 2))
    supplier_costs_usd: Mapped[Decimal | None] = mapped_column(Numeric(10, 2))
    shipping_costs_usd: Mapped[Decimal | None] = mapped_column(Numeric(10, 2))
    reshipper_fees_usd: Mapped[Decimal | None] = mapped_column(Numeric(10, 2))
    chargebacks_usd: Mapped[Decimal | None] = mapped_column(Numeric(10, 2))
    net_profit_usd: Mapped[Decimal | None] = mapped_column(Numeric(10, 2))
    computed_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )


class PnlSkuRollup(Base):
    __tablename__ = "pnl_sku_rollup"
    sku: Mapped[str] = mapped_column(Text, primary_key=True)
    period_start: Mapped[dt.date] = mapped_column(Date, primary_key=True)
    period_end: Mapped[dt.date] = mapped_column(Date, primary_key=True)
    sales_count: Mapped[int | None] = mapped_column(Integer)
    gross_usd: Mapped[Decimal | None] = mapped_column(Numeric(10, 2))
    cost_usd: Mapped[Decimal | None] = mapped_column(Numeric(10, 2))
    fees_usd: Mapped[Decimal | None] = mapped_column(Numeric(10, 2))
    net_usd: Mapped[Decimal | None] = mapped_column(Numeric(10, 2))
    avg_margin_pct: Mapped[Decimal | None] = mapped_column(Numeric(5, 2))
    recommendation: Mapped[str | None] = mapped_column(Text)


class Dispute(Base):
    __tablename__ = "disputes"
    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    sale_id: Mapped[int | None] = mapped_column(Integer, ForeignKey("sales.id"))
    platform: Mapped[str | None] = mapped_column(Text)
    dispute_ref: Mapped[str | None] = mapped_column(Text)
    reason: Mapped[str | None] = mapped_column(Text)
    status: Mapped[str | None] = mapped_column(Text)
    opened_at: Mapped[dt.datetime | None] = mapped_column(DateTime(timezone=True))
    evidence_packet_path: Mapped[str | None] = mapped_column(Text)
    resolved_at: Mapped[dt.datetime | None] = mapped_column(DateTime(timezone=True))
    outcome: Mapped[str | None] = mapped_column(Text)


class ScrapeRun(Base):
    __tablename__ = "scrape_runs"
    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    platform: Mapped[str | None] = mapped_column(Text)
    query: Mapped[str | None] = mapped_column(Text)
    listings_found: Mapped[int | None] = mapped_column(Integer)
    errors: Mapped[int | None] = mapped_column(Integer)
    duration_sec: Mapped[int | None] = mapped_column(Integer)
    ran_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )


class SystemEvent(Base):
    __tablename__ = "system_events"
    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    level: Mapped[str | None] = mapped_column(String(16))
    component: Mapped[str | None] = mapped_column(Text)
    message: Mapped[str | None] = mapped_column(Text)
    payload: Mapped[dict | None] = mapped_column(JSONB)
    created_at: Mapped[dt.datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )
