#!/usr/bin/env bash
set -Eeuo pipefail

# GRFICSv3 Ubuntu installer
# Installs Docker Engine (if missing), downloads the official GRFICSv3 Compose file,
# adjusts macvlan parent interfaces to the default-route interface, pulls images,
# and starts the lab.

INSTALL_DIR="${GRFICS_INSTALL_DIR:-/opt/grficsv3}"
REPO_URL="https://raw.githubusercontent.com/Fortiphyd/GRFICSv3/main/docker-compose.yml"
DOCKER_KEYRING="/etc/apt/keyrings"
DOCKER_SOURCE="/etc/apt/sources.list.d/docker.sources"

log() { printf '\n[GRFICSv3] %s\n' "$*"; }
die() { printf '\n[GRFICSv3] ERROR: %s\n' "$*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "Run as root, for example: curl -fsSL <SCRIPT_URL> | sudo bash"
[[ -r /etc/os-release ]] || die "Cannot identify operating system."
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || die "This installer supports Ubuntu only. Detected: ${PRETTY_NAME:-unknown}."
[[ "$(dpkg --print-architecture)" == "amd64" || "$(dpkg --print-architecture)" == "arm64" ]] || die "Unsupported architecture: $(dpkg --print-architecture)."

if ! command -v curl >/dev/null 2>&1; then
  log "Installing curl and CA certificates"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl
fi

# Select the interface used for the default route; macvlan definitions in the
# upstream Compose file use eth0 by default, which is not universal on Ubuntu.
HOST_IFACE="$(ip -o route show default 2>/dev/null | awk 'NR==1 {for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')"
[[ -n "$HOST_IFACE" ]] || die "Could not detect the default-route network interface. Check 'ip route' and retry."
log "Detected host network interface: ${HOST_IFACE}"

if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  log "Installing Docker Engine and the Compose plugin from Docker's official Ubuntu repository"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl
  install -m 0755 -d "$DOCKER_KEYRING"
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "${DOCKER_KEYRING}/docker.asc"
  chmod a+r "${DOCKER_KEYRING}/docker.asc"

  CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
  [[ -n "$CODENAME" ]] || die "Could not determine Ubuntu codename."
  ARCH="$(dpkg --print-architecture)"
  cat > "$DOCKER_SOURCE" <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${CODENAME}
Components: stable
Architectures: ${ARCH}
Signed-By: ${DOCKER_KEYRING}/docker.asc
EOF
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

systemctl enable --now docker
docker info >/dev/null 2>&1 || die "Docker daemon is not responding. Check: systemctl status docker"

log "Checking available disk space"
df -h "$INSTALL_DIR" 2>/dev/null || df -h /

install -d -m 0755 "$INSTALL_DIR"
cd "$INSTALL_DIR"

if [[ -f docker-compose.yml ]]; then
  cp -n docker-compose.yml "docker-compose.yml.backup.$(date +%Y%m%d%H%M%S)" || true
fi

log "Downloading the official GRFICSv3 Compose file"
curl -fL --retry 3 "$REPO_URL" -o docker-compose.yml

# Replace the upstream default interface only in macvlan parent settings.
# Keep the original subnet/IP definitions unchanged.
sed -i -E "s/(parent:[[:space:]]*)eth0/\1${HOST_IFACE}/g" docker-compose.yml

log "Validating Compose configuration"
docker compose -f docker-compose.yml config --quiet

log "Pulling GRFICSv3 images. This may take a while and require substantial disk space."
docker compose -f docker-compose.yml pull

log "Starting GRFICSv3"
docker compose -f docker-compose.yml up -d

log "Container status"
docker compose -f docker-compose.yml ps

cat <<EOF

GRFICSv3 installation commands:
  Project directory: ${INSTALL_DIR}
  Status:            cd ${INSTALL_DIR} && sudo docker compose ps
  Logs:              cd ${INSTALL_DIR} && sudo docker compose logs -f
  Stop:              cd ${INSTALL_DIR} && sudo docker compose stop
  Start:             cd ${INSTALL_DIR} && sudo docker compose start
  Remove containers: cd ${INSTALL_DIR} && sudo docker compose down

Common host-browser URLs:
  Simulation: http://localhost/
  EWS:        http://localhost:6080
  HMI:        http://localhost:6081
  Kali:       http://localhost:6088
  PLC:        http://localhost:8080
  Caldera:    http://localhost:8888

SECURITY NOTICE:
  GRFICSv3 is a deliberately vulnerable training lab. Keep it on an isolated,
  authorized training host/network. Review Docker-published ports and do not
  expose these services directly to the public Internet.
  The installer downloads the upstream Compose file from the Fortiphyd GRFICSv3
  main branch. Review and pin a known-good revision before using at scale.
EOF
