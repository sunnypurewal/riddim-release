#!/usr/bin/env bash
# ephemeral_keychain.sh — Manage a temporary macOS keychain for CI code-signing.
# Usage:   ephemeral_keychain.sh create   — create keychain, import /tmp/dist_cert.p12
#          ephemeral_keychain.sh cleanup  — delete keychain and remove /tmp/dist_cert.p12
# Inputs (create):  KEYCHAIN_PASSWORD, DIST_CERT_PASSWORD (env vars)
# Outputs (create): /tmp/build.keychain-db set as default, added to search list, cert imported
set -euo pipefail

KEYCHAIN_PATH=/tmp/build.keychain-db
KEYCHAIN_LIST_BACKUP=/tmp/build.keychain-list.txt
DEFAULT_KEYCHAIN_BACKUP=/tmp/build.default-keychain.txt

saved_keychains=()

read_saved_keychain_list() {
  local list_file="$1"
  local keychain

  saved_keychains=()
  [[ -s "$list_file" ]] || return 0

  while IFS= read -r keychain; do
    keychain="${keychain#*\"}"
    keychain="${keychain%\"*}"
    [[ -n "$keychain" ]] || continue
    [[ "$keychain" == "$KEYCHAIN_PATH" ]] && continue
    saved_keychains+=("$keychain")
  done < "$list_file"
}

cmd="${1:-}"

case "$cmd" in
  create)
    : "${KEYCHAIN_PASSWORD:?KEYCHAIN_PASSWORD must be set}"
    : "${DIST_CERT_PASSWORD:?DIST_CERT_PASSWORD must be set}"

    security default-keychain -d user 2>/dev/null \
      | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//' \
      > "$DEFAULT_KEYCHAIN_BACKUP" || true
    security list-keychains -d user > "$KEYCHAIN_LIST_BACKUP" || true

    security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
    security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
    # 6-hour lock; lock on sleep disabled so long builds don't lose access.
    security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"

    read_saved_keychain_list "$KEYCHAIN_LIST_BACKUP"
    security list-keychains -d user -s "$KEYCHAIN_PATH" "${saved_keychains[@]+"${saved_keychains[@]}"}"
    security default-keychain -d user -s "$KEYCHAIN_PATH"

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

    echo "ephemeral_keychain: code signing identities in ${KEYCHAIN_PATH}"
    security find-identity -v -p codesigning "$KEYCHAIN_PATH" || true
    echo "ephemeral_keychain: code signing identities in keychain search list"
    security find-identity -v -p codesigning || true
    echo "ephemeral_keychain: created and configured ${KEYCHAIN_PATH}"
    ;;

  cleanup)
    if [[ -s "$DEFAULT_KEYCHAIN_BACKUP" ]]; then
      security default-keychain -d user -s "$(cat "$DEFAULT_KEYCHAIN_BACKUP")" 2>/dev/null || true
    fi

    read_saved_keychain_list "$KEYCHAIN_LIST_BACKUP"
    if [[ ${#saved_keychains[@]} -gt 0 ]]; then
      security list-keychains -d user -s "${saved_keychains[@]}" 2>/dev/null || true
    fi

    security delete-keychain "$KEYCHAIN_PATH" 2>/dev/null || true
    rm -f /tmp/dist_cert.p12 || true
    rm -f "$KEYCHAIN_LIST_BACKUP" "$DEFAULT_KEYCHAIN_BACKUP" || true
    echo "ephemeral_keychain: cleaned up"
    ;;

  *)
    echo "Usage: $0 {create|cleanup}" >&2
    exit 1
    ;;
esac
