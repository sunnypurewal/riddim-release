#!/usr/bin/env bash
# aso-baseline-audit.sh — riddim-release template — copy to scripts/marketing/ and adjust
#
# Fetches App Store Connect metadata and ratings and writes a markdown baseline
# report to docs/marketing/growth-metrics-<YYYY-MM>.md (configurable).
#
# Required ENV:
#   ASC_KEY_ID        — 10-character ASC API key ID
#   ASC_ISSUER_ID     — UUID from App Store Connect Users and Access
#   ASC_KEY_PATH      — path to the AuthKey_<KEY_ID>.p8 file
#   ASC_APP_ID        — numeric Apple App ID (from App Store Connect → App Information)
#   PRIMARY_LOCALE    — locale code matching fastlane metadata dir (e.g. en-US, en-CA)
#
# Optional ENV:
#   IOS_WORKDIR       — path to the ios/ directory (default: ios)
#   EVIDENCE_OUTPUT_DIR — output directory for the report (default: docs/marketing)
#
# Usage:
#   ASC_KEY_ID=... ASC_ISSUER_ID=... ASC_KEY_PATH=~/.appstoreconnect/AuthKey.p8 \
#     ASC_APP_ID=1234567890 PRIMARY_LOCALE=en-US \
#     bash scripts/marketing/aso-baseline-audit.sh
#
# Note on Analytics data:
#   The App Store Connect API does not expose the full Analytics suite
#   (impressions, page views, conversion rates, installs-by-source, search
#   terms) via the public REST API. This script fetches what IS available
#   (ratings summary, recent reviews, app metadata) and writes placeholder
#   rows for the rest so a human can fill them in from the browser.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DATE="$(date +%Y-%m-%d)"
MONTH="$(date +%Y-%m)"
IOS_WORKDIR="${IOS_WORKDIR:-ios}"
OUT="${EVIDENCE_OUTPUT_DIR:-$REPO_ROOT/docs/marketing}/growth-metrics-$MONTH.md"

# Validate required env
: "${ASC_KEY_ID:?Set ASC_KEY_ID}"
: "${ASC_ISSUER_ID:?Set ASC_ISSUER_ID}"
: "${ASC_KEY_PATH:?Set ASC_KEY_PATH}"
: "${ASC_APP_ID:?Set ASC_APP_ID}"
: "${PRIMARY_LOCALE:?Set PRIMARY_LOCALE}"

echo "Running ASO baseline audit for $MONTH (app $ASC_APP_ID, locale $PRIMARY_LOCALE)..."

RATINGS_JSON="$(mktemp /tmp/aso-audit-ratings.XXXXXX.json)"
trap 'rm -f "$RATINGS_JSON"' EXIT

python3 - <<PYEOF
import json, time, jwt, requests, sys, os

APP_ID    = os.environ["ASC_APP_ID"]
BASE      = "https://api.appstoreconnect.apple.com/v1"
key_id    = os.environ["ASC_KEY_ID"]
issuer_id = os.environ["ASC_ISSUER_ID"]
key_path  = os.environ["ASC_KEY_PATH"]

with open(key_path) as f:
    key = f.read()

