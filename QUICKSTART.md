# Quickstart — zero to first live listing

This walks every real step. It's blunt about what the system automates vs. what
you touch by hand. **Expected total time: 2-4 hours of your attention spread
across a few days** (account warming eats most of the wall clock).

---

## 0. One-time VPS prep

You need:
- A VPS running Linux with Docker + Docker Compose (Hetzner CPX21 recommended, $12/mo)
- Root or sudo access
- A domain is NOT required (no public endpoints)

```bash
# On the VPS:
git clone <your repo url> dropship-mp
cd dropship-mp
bash scripts/bootstrap.sh
```

This creates `.env` with a random Postgres password and prepares `data/` dirs.

---

## 1. Telegram bot (5 min)

1. On your phone, open Telegram → search `@BotFather` → `/newbot` → pick any name.
2. Copy the token BotFather gives you.
3. DM your new bot once (any message).
4. In a browser: `https://api.telegram.org/bot<TOKEN>/getUpdates` → find your `chat.id`.
5. In `.env` on the VPS:
   ```
   TELEGRAM_BOT_TOKEN=123:ABC...
   TELEGRAM_CHAT_ID=123456789
   TELEGRAM_ADMIN_IDS=123456789
   ```

---

## 2. Boot the stack (2 min)

```bash
make build
make up
make logs      # watch for "telegram bot online"
```

In Telegram, send `/health`. You should see `db ✓ redis ✓`.

If anything fails, `make logs` tells you what. The most common first-boot
problem is forgetting to fill `TELEGRAM_BOT_TOKEN`.

---

## 3. Seed demo data so /digest has something to show (30 sec)

```bash
make seed
```

Then in Telegram: `/digest` — you'll see a placeholder opportunity row for
`DEMO-TEE-BLACK`. This proves the pipeline — delete the demo row in Postgres
once you've added real SKUs.

---

## 4. Create marketplace accounts — BY HAND (1-2 hr spread over days)

**You must do this yourself from your own device.** Automated signup gets
instant bans on all three platforms. Signup needs SMS verification + often
photo ID — these are human checkpoints by design.

For each platform (do them one week apart ideally so you don't trip any
cross-platform correlation):

1. Sign up with a Google Voice / MySudo number
2. Use `vertdaty@gmail.com` + aliases (`vertdaty+depop@gmail.com`,
   `vertdaty+grailed@gmail.com`, `vertdaty+mercari@gmail.com` — Gmail
   routes all to the same inbox)
3. Complete profile: real-looking photo, short bio, pick a timezone
4. Verify email + phone
5. **Do NOT list anything yet.** The system does the warming for you.

---

## 5. Hand the system your logged-in session (5 min per account)

The login scripts open a visible Chrome window on your own laptop/desktop,
you log in by hand, press Enter in the terminal, and the session cookies land
in `data/sessions/<platform>/<handle>.json`. The VPS reads these files;
nothing is transmitted anywhere else.

**Run these on your laptop** (needs a graphical display — the VPS doesn't
have one):

```bash
# One-time: clone the repo locally too, install playwright
pip install playwright==1.47.0
playwright install chromium

# For each account:
python -m scripts.login_depop   --handle alice
python -m scripts.login_grailed --handle alice
python -m scripts.login_mercari --handle alice
```

A Chrome window opens, you log in, press Enter in the terminal.

Then copy the session JSONs to the VPS:
```bash
scp data/sessions/depop/alice.json   vps:dropship-mp/data/sessions/depop/
scp data/sessions/grailed/alice.json vps:dropship-mp/data/sessions/grailed/
scp data/sessions/mercari/alice.json vps:dropship-mp/data/sessions/mercari/
```

---

## 6. Register the account + start warming (10 sec each)

On the VPS:

```bash
docker compose run --rm worker python -m scripts.warm_new_account \
  --platform depop --handle alice --email vertdaty+depop@gmail.com
docker compose run --rm worker python -m scripts.warm_new_account \
  --platform grailed --handle alice --email vertdaty+grailed@gmail.com
docker compose run --rm worker python -m scripts.warm_new_account \
  --platform mercari --handle alice --email vertdaty+mercari@gmail.com
```

In Telegram: `/accounts` → you'll see each one at `warming`.

