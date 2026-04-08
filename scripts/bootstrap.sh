#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="${BOOTSTRAP_LOG_FILE:-/tmp/bft-bootstrap.log}"
exec > >(tee -a "${LOG_FILE}") 2>&1

NODE_INDEX="${1:?missing NODE_INDEX}"
TOTAL_NODES="${2:?missing TOTAL_NODES}"
NODE_IP="${3:?missing NODE_IP}"
PEERS_CSV="${4:?missing PEERS_CSV}"
DOCKER_IMAGE="${5:?missing DOCKER_IMAGE}"
CONTAINER_NAME="${6:?missing CONTAINER_NAME}"
MOUNT_REPOSITORY="${7:?missing MOUNT_REPOSITORY}"
DOCKER_CMD="${8:-sleep infinity}"
DOCKER_NETWORK_MODE="${9:-bridge}"
CONTAINER_SSH_PORT="${10:-2222}"
CONTAINER_PUBLISHED_PORTS="${11:-}"
CLI_DOCKERHUB_USER="${12:-}"
CLI_DOCKERHUB_TOKEN="${13:-}"
DOCKERHUB_USER="${CLI_DOCKERHUB_USER:-${DOCKERHUB_USER:-}}"
DOCKERHUB_TOKEN="${CLI_DOCKERHUB_TOKEN:-${DOCKERHUB_TOKEN:-}}"
AUTHORIZED_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAID7Nv8mMG9bCbPZZwpxCarBfHAwhwJmMzxxD0VMyS2rB shaokang@Shaokangs-MacBook-Pro.local"

if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  SUDO="sudo"
fi

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

service_name() {
  printf 'bft-bootstrap-%s.service' "${CONTAINER_NAME}"
}

retry() {
  local attempts=0
  until "$@"; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 5 ]; then
      log "Command failed after ${attempts} attempts: $*"
      return 1
    fi
    sleep 10
  done
}

cleanup_docker_auth() {
  ${SUDO} docker logout >/dev/null 2>&1 || true
  ${SUDO} rm -f /root/.docker/config.json || true
}

install_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    retry ${SUDO} apt-get update
    retry ${SUDO} apt-get install -y docker.io
  fi

  ${SUDO} systemctl enable docker
  ${SUDO} systemctl restart docker

  for _ in $(seq 1 30); do
    if ${SUDO} docker info >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  ${SUDO} docker info >/dev/null 2>&1
}

docker_login_if_needed() {
  if [ -n "${DOCKERHUB_USER}" ] && [ -n "${DOCKERHUB_TOKEN}" ]; then
    log "Logging into Docker Hub for private image access"
    ${SUDO} mkdir -p /root/.docker
    printf '%s' "${DOCKERHUB_TOKEN}" | ${SUDO} docker login -u "${DOCKERHUB_USER}" --password-stdin >/dev/null
    trap cleanup_docker_auth EXIT
  else
    log "No Docker Hub credentials provided; attempting anonymous pull"
  fi
}

start_container() {
  local -a docker_run_args
  docker_run_args=(
    -d
    --name "${CONTAINER_NAME}"
    --hostname "${CONTAINER_NAME}"
    --restart unless-stopped
    -e NODE_INDEX="${NODE_INDEX}"
    -e NODE_IP="${NODE_IP}"
    -e PEERS_CSV="${PEERS_CSV}"
    -e TOTAL_NODES="${TOTAL_NODES}"
  )

  if [ "${DOCKER_NETWORK_MODE}" = "host" ]; then
    docker_run_args+=(--network host)
    if [ "${CONTAINER_SSH_PORT}" != "0" ]; then
      log "docker_network_mode=host; container SSH will listen directly on port ${CONTAINER_SSH_PORT}"
    fi
  else
    docker_run_args+=(--network bridge)

    if [ -n "${CONTAINER_PUBLISHED_PORTS}" ]; then
      local old_ifs="${IFS}"
      IFS=','
      read -r -a published_ports <<< "${CONTAINER_PUBLISHED_PORTS}"
      IFS="${old_ifs}"
      local published_port
      for published_port in "${published_ports[@]}"; do
        if [ -n "${published_port}" ]; then
          docker_run_args+=(-p "${published_port}")
        fi
      done
    fi
  fi

  if [ "${MOUNT_REPOSITORY}" = "1" ]; then
    docker_run_args+=(-v /local/repository:/workspace)
  fi

  ${SUDO} docker run \
    "${docker_run_args[@]}" \
    "${DOCKER_IMAGE}" \
    /bin/sh -lc "${DOCKER_CMD}"
}

