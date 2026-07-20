#!/bin/bash

CONTROL_SERVER_URL="${CONTROL_SERVER_URL:-http://gluetun:8000}"
CONTROL_SERVER_URL="${CONTROL_SERVER_URL%/}"
CHECK_INTERVAL="${CHECK_INTERVAL:-30}"
HTTP_S="${HTTP_S:-http}"
VPNMODE="${VPNMODE:-SMARTMODE}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-60}"
WAIT_INTERVAL="${WAIT_INTERVAL:-5}"
CONTROL_SERVER_AUTH_MODE="${CONTROL_SERVER_AUTH_MODE:-apikey}"
CONTROL_SERVER_API_KEY="${CONTROL_SERVER_API_KEY:-}"
CONTROL_SERVER_API_KEY_FILE="${CONTROL_SERVER_API_KEY_FILE:-}"
CONTROL_SERVER_BASIC_USER="${CONTROL_SERVER_BASIC_USER:-}"
CONTROL_SERVER_BASIC_PASS="${CONTROL_SERVER_BASIC_PASS:-}"
CONTROL_SERVER_TIMEOUT="${CONTROL_SERVER_TIMEOUT:-15}"
CONTROL_SERVER_RETRIES="${CONTROL_SERVER_RETRIES:-3}"
CONTROL_SERVER_RETRY_DELAY="${CONTROL_SERVER_RETRY_DELAY:-2}"
QBITTORRENT_TIMEOUT="${QBITTORRENT_TIMEOUT:-15}"
QBITTORRENT_URL="${HTTP_S}://${QBITTORRENT_SERVER}:${QBITTORRENT_PORT}"

COOKIES="/tmp/cookies.txt"
LAST_PORT=""

remove_cookies() {
  rm -f "$COOKIES"
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

load_control_server_auth() {
  if [ -z "$CONTROL_SERVER_API_KEY" ] && [ -n "$CONTROL_SERVER_API_KEY_FILE" ] && [ -f "$CONTROL_SERVER_API_KEY_FILE" ]; then
    CONTROL_SERVER_API_KEY=$(trim "$(head -n 1 "$CONTROL_SERVER_API_KEY_FILE")")
  fi
}

validate_control_server_auth() {
  case "$CONTROL_SERVER_AUTH_MODE" in
    none)
      ;;
    apikey)
      if [ -z "$CONTROL_SERVER_API_KEY" ]; then
        echo "FATAL: CONTROL_SERVER_AUTH_MODE=apikey requires CONTROL_SERVER_API_KEY or CONTROL_SERVER_API_KEY_FILE."
        exit 1
      fi
      ;;
    basic)
      if [ -z "$CONTROL_SERVER_BASIC_USER" ] || [ -z "$CONTROL_SERVER_BASIC_PASS" ]; then
        echo "FATAL: CONTROL_SERVER_AUTH_MODE=basic requires CONTROL_SERVER_BASIC_USER and CONTROL_SERVER_BASIC_PASS."
        exit 1
      fi
      ;;
    *)
      echo "FATAL: Invalid CONTROL_SERVER_AUTH_MODE '$CONTROL_SERVER_AUTH_MODE'. Expected none, apikey, or basic."
      exit 1
      ;;
  esac
}

validate_configuration() {
  local name
  local value

  if [ "$HTTP_S" != "http" ] && [ "$HTTP_S" != "https" ]; then
    echo "FATAL: HTTP_S must be either 'http' or 'https'." >&2
    exit 1
  fi

  if [ -z "${QBITTORRENT_SERVER:-}" ]; then
    echo "FATAL: QBITTORRENT_SERVER must not be empty." >&2
    exit 1
  fi

  if ! [[ "${QBITTORRENT_PORT:-}" =~ ^[0-9]+$ ]] || [ "$QBITTORRENT_PORT" -lt 1 ] || [ "$QBITTORRENT_PORT" -gt 65535 ]; then
    echo "FATAL: QBITTORRENT_PORT must be an integer between 1 and 65535." >&2
    exit 1
  fi

  for name in CHECK_INTERVAL WAIT_TIMEOUT WAIT_INTERVAL CONTROL_SERVER_TIMEOUT CONTROL_SERVER_RETRIES CONTROL_SERVER_RETRY_DELAY QBITTORRENT_TIMEOUT; do
    value="${!name}"
    if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt 1 ]; then
      echo "FATAL: $name must be a positive integer." >&2
      exit 1
    fi
  done
}

