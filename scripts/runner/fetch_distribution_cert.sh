#!/usr/bin/env bash
# fetch_distribution_cert.sh — Fetch appstore/distribution-cert from AWS Secrets Manager.
# Inputs:  AWS credentials already configured (OIDC or env vars).
#          Secret shape: { "p12_base64": "<base64>", "password": "<p12 password>" }
# Outputs: /tmp/dist_cert.p12 (chmod 600)
#          $GITHUB_ENV export: DIST_CERT_PASSWORD
set -euo pipefail

SECRET=$(aws secretsmanager get-secret-value \
  --secret-id appstore/distribution-cert \
  --region us-east-1 \
  --query SecretString \
  --output text)

P12_BASE64=$(echo "$SECRET" | jq -r '.p12_base64')
PASSWORD=$(echo "$SECRET" | jq -r '.password')

echo "$P12_BASE64" | base64 --decode > /tmp/dist_cert.p12
chmod 600 /tmp/dist_cert.p12

# Export password so ephemeral_keychain.sh create can import the cert.
if [[ -n "${GITHUB_ENV:-}" ]]; then
  echo "DIST_CERT_PASSWORD=${PASSWORD}" >> "$GITHUB_ENV"
fi
export DIST_CERT_PASSWORD="$PASSWORD"

echo "fetch_distribution_cert: wrote /tmp/dist_cert.p12"