**Scheduler runs the daily warming cycle automatically.** On day 7 each
account flips to `active` and the posting rotation picks it up.

---

## 7. DHgate login (5 min)

Same drill — on your laptop:

```bash
python -m scripts.login_dhgate --handle dhgate
scp data/sessions/dhgate.json vps:dropship-mp/data/sessions/
```

Make sure your DHgate account has a payment method saved (PayPal is cleanest).
Otherwise the ordering flow halts at the payment step.

---

## 8. Seed your real product catalog

Replace the demo seed with your actual SKUs. Easiest: craft one more script,
or just insert via psql:

```bash
make psql
```

```sql
INSERT INTO product_catalog (sku, display_name, category, variant_group, sizes)
VALUES ('CRTZ-ALC-CARGO', 'Corteiz Alcatraz', 'menswear/bottoms', 'Cargo', ARRAY['S','M','L','XL']);

INSERT INTO product_sources (sku, source, product_url, color_option, size_option,
                             expected_price_usd, max_price_usd, priority, status)
VALUES ('CRTZ-ALC-CARGO', 'dhgate',
        'https://www.dhgate.com/product/.../000.html',
        'Black', 'M', 24.50, 32.00, 10, 'active');
```

Repeat for each real SKU + source. 5-10 to start is plenty.

---

## 9. Supply product photos

For each SKU, drop 5-10 real supplier photos into:
```
data/photos/raw/<SKU>/01.jpg
data/photos/raw/<SKU>/02.jpg
...
```

How you get them: order one sample unit to yourself (your Shipito address
later for cost control, or your home address for now), shoot your own photos
OR screenshot the DHgate product gallery.

Optional: drop 2-3 background photos (wood floor, carpet, bedroom wall) into
`data/photos/backgrounds/`. The hero shot gets composited onto one.

---

## 10. First test order (controlled, by hand)

Before letting the automation run, verify DHgate works end-to-end from one of
YOUR real sales (ship to yourself):

```bash
docker compose run --rm worker python -m src.suppliers test_order \
  --source dhgate \
  --url 'https://www.dhgate.com/product/.../000.html' \
  --color Black --size M \
  --to 'Your Name|123 Your St||Your City|TX|78701|US|+15125550123' \
  --max-price 32.00 \
  --ref TEST-0001
```

Expect one of three outcomes:
- `ok=True` with a supplier order ref → system works, your money is spent, package is coming.
- `captcha` error → DHgate wants a human; log in with the browser once, re-run.
- Selector miss → inspect `src/suppliers/selectors/dhgate.py` and tweak.

---

## 11. First automated listing

Once an account hits day 7 (status `active`):

In Telegram:
```
/post CRTZ-ALC-CARGO
```

The worker generates a title, description, photo set, price; picks the next
eligible account on each of the 3 platforms; posts. Watch `make logs` — if
a selector misses you'll see it immediately.

---

## 12. First real sale

Nothing to do. `poll_sold` sweeps every 10 min; on a new sale it:
1. Pulls the buyer address
2. Opens a DHgate order to that address
3. Writes the dropship note
4. Polls DHgate for tracking
5. Pushes the tracking back into the marketplace sale detail

3 days after delivery it DMs the buyer asking for a review. All automatic.

---

## 13. Daily rhythm (5-10 min)

- Open Telegram, `/digest`
- Approve any `⚠️` DM flagged for human review
- Tap `/post <SKU>` on 3-5 ranked items from the digest
- Glance at `/pnl` for yesterday

---

## Troubleshooting

### `make logs` shows selector errors on Depop
Depop ships UI changes every few weeks. Open
`src/marketplaces/selectors/depop.py` and fix the one that misses.
Everything that touches Depop reads from that file.

### An account got suspended
`health_check` worker runs daily and will flag it + Telegram-alert. Follow
the alert's command — launch a replacement with new credentials.

### Dispute from buyer
```
/dispute <sale_id>
```
PDF arrives in Telegram. Upload to platform's dispute form.

### Proxy question (ignore on first run)
Proxies are OPTIONAL in `.env`. Blank `PROXY_HOST` = run from VPS's own IP.
That's fine until you're running 3+ accounts per platform on the same VPS.
At that point sign up for BrightData, drop creds in `.env`, restart stack.