control_server_request() {
  local path="$1"
  shift
  local attempt=1
  local delay="$CONTROL_SERVER_RETRY_DELAY"
  local temp_file
  local http_code
  local curl_status

  while [ "$attempt" -le "$CONTROL_SERVER_RETRIES" ]; do
    temp_file=$(mktemp)

    case "$CONTROL_SERVER_AUTH_MODE" in
      apikey)
        http_code=$(curl -sS --connect-timeout 5 --max-time "$CONTROL_SERVER_TIMEOUT" \
          -H "X-API-Key: $CONTROL_SERVER_API_KEY" \
          -o "$temp_file" -w "%{http_code}" "$@" "$CONTROL_SERVER_URL$path")
        ;;
      basic)
        http_code=$(curl -sS --connect-timeout 5 --max-time "$CONTROL_SERVER_TIMEOUT" \
          -u "$CONTROL_SERVER_BASIC_USER:$CONTROL_SERVER_BASIC_PASS" \
          -o "$temp_file" -w "%{http_code}" "$@" "$CONTROL_SERVER_URL$path")
        ;;
      *)
        http_code=$(curl -sS --connect-timeout 5 --max-time "$CONTROL_SERVER_TIMEOUT" \
          -o "$temp_file" -w "%{http_code}" "$@" "$CONTROL_SERVER_URL$path")
        ;;
    esac
    curl_status=$?

    if [ "$curl_status" -ne 0 ]; then
      rm -f "$temp_file"
      if [ "$attempt" -lt "$CONTROL_SERVER_RETRIES" ]; then
        echo "Control Server request failed (network/timeout). Retrying in ${delay}s..." >&2
        sleep "$delay"
        delay=$((delay * 2))
        attempt=$((attempt + 1))
        continue
      fi
      return 1
    fi

    if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
      cat "$temp_file"
      rm -f "$temp_file"
      return 0
    fi

    if [ "$http_code" -eq 401 ] || [ "$http_code" -eq 403 ]; then
      echo "Control Server authentication failed (HTTP $http_code)." >&2
      rm -f "$temp_file"
      return 1
    fi

    rm -f "$temp_file"
    if [ "$attempt" -lt "$CONTROL_SERVER_RETRIES" ] && { [ "$http_code" -eq 429 ] || [ "$http_code" -ge 500 ]; }; then
      echo "Control Server returned HTTP $http_code. Retrying in ${delay}s..." >&2
      sleep "$delay"
      delay=$((delay * 2))
      attempt=$((attempt + 1))
      continue
    fi

    echo "Control Server request failed with HTTP $http_code." >&2
    return 1
  done

  return 1
}

qbittorrent_curl() {
  curl -sS --fail --connect-timeout 5 --max-time "$QBITTORRENT_TIMEOUT" \
    -H "Referer: $QBITTORRENT_URL" "$@"
}

qbittorrent_login() {
  local temp_file
  local http_code
  local curl_status
  local response

  remove_cookies
  temp_file=$(mktemp)
  http_code=$(curl -sS --connect-timeout 5 --max-time "$QBITTORRENT_TIMEOUT" \
    -H "Referer: $QBITTORRENT_URL" \
    --data-urlencode "username=$QBITTORRENT_USER" \
    --data-urlencode "password=$QBITTORRENT_PASS" \
    -c "$COOKIES" -o "$temp_file" -w "%{http_code}" \
    "$QBITTORRENT_URL/api/v2/auth/login")
  curl_status=$?
  response=$(trim "$(cat "$temp_file")")
  rm -f "$temp_file"

  if [ "$curl_status" -ne 0 ]; then
    echo "qBittorrent login failed due to a network error or timeout." >&2
    return 1
  fi

  if [ "$http_code" -eq 403 ]; then
    echo "qBittorrent login rejected (HTTP 403). The client IP may be temporarily banned." >&2
    return 1
  fi

  if [ "$http_code" -ne 200 ] && [ "$http_code" -ne 204 ]; then
    echo "qBittorrent login failed with HTTP $http_code." >&2
    return 1
  fi

  # qBittorrent 5.2+ returns 204 for successful WebAPI calls without a body.
  # The following preferences request verifies that the session is authorized.
  if [ "$http_code" -eq 200 ] && [ "$response" != "Ok." ] && [ "$response" != "Ok" ]; then
    echo "qBittorrent login failed: invalid username or password." >&2
    return 1
  fi

  return 0
}

