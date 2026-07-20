FROM alpine:latest

# Update and install required packages: curl, bash, jq, and nmap
RUN apk update && apk add --no-cache curl bash jq nmap

# Default environment variables for qBittorrent connection
ENV QBITTORRENT_SERVER=localhost
ENV QBITTORRENT_PORT=8080
ENV QBITTORRENT_USER=admin
ENV QBITTORRENT_PASS=adminadmin
ENV HTTP_S=http

# Timing configuration for the script
# Update cycle interval in seconds (can be overridden in the Compose file)
ENV CHECK_INTERVAL=30     
# Timeout (in seconds) for waiting on VPN status changes   
ENV WAIT_TIMEOUT=60      
# Interval (in seconds) between VPN status checks    
ENV WAIT_INTERVAL=5          
ENV CONTROL_SERVER_TIMEOUT=15
ENV CONTROL_SERVER_RETRIES=3
ENV CONTROL_SERVER_RETRY_DELAY=2
ENV QBITTORRENT_TIMEOUT=15

# Control Server URL (used by our script to query the forwarded port and VPN status)
ENV CONTROL_SERVER_URL=http://gluetun:8000

# VPN mode (Options: SMARTMODE or DUMPMODE)
ENV VPNMODE=SMARTMODE

# Copy the start.sh script into the container and make it executable
COPY ./start.sh /start.sh
COPY ./healthcheck.sh /healthcheck.sh
RUN chmod +x /start.sh /healthcheck.sh

HEALTHCHECK --interval=30s --timeout=10s --start-period=20s --retries=3 CMD ["/healthcheck.sh"]

# Command to run the script
CMD ["/start.sh"]