now = int(time.time())
token = jwt.encode(
    {"iss": issuer_id, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"},
    key, algorithm="ES256", headers={"kid": key_id},
)
hdrs = {"Authorization": f"Bearer {token}"}

def asc_get(path, params=None):
    r = requests.get(f"{BASE}{path}", headers=hdrs, params=params, timeout=30)
    if not r.ok:
        print(f"  ASC {r.status_code} {path}: {r.text[:200]}", file=sys.stderr)
        return {}
    return r.json()

print("Fetching customer reviews...", file=sys.stderr)
rev_data = asc_get(
    f"/apps/{APP_ID}/customerReviews",
    params={
        "limit": 20,
        "sort": "-rating",
        "fields[customerReviews]": "rating,title,body,createdDate",
    },
)
reviews = [
    {
        "rating": r["attributes"]["rating"],
        "title":  r["attributes"].get("title", ""),
        "body":   (r["attributes"].get("body") or "")[:200],
        "date":   r["attributes"]["createdDate"][:10],
    }
    for r in rev_data.get("data", [])
]

if reviews:
    total   = len(reviews)
    avg     = sum(r["rating"] for r in reviews) / total
    five_pc = sum(1 for r in reviews if r["rating"] == 5) / total * 100
else:
    total = avg = five_pc = None

result = {
    "fetched_at": "$DATE",
    "review_count_in_sample": total,
    "avg_rating_in_sample":   round(avg, 2) if avg else None,
    "five_star_pct_in_sample": round(five_pc, 1) if five_pc else None,
    "recent_reviews": reviews[:5],
}
with open("$RATINGS_JSON", "w") as f:
    json.dump(result, f, indent=2)
print(f"  Wrote ratings data ({total} reviews sampled)", file=sys.stderr)
PYEOF

RATING_AVG=$(python3 -c "import json; d=json.load(open('$RATINGS_JSON')); print(d['avg_rating_in_sample'] or '_[fill from ASC]_')")
RATING_COUNT=$(python3 -c "import json; d=json.load(open('$RATINGS_JSON')); print(d['review_count_in_sample'] or '_[fill from ASC]_')")
FIVE_STAR_PCT=$(python3 -c "import json; d=json.load(open('$RATINGS_JSON')); v=d['five_star_pct_in_sample']; print(f'{v}%' if v else '_[fill from ASC]_')")

KEYWORDS=$(cat "$REPO_ROOT/$IOS_WORKDIR/fastlane/metadata/$PRIMARY_LOCALE/keywords.txt" 2>/dev/null || echo "_[not found]_")

echo "Writing baseline document to $OUT..."
mkdir -p "$(dirname "$OUT")"

cat > "$OUT" <<MDEOF
# ASO Growth Metrics — $MONTH Baseline

**Date recorded:** $DATE
**App ID:** $ASC_APP_ID
**Locale:** $PRIMARY_LOCALE
**Script:** \`scripts/marketing/aso-baseline-audit.sh\`

---

## App Store Connect Analytics (30-day snapshot)

> Fill from ASC → Analytics → Overview. The REST API does not expose Analytics data.

| Metric | Value | Notes |
|---|---|---|
| Impressions | _[fill from ASC]_ | Unique devices that saw the app icon |
| Product page views | _[fill from ASC]_ | |
| Installs | _[fill from ASC]_ | |
| Conversion rate (views→installs) | _[fill from ASC]_ | Primary KPI — target ≥ 3% |
| Re-downloads | _[fill from ASC]_ | |
| D7 retention | _[fill from ASC]_ | Target ≥ 30% |
| D28 retention | _[fill from ASC]_ | Target ≥ 15% |

---

## Installs by Source (30-day)

> Fill from ASC → Analytics → Installs → split by Source Type.

| Source | Installs | % of total |
|---|---|---|
| App Store Search | _[fill]_ | |
| App Store Browse | _[fill]_ | |
| Web Referral | _[fill]_ | |
| App Referral | _[fill]_ | |

---

## Top Search Terms (from ASC → Acquisition → App Store Search)

> Fill from ASC → Analytics → Acquisition → App Store Search Popularity.

| Rank | Term | Impressions | Installs | CVR |
|---|---|---|---|---|
| 1 | | | | |
| 2 | | | | |
| 3 | | | | |
| 4 | | | | |
| 5 | | | | |

---

## Ratings

> Avg rating and five-star % are sampled from the 20 most-recent reviews via the
> ASC API (not the full lifetime breakdown — fill the lifetime numbers from ASC).

| Metric | API sample | Lifetime (fill from ASC) |
|---|---|---|
| Average rating | $RATING_AVG | _[fill]_ |
| Total ratings (lifetime) | — | _[fill]_ |
| Ratings in sample | $RATING_COUNT | — |
| 5-star % in sample | $FIVE_STAR_PCT | _[fill lifetime]_ |

---

## Current Keyword Field (as of $DATE)

\`\`\`
$KEYWORDS
\`\`\`

---

## Current Listing Copy Summary

> Fill in the current app name, subtitle, and promotional text from ASC.

- **App name:** _[fill]_
- **Subtitle:** _[fill]_
- **Promotional text:** _[fill]_

---

## Google Search Console (fill from search.google.com/search-console)

> Date range: last 28 days ending $DATE.

| Metric | Value |
|---|---|
| Total clicks (28 days) | _[fill]_ |
| Total impressions (28 days) | _[fill]_ |
| Average CTR | _[fill]_ |
| Average position | _[fill]_ |

### Top queries by clicks

> Fill from Search Console → Performance → Queries.

| Rank | Query | Clicks | Impressions | Position |
|---|---|---|---|---|
| 1 | | | | |
| 2 | | | | |
| 3 | | | | |
| 4 | | | | |
| 5 | | | | |

---

## Next Review

Scheduled: $(python3 -c "
from datetime import date
d = date.today().replace(day=1)
m = d.month % 12 + 1
y = d.year + (1 if d.month == 12 else 0)
print(date(y, m, 28).strftime('%Y-%m'))
")-01 (monthly cadence)

---

## Notes

_Add any observations about what drove the numbers above._
MDEOF

echo "Done. Baseline document written to: $OUT"
echo ""
echo "Next steps:"
echo "  1. Open ASC → Analytics → Overview and fill in the Analytics section"
echo "  2. Open Search Console and fill in the GSC section"
echo "  3. Commit the filled-in document"
