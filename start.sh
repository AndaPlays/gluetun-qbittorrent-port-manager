#!/bin/bash

CONTROL_SERVER_URL="${CONTROL_SERVER_URL:-http://localhost:8000}"
CONTROL_SERVER_APIKEY="${CONTROL_SERVER_APIKEY:+"--header X-API-KEY:${CONTROL_SERVER_APIKEY}"}"
CHECK_INTERVAL="${CHECK_INTERVAL:-30}"
HTTP_S="${HTTP_S:-http}"
VPNMODE="${VPNMODE:-OPENVPN}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-60}"
WAIT_INTERVAL="${WAIT_INTERVAL:-5}"

COOKIES="/tmp/cookies.txt"
LAST_PORT=""

remove_cookies() {
  rm -f "$COOKIES"
}

wait_for_vpn_status() {
  local desired_status="$1"
  local timeout="${WAIT_TIMEOUT}"
  local interval="${WAIT_INTERVAL}"
  local elapsed=0

  echo "Waiting for VPN status to become '$desired_status'..."
  while [ "$elapsed" -lt "$timeout" ]; do
    current_status=$(curl ${CONTROL_SERVER_APIKEY} -s "$CONTROL_SERVER_URL/v1/vpn/status" | jq -r '.status')
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
  echo "Setting VPN status to '$status'..."
  response=$(curl ${CONTROL_SERVER_APIKEY} -s -X PUT -H "Content-Type: application/json" \
    -d "{\"status\":\"$status\"}" "$CONTROL_SERVER_URL/v1/vpn/status")
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

shutdown_qbittorrent() {
  echo "Shutting down qBittorrent via WebUI API..."
  remove_cookies

  login_response=$(curl -s -c "$COOKIES" --data "username=$QBITTORRENT_USER&password=$QBITTORRENT_PASS" \
    "${HTTP_S}://${QBITTORRENT_SERVER}:${QBITTORRENT_PORT}/api/v2/auth/login")
  if ! echo "$login_response" | grep -iq "Ok"; then
    echo "Error logging into the qBittorrent Web UI"
    return 1
  fi

  shutdown_response=$(curl -s -b "$COOKIES" -X POST \
    "${HTTP_S}://${QBITTORRENT_SERVER}:${QBITTORRENT_PORT}/api/v2/app/shutdown")

  if [ "$shutdown_response" = "" ]; then
    echo "qBittorrent has been successfully shut down."
  else
    echo "Unexpected response: $shutdown_response"
  fi

  remove_cookies
}

update_port() {
  echo "Retrieving forwarded port from Control Server..."
  NEW_PORT=$(curl ${CONTROL_SERVER_APIKEY} -s "$CONTROL_SERVER_URL/v1/portforward" | jq -r '.port')
  if [ -z "$NEW_PORT" ] || [ "$NEW_PORT" = "null" ]; then
    echo "Error retrieving forwarded port from Control Server"
    return 1
  fi

  if [ "$LAST_PORT" = "$NEW_PORT" ]; then
    echo "Port has not changed. Current port: $NEW_PORT. No update necessary."

    echo "Ensuring qBittorrent is reachable and correct port is set..."
    remove_cookies
    login_response=$(curl -s -c "$COOKIES" --data "username=$QBITTORRENT_USER&password=$QBITTORRENT_PASS" \
      "${HTTP_S}://${QBITTORRENT_SERVER}:${QBITTORRENT_PORT}/api/v2/auth/login")
    if echo "$login_response" | grep -iq "Ok"; then
      CURRENT_QBIT_PORT=$(curl -s -b "$COOKIES" "${HTTP_S}://${QBITTORRENT_SERVER}:${QBITTORRENT_PORT}/api/v2/app/preferences" | jq -r '.listen_port')
      if [ "$CURRENT_QBIT_PORT" != "$NEW_PORT" ]; then
        echo "qBittorrent is reachable but using incorrect port: $CURRENT_QBIT_PORT (expected: $NEW_PORT)"
        echo "Updating qBittorrent to port $NEW_PORT..."
        curl -s -b "$COOKIES" --data-urlencode "json={\"listen_port\":$NEW_PORT}" \
          "${HTTP_S}://${QBITTORRENT_SERVER}:${QBITTORRENT_PORT}/api/v2/app/setPreferences" > /dev/null
        echo "qBittorrent port updated."
      else
        echo "qBittorrent port is correctly set."
      fi
    else
      echo "qBittorrent not reachable or login failed."
    fi
    remove_cookies
  else
    echo "Logging into qBittorrent..."
    remove_cookies
    login_response=$(curl -s -c "$COOKIES" --data "username=$QBITTORRENT_USER&password=$QBITTORRENT_PASS" \
      "${HTTP_S}://${QBITTORRENT_SERVER}:${QBITTORRENT_PORT}/api/v2/auth/login")
    if ! echo "$login_response" | grep -iq "Ok"; then
      echo "Error logging into the qBittorrent Web UI"
      return 1
    fi

    echo "Updating qBittorrent listening port to $NEW_PORT..."
    curl -s -b "$COOKIES" --data-urlencode "json={\"listen_port\":$NEW_PORT}" \
      "${HTTP_S}://${QBITTORRENT_SERVER}:${QBITTORRENT_PORT}/api/v2/app/setPreferences" > /dev/null
    echo "qBittorrent successfully updated to port $NEW_PORT"

    LAST_PORT="$NEW_PORT"
    remove_cookies
  fi

  if [ "$VPNMODE" = "DUMPMODE" ]; then
    echo "DUMPMODE active: Port updated without TCP port check."
    return 0
  fi

  echo "Retrieving current VPN public IP from Control Server..."
  PUBLIC_IP=$(curl ${CONTROL_SERVER_APIKEY} -s "$CONTROL_SERVER_URL/v1/publicip/ip" | jq -r '.public_ip')
  if [ -z "$PUBLIC_IP" ] || [ "$PUBLIC_IP" = "null" ]; then
    echo "Error retrieving public IP from Control Server"
  else
    echo "Current VPN public IP: $PUBLIC_IP"
    if check_port_status "$PUBLIC_IP" "$NEW_PORT"; then
      echo "Port check successful."
    else
      echo "Port check failed."
      if [ "$VPNMODE" = "OPENVPN" ]; then
        echo "VPNMODE is OPENVPN. Restarting VPN connection..."
        change_vpn_status "stopped"
        change_vpn_status "running"
      elif [ "$VPNMODE" = "WIREGUARD" ]; then
        echo "VPNMODE is WIREGUARD. Shutting down qBittorrent due to closed TCP port..."
        shutdown_qbittorrent
      else
        echo "Unknown VPNMODE: $VPNMODE. No action taken."
      fi
    fi
  fi
}


while true; do
  update_port
  sleep "$CHECK_INTERVAL"
done