get_qbittorrent_listen_port() {
  local response

  response=$(qbittorrent_curl -b "$COOKIES" "$QBITTORRENT_URL/api/v2/app/preferences") || return 1
  echo "$response" | jq -er '.listen_port' 2>/dev/null
}

set_qbittorrent_listen_port() {
  local port="$1"

  qbittorrent_curl -b "$COOKIES" \
    --data-urlencode "json={\"listen_port\":$port}" \
    "$QBITTORRENT_URL/api/v2/app/setPreferences" >/dev/null
}

get_forwarded_port() {
  local response=""
  local port=""
  local attempt=1
  local delay="$CONTROL_SERVER_RETRY_DELAY"

  while [ "$attempt" -le "$CONTROL_SERVER_RETRIES" ]; do
    response=$(control_server_request "/v1/portforward") || return 1
    port=$(echo "$response" | jq -r '.port // empty' 2>/dev/null)
    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
      echo "$port"
      return 0
    fi

    if [ "$attempt" -lt "$CONTROL_SERVER_RETRIES" ]; then
      echo "Control Server has no valid forwarded port yet ('$port'). Retrying in ${delay}s..." >&2
      sleep "$delay"
      delay=$((delay * 2))
    fi
    attempt=$((attempt + 1))
  done

  echo "Control Server returned an invalid forwarded port: '$port'." >&2
  return 1
}

wait_for_vpn_status() {
  local desired_status="$1"
  local timeout="${WAIT_TIMEOUT}"
  local interval="${WAIT_INTERVAL}"
  local elapsed=0
  local status_response=""
  local current_status=""

  echo "Waiting for VPN status to become '$desired_status'..."
  while [ "$elapsed" -lt "$timeout" ]; do
    if ! status_response=$(control_server_request "/v1/vpn/status"); then
      echo "Failed to query VPN status from Control Server."
      return 1
    fi
    current_status=$(echo "$status_response" | jq -r '.status')
    echo "Current VPN status: $current_status"
    if [ "$current_status" = "$desired_status" ]; then
      echo "VPN status is now '$desired_status'"
      return 0
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  echo "Timeout waiting for VPN status to become '$desired_status'. Current status: $current_status"
  return 1
}

change_vpn_status() {
  local status="$1"
  local response=""
  echo "Setting VPN status to '$status'..."
  response=$(control_server_request "/v1/vpn/status" -X PUT -H "Content-Type: application/json" \
    -d "{\"status\":\"$status\"}") || return 1
  echo "Response from VPN status change: $response"
  wait_for_vpn_status "$status"
}

check_port_status() {
  local ip="$1"
  local port="$2"
  local retries=3
  local delay=5

  for attempt in $(seq 1 $retries); do
    echo "Checking TCP port $port on $ip with nmap (Attempt: $attempt)..."
    tcp_result=$(nmap -Pn -p "$port" "$ip" 2>/dev/null | grep "$port/tcp")
    if echo "$tcp_result" | grep -qi "open"; then
      echo "TCP port $port is open on $ip."
      return 0
    else
      echo "WARNING: TCP port $port is closed or filtered on $ip!"
      if [ "$attempt" -lt "$retries" ]; then
        echo "Retrying in $delay seconds..."
        sleep "$delay"
      fi
    fi
  done

  echo "TCP port check failed after $retries attempts."
  return 1
}

