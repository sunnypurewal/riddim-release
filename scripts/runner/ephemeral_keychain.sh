#!/usr/bin/env bash
# ephemeral_keychain.sh — Manage a temporary macOS keychain for CI code-signing.
# Usage:   ephemeral_keychain.sh create   — create keychain, import /tmp/dist_cert.p12
#          ephemeral_keychain.sh cleanup  — delete keychain and remove /tmp/dist_cert.p12
# Inputs (create):  KEYCHAIN_PASSWORD, DIST_CERT_PASSWORD (env vars)
# Outputs (create): /tmp/build.keychain-db set as default, cert imported
set -euo pipefail

KEYCHAIN_PATH=/tmp/build.keychain-db

cmd="${1:-}"

case "$cmd" in
  create)
    : "${KEYCHAIN_PASSWORD:?KEYCHAIN_PASSWORD must be set}"
    : "${DIST_CERT_PASSWORD:?DIST_CERT_PASSWORD must be set}"

    security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
    security default-keychain -s "$KEYCHAIN_PATH"
    security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
    # 6-hour lock; lock on sleep disabled so long builds don't lose access.
    security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"

    security import /tmp/dist_cert.p12 \
      -k "$KEYCHAIN_PATH" \
      -P "$DIST_CERT_PASSWORD" \
      -T /usr/bin/codesign \
      -T /usr/bin/security

    # Allow codesign to access the key without an interactive passphrase prompt.
    security set-key-partition-list \
      -S apple-tool:,apple: \
      -s -k "$KEYCHAIN_PASSWORD" \
      "$KEYCHAIN_PATH"

    echo "ephemeral_keychain: created and configured ${KEYCHAIN_PATH}"
    ;;

  cleanup)
    security delete-keychain "$KEYCHAIN_PATH" 2>/dev/null || true
    rm -f /tmp/dist_cert.p12 || true
    echo "ephemeral_keychain: cleaned up"
    ;;

  *)
    echo "Usage: $0 {create|cleanup}" >&2
    exit 1
    ;;
esac