configure_container_ssh() {
  local ssh_port="$1"
  local escaped_authorized_key
  escaped_authorized_key=$(printf "%s" "${AUTHORIZED_KEY}" | sed "s/'/'\"'\"'/g")
  local started=0

  if [ "${CONTAINER_SSH_PORT}" = "0" ]; then
    log "Container SSH setup disabled because container_ssh_host_port=0"
    return 0
  fi

  if ! ${SUDO} docker exec "${CONTAINER_NAME}" sh -lc "command -v sshd >/dev/null 2>&1"; then
    log "sshd is not installed in ${CONTAINER_NAME}; skipping SSH setup"
    return 0
  fi

  log "Configuring container SSH on port ${ssh_port}"
  retry ${SUDO} docker exec "${CONTAINER_NAME}" sh -lc "mkdir -p /run/sshd /root/.ssh && chmod 700 /root/.ssh && touch /root/.ssh/authorized_keys"
  ${SUDO} docker exec "${CONTAINER_NAME}" sh -lc "grep -qxF '${escaped_authorized_key}' /root/.ssh/authorized_keys 2>/dev/null || printf '%s\n' '${escaped_authorized_key}' >> /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys"
  ${SUDO} docker exec "${CONTAINER_NAME}" sh -lc "ssh-keygen -A >/dev/null 2>&1 || true"
  ${SUDO} docker exec "${CONTAINER_NAME}" sh -lc "pkill -f '/usr/sbin/sshd -D' >/dev/null 2>&1 || true"

  # Starting sshd via `docker exec -d` proved flaky during CloudLab startup.
  # Let the container shell background it directly, then wait for the port.
  ${SUDO} docker exec "${CONTAINER_NAME}" sh -lc "(/usr/sbin/sshd -D -e -p '${ssh_port}' >/tmp/container-sshd.log 2>&1 &)"

  for _ in $(seq 1 15); do
    if ${SUDO} docker exec "${CONTAINER_NAME}" sh -lc "ps -ef | grep '[s]shd: /usr/sbin/sshd -D -e -p ${ssh_port}' >/dev/null"; then
      started=1
      break
    fi
    sleep 1
  done

  if [ "${started}" -ne 1 ]; then
    log "Container SSH failed to stay up on port ${ssh_port}"
    ${SUDO} docker exec "${CONTAINER_NAME}" sh -lc "tail -n 50 /tmp/container-sshd.log 2>/dev/null || true"
    return 1
  fi

  log "Container SSH started on port ${ssh_port}"
}

install_boot_service() {
  local wrapper_path="/usr/local/sbin/bft-bootstrap-${CONTAINER_NAME}.sh"
  local unit_path="/etc/systemd/system/$(service_name)"

  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf 'exec /bin/bash /local/repository/scripts/bootstrap.sh'
    printf ' %q' "${NODE_INDEX}"
    printf ' %q' "${TOTAL_NODES}"
    printf ' %q' "${NODE_IP}"
    printf ' %q' "${PEERS_CSV}"
    printf ' %q' "${DOCKER_IMAGE}"
    printf ' %q' "${CONTAINER_NAME}"
    printf ' %q' "${MOUNT_REPOSITORY}"
    printf ' %q' "${DOCKER_CMD}"
    printf ' %q' "${DOCKER_NETWORK_MODE}"
    printf ' %q' "${CONTAINER_SSH_PORT}"
    printf ' %q' "${CONTAINER_PUBLISHED_PORTS}"
    printf ' %q' "${DOCKERHUB_USER}"
    printf ' %q' "${DOCKERHUB_TOKEN}"
    printf '\n'
  } | ${SUDO} tee "${wrapper_path}" >/dev/null
  ${SUDO} chmod 700 "${wrapper_path}"

  cat <<EOF | ${SUDO} tee "${unit_path}" >/dev/null
[Unit]
Description=Bootstrap ${CONTAINER_NAME} on boot
After=local-fs.target network-online.target docker.service
Wants=network-online.target docker.service

[Service]
Type=oneshot
ExecStart=${wrapper_path}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  ${SUDO} systemctl daemon-reload
  ${SUDO} systemctl enable "$(service_name)"
  log "Installed boot service $(service_name)"
}

log "Bootstrap starting on node index ${NODE_INDEX} (${NODE_IP})"
install_docker
install_boot_service
docker_login_if_needed
retry ${SUDO} docker pull "${DOCKER_IMAGE}"
${SUDO} docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
start_container
configure_container_ssh "${CONTAINER_SSH_PORT}"
${SUDO} docker ps
log "Bootstrap completed for ${CONTAINER_NAME}"
