#!/usr/bin/env bash
# fetch_asc_secret.sh — Fetch appstore/connect-api from AWS Secrets Manager.
# Inputs:  AWS credentials already configured (OIDC or env vars).
# Outputs: ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8 (chmod 600)
#          /tmp/asc_api_key.json  (fastlane app_store_connect_api_key format)
#          $GITHUB_ENV exports: ASC_KEY_ID, ASC_ISSUER_ID
set -euo pipefail

SECRET=$(aws secretsmanager get-secret-value \
  --secret-id appstore/connect-api \
  --region us-east-1 \
  --query SecretString \
  --output text)

KEY_ID=$(echo "$SECRET" | jq -r '.key_id')
ISSUER_ID=$(echo "$SECRET" | jq -r '.issuer_id')
PRIVATE_KEY=$(echo "$SECRET" | jq -r '.private_key')

mkdir -p ~/.appstoreconnect/private_keys
P8_PATH=~/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8
printf '%s' "$PRIVATE_KEY" > "$P8_PATH"
chmod 600 "$P8_PATH"

# Write fastlane-compatible API key JSON (used by release-app-store.yml deliver calls).
cat > /tmp/asc_api_key.json <<JSON
{
  "key_id": "${KEY_ID}",
  "issuer_id": "${ISSUER_ID}",
  "key": "${PRIVATE_KEY}",
  "in_house": false
}
JSON
chmod 600 /tmp/asc_api_key.json

# Export to GitHub Actions environment for subsequent steps in the same job.
if [[ -n "${GITHUB_ENV:-}" ]]; then
  echo "ASC_KEY_ID=${KEY_ID}" >> "$GITHUB_ENV"
  echo "ASC_ISSUER_ID=${ISSUER_ID}" >> "$GITHUB_ENV"
fi

echo "fetch_asc_secret: wrote ${P8_PATH} and /tmp/asc_api_key.json"