normalize_vpn_mode() {
  case "$VPNMODE" in
    OPENVPN|WIREGUARD)
      echo "VPNMODE '$VPNMODE' is deprecated. Using SMARTMODE."
      VPNMODE="SMARTMODE"
      ;;
    SMARTMODE|DUMPMODE)
      ;;
    *)
      echo "FATAL: Unknown VPNMODE '$VPNMODE'. Expected SMARTMODE or DUMPMODE." >&2
      exit 1
      ;;
  esac
}

update_port() {
  local NEW_PORT=""
  local CURRENT_QBIT_PORT=""
  local PUBLIC_IP=""
  local public_ip_response=""

  echo "Retrieving forwarded port from Control Server..."
  NEW_PORT=$(get_forwarded_port)
  if [ -z "$NEW_PORT" ] || [ "$NEW_PORT" = "null" ]; then
    echo "Error retrieving forwarded port from Control Server"
    return 1
  fi

  if [ "$LAST_PORT" = "$NEW_PORT" ]; then
    echo "Port has not changed. Current port: $NEW_PORT. No update necessary."

    echo "Ensuring qBittorrent is reachable and correct port is set..."
    if qbittorrent_login; then
      if ! CURRENT_QBIT_PORT=$(get_qbittorrent_listen_port); then
        echo "Error retrieving qBittorrent preferences."
        remove_cookies
        return 1
      fi
      if [ "$CURRENT_QBIT_PORT" != "$NEW_PORT" ]; then
        echo "qBittorrent is reachable but using incorrect port: $CURRENT_QBIT_PORT (expected: $NEW_PORT)"
        echo "Updating qBittorrent to port $NEW_PORT..."
        if ! set_qbittorrent_listen_port "$NEW_PORT"; then
          echo "Error updating qBittorrent listening port."
          remove_cookies
          return 1
        fi
        echo "qBittorrent port updated."
      else
        echo "qBittorrent port is correctly set."
      fi
    else
      echo "qBittorrent not reachable or login failed."
      remove_cookies
      return 1
    fi
    remove_cookies
  else
    echo "Logging into qBittorrent..."
    if ! qbittorrent_login; then
      echo "Error logging into the qBittorrent Web UI"
      return 1
    fi

    echo "Updating qBittorrent listening port to $NEW_PORT..."
    if ! set_qbittorrent_listen_port "$NEW_PORT"; then
      echo "Error updating qBittorrent listening port."
      remove_cookies
      return 1
    fi
    echo "qBittorrent successfully updated to port $NEW_PORT"

    LAST_PORT="$NEW_PORT"
    remove_cookies
  fi

  if [ "$VPNMODE" = "DUMPMODE" ]; then
    echo "DUMPMODE active: Port updated without TCP port check."
    return 0
  fi

  echo "Retrieving current VPN public IP from Control Server..."
  if ! public_ip_response=$(control_server_request "/v1/publicip/ip"); then
    echo "Error retrieving public IP from Control Server"
    return 1
  fi
  PUBLIC_IP=$(echo "$public_ip_response" | jq -r '.public_ip')
  if [ -z "$PUBLIC_IP" ] || [ "$PUBLIC_IP" = "null" ]; then
    echo "Error retrieving public IP from Control Server"
    return 1
  else
    echo "Current VPN public IP: $PUBLIC_IP"
    if check_port_status "$PUBLIC_IP" "$NEW_PORT"; then
      echo "Port check successful."
    else
      echo "Port check failed."
      if [ "$VPNMODE" = "SMARTMODE" ]; then
        echo "VPNMODE is $VPNMODE. Restarting VPN connection..."
        if ! change_vpn_status "stopped"; then
          echo "Failed to stop the VPN connection. Restart aborted."
          return 1
        fi
        if ! change_vpn_status "running"; then
          echo "Failed to start the VPN connection after stopping it."
          return 1
        fi
      else
        echo "Unknown VPNMODE: $VPNMODE. No action taken."
      fi
    fi
  fi
}


load_control_server_auth
validate_configuration
validate_control_server_auth
normalize_vpn_mode

while true; do
  if ! update_port; then
    echo "Update cycle failed. Retrying after ${CHECK_INTERVAL}s." >&2
  fi
  sleep "$CHECK_INTERVAL"
done
