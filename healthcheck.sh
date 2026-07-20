#!/bin/sh
set -eu

CONTROL_SERVER_URL="${CONTROL_SERVER_URL:-http://gluetun:8000}"
CONTROL_SERVER_URL="${CONTROL_SERVER_URL%/}"
CONTROL_SERVER_AUTH_MODE="${CONTROL_SERVER_AUTH_MODE:-apikey}"
CONTROL_SERVER_API_KEY="${CONTROL_SERVER_API_KEY:-}"
CONTROL_SERVER_API_KEY_FILE="${CONTROL_SERVER_API_KEY_FILE:-}"
CONTROL_SERVER_BASIC_USER="${CONTROL_SERVER_BASIC_USER:-}"
CONTROL_SERVER_BASIC_PASS="${CONTROL_SERVER_BASIC_PASS:-}"
CONTROL_SERVER_TIMEOUT="${CONTROL_SERVER_TIMEOUT:-10}"

if [ -z "$CONTROL_SERVER_API_KEY" ] && [ -n "$CONTROL_SERVER_API_KEY_FILE" ] && [ -f "$CONTROL_SERVER_API_KEY_FILE" ]; then
  CONTROL_SERVER_API_KEY=$(head -n 1 "$CONTROL_SERVER_API_KEY_FILE" | tr -d '\r\n')
fi

case "$CONTROL_SERVER_AUTH_MODE" in
  apikey)
    [ -n "$CONTROL_SERVER_API_KEY" ] || exit 1
    curl -sS --fail --connect-timeout 5 --max-time "$CONTROL_SERVER_TIMEOUT" \
      -H "X-API-Key: $CONTROL_SERVER_API_KEY" \
      "$CONTROL_SERVER_URL/v1/vpn/status" >/dev/null
    ;;
  basic)
    [ -n "$CONTROL_SERVER_BASIC_USER" ] || exit 1
    [ -n "$CONTROL_SERVER_BASIC_PASS" ] || exit 1
    curl -sS --fail --connect-timeout 5 --max-time "$CONTROL_SERVER_TIMEOUT" \
      -u "$CONTROL_SERVER_BASIC_USER:$CONTROL_SERVER_BASIC_PASS" \
      "$CONTROL_SERVER_URL/v1/vpn/status" >/dev/null
    ;;
  none)
    curl -sS --fail --connect-timeout 5 --max-time "$CONTROL_SERVER_TIMEOUT" \
      "$CONTROL_SERVER_URL/v1/vpn/status" >/dev/null
    ;;
  *)
    exit 1
    ;;
esac
