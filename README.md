# gluetun-qbittorrent Port Manager
Automatically updates the listening port for qBittorrent to match the port forwarded by [Gluetun](https://github.com/qdm12/gluetun/). This project is a fork of [SnoringDragon's gluetun-qbittorrent-port-manager](https://github.com/SnoringDragon/gluetun-qbittorrent-port-manager).

## Overview
[Gluetun](https://github.com/qdm12/gluetun/) can forward ports for supported VPN providers, but qBittorrent lacks the ability to automatically update its listening port. In modern Gluetun versions (v3.40.0+), port information is exposed through the Control Server API. This Docker container-based script periodically (by default every 30 seconds) retrieves the current forwarded port and VPN public IP via the Control Server API, then automatically updates qBittorrent's listening port accordingly.

The script also performs a TCP port check using nmap to verify that the forwarded port is open. To handle cases when the TCP port is not open, two different modes have been implemented:

- SMARTMODE:
If the TCP port check fails, the script restarts the VPN connection through `/v1/vpn/status` (stop -> start). This works for OpenVPN and WireGuard.

- DUMPMODE:
Some users only require the forwarded port to be updated automatically, regardless of whether the TCP port is open. In dump mode, the script updates the port if it has changed but skips the TCP port check entirely. This mode is useful when only UDP connectivity is needed or if you prefer to manage TCP connectivity by other means.

## Important Note
You must integrate the provided `docker-compose.yml` configuration into your existing Docker Compose setup that includes Gluetun. Be sure to replace the default values with your specific settings; otherwise, the script will not function correctly.

The Docker image includes a `HEALTHCHECK` that validates Control Server reachability using your configured authentication mode.

qBittorrent WebUI access follows the v5.0+ API requirements: login and mutations use POST, preferences use GET, authentication uses the SID cookie, and every request sends a matching `Referer` header for CSRF/Host validation. Login accepts both the traditional `200 OK` response and qBittorrent 5.2+'s `204 No Content`; the following authenticated preferences request verifies access.

## Manual Test
Before using this script, ensure that qBittorrent is properly connected to the forwarded port. You can confirm this if you see a green globe icon at the bottom of the qBittorrent WebUI.

## Setting Up Gluetun

The Control Server is built into Gluetun and listens on port `8000`. Current releases make every route private by default, so configure authentication before using it. The old `CONTROL_SERVER` and `CONTROL_SERVER_ALLOW_CIDRS` variables are no longer used.

Mount Gluetun's data directory, for example:

```yaml
volumes:
  - /docker/gluetunvpn:/gluetun
```

Generate a suitable API key:

```sh
docker run --rm qmcgaw/gluetun genkey
```

Create `/docker/gluetunvpn/auth/config.toml` with the generated key:

```toml
[[roles]]
name = "portmanager"
routes = [
  "GET /v1/portforward",
  "GET /v1/publicip/ip",
  "GET /v1/vpn/status",
  "PUT /v1/vpn/status"
]
auth = "apikey"
apikey = "replace-with-the-generated-api-key"
```

Restart Gluetun after changing this file. The default container path is `/gluetun/auth/config.toml`; it can be changed with `HTTP_CONTROL_SERVER_AUTH_CONFIG_FILEPATH`.

Do not publish port `8000` on the Docker host when the port manager and Gluetun share a Docker network. The internal address `http://gluetun:8000` is sufficient. If external access is required, protect it with TLS and restrict network access.

## Setting Up Gluetun-qBittorrent Port Manager
No Gluetun data volume mount is required for the port-manager container. It reads everything through the Gluetun Control Server API. Both containers must share a Docker network. When both services are in the same Compose project, Compose's default network is sufficient.

The supplied Compose example reads the Control Server API key from `./secrets/gluetun_control_server_api_key`. This file must contain the same key as Gluetun's `config.toml` and should contain only that key on its first line.

Environment Variables
Configure your Docker Compose file to include the qBittorrent connection details as well as the Control Server URL and timing parameters. For example:
```
environment:
  QBITTORRENT_SERVER: localhost         # IP address of your qBittorrent server (adjust as needed)
  QBITTORRENT_PORT: 8080                # Port on which qBittorrent is listening
  QBITTORRENT_USER: admin               # qBittorrent username
  QBITTORRENT_PASS: adminadmin          # qBittorrent password
  HTTP_S: http                          # Use "http" or "https" as required

  # Timing parameters
  CHECK_INTERVAL: 30                    # Interval (in seconds) for the update cycle (default: 30)
  WAIT_TIMEOUT: 60                      # Timeout (in seconds) for waiting on VPN status changes
  WAIT_INTERVAL: 5                      # Interval (in seconds) between VPN status checks
  CONTROL_SERVER_TIMEOUT: 15            # HTTP timeout for Control Server requests
  CONTROL_SERVER_RETRIES: 3             # Retries for Control Server requests
  CONTROL_SERVER_RETRY_DELAY: 2         # Initial retry delay in seconds (exponential backoff)
  QBITTORRENT_TIMEOUT: 15               # HTTP timeout for qBittorrent API requests

  # Control Server settings
  # "gluetun" is the Gluetun service name on the shared Docker network.
  CONTROL_SERVER_URL: http://gluetun:8000
  # Auth mode: none, apikey, or basic
  CONTROL_SERVER_AUTH_MODE: apikey
  # Docker secret containing the same key as Gluetun's config.toml
  CONTROL_SERVER_API_KEY_FILE: /run/secrets/gluetun_control_server_api_key

  # VPN Mode settings
  # Options: SMARTMODE or DUMPMODE
  # OPENVPN/WIREGUARD are still accepted as aliases for backward compatibility
  VPNMODE: SMARTMODE
```
With these settings in place, the script will dynamically update qBittorrent's listening port by querying the Gluetun Control Server (`/v1/portforward`) for the current forwarded port and (`/v1/publicip/ip`) for the VPN public IP. It will then perform a health check using nmap and take action based on the selected VPN mode:

Note: this project now targets the current Gluetun route `GET /v1/portforward` and no longer falls back to the legacy `GET /v1/openvpn/portforwarded`.

## Summary VPN modes
- SMARTMODE: Restarts the VPN connection if the TCP port is not open.
- DUMPMODE: Simply updates the port without performing a TCP port check.
This flexibility allows users to choose the behavior that best fits their VPN configuration and network requirements.


## WireGuard note

Gluetun now exposes protocol-agnostic VPN status routes (`/v1/vpn/status`) for OpenVPN and WireGuard. This script uses those routes for restart handling.
