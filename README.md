# gluetun-qbittorrent Port Manager
Automatically updates the listening port for qBittorrent to match the port forwarded by [Gluetun](https://github.com/qdm12/gluetun/). This project is a fork of [SnoringDragon's gluetun-qbittorrent-port-manager](https://github.com/SnoringDragon/gluetun-qbittorrent-port-manager).

## Overview
[Gluetun](https://github.com/qdm12/gluetun/)  can forward ports for supported VPN providers, but qBittorrent lacks the ability to automatically update its listening port. In previous versions, the forwarded port was written to a file; however, with Gluetun v4, this file has been replaced by a Control Server API. This Docker container-based script periodically (by default every 30 seconds) retrieves the current forwarded port and the VPN public IP via the Control Server API, then automatically updates qBittorrent's listening port accordingly. 

The script also performs a TCP port check using nmap to verify that the forwarded port is open. To handle cases when the TCP port is not open, three different modes have been implemented:

- OPENVPN mode:
In this mode, if the TCP port check fails, the script will restart the VPN connection by sending API calls to Gluetun (using the OpenVPN API endpoints). This mode is ideal for setups using OpenVPN, where the Gluetun Control Server supports VPN restarts.

- WIREGUARD mode:
For WireGuard users, the Gluetun Control Server does not offer a dedicated API to restart the VPN connection yet. Instead, if the TCP port check fails in this mode, the script will shut down qBittorrent via its WebUI API. This prevents qBittorrent from operating with a non-functional TCP port until the issue can be addressed manually.

- DUMPMODE:
Some users only require the forwarded port to be updated automatically, regardless of whether the TCP port is open. In dump mode, the script updates the port if it has changed but skips the TCP port check entirely. This mode is useful when only UDP connectivity is needed or if you prefer to manage TCP connectivity by other means.

## Important Note
You must integrate the provided `docker-compose.yml` configuration into your existing Docker Compose setup that includes Gluetun. Be sure to replace the default values with your specific settings; otherwise, the script will not function correctly.

## Manual Test
Before using this script, ensure that qBittorrent is properly connected to the forwarded port. You can confirm this if you see a green globe icon at the bottom of the qBittorrent WebUI.

##  Setting Up Gluetun
Add a volume mount to your [Gluetun](https://github.com/qdm12/gluetun/) container, for example:
```
volumes:
    - /docker/gluetunvpn:/gluetun
```
Enable the Control Server. Set the following environment variables in your Gluetun container:
```
environment:
  - CONTROL_SERVER=on
  - CONTROL_SERVER_ALLOW_CIDRS=192.168.1.0/24
```
Publish the Control Server Port. To make the Control Server externally accessible, map the internal port 8000 to a host port (e.g., 8000):
```
ports:
  - 8000:8000/tcp  # Control Server (accessible externally via port 8000, first port external, second port internal)
```

## Setting Up Gluetun-qBittorrent Port Manager
Ensure that the correct volume is mounted so that the container can access any necessary shared data. For example:
```
volumes:
  - /docker/gluetun:/tmp/gluetun
```
Within the container, this volume will be accessible at `/tmp/gluetun`.

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

  # Control Server settings
  # The Control Server is assumed to be available at hostname "gluetun" on port 8000 within the Docker network.
  CONTROL_SERVER_URL: http://gluetun:8000
  # Optional API key for Gluetun Control Server
  #CONTROL_SERVER_APIKEY: key

  # VPN Mode settings
  # Options: OPENVPN, WIREGUARD, or DUMPMODE
  VPNMODE: OPENVPN
```
With these settings in place, the script will dynamically update qBittorrent's listening port by querying the Gluetun Control Server for the current forwarded port and VPN public IP. It will then perform a health check using nmap and take action based on the selected VPN mode:

## Summary VPN modes
- OPENVPN mode: Restarts the VPN connection if the TCP port is not open.
- WIREGUARD mode: Shuts down qBittorrent if the TCP port is not open.
- DUMPMODE: Simply updates the port without performing a TCP port check.
This flexibility allows users to choose the behavior that best fits their VPN configuration and network requirements.


## When will WireGuard auto-restart be supported?

Automatic VPN restart in WireGuard mode will be supported once the corresponding API is implemented in Gluetun. You can track the [current status here](https://github.com/qdm12/gluetun/issues/1113#issue-1345565765). In the meantime, if the TCP port is not open, the script will shut down qBittorrent. If you don't want this use mode `DUMPMODE`.