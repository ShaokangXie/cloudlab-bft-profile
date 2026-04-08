#!/usr/bin/env bash
set -euo pipefail

exec > >(tee -a /var/log/bft-bootstrap.log) 2>&1

NODE_INDEX="${1:?missing NODE_INDEX}"
TOTAL_NODES="${2:?missing TOTAL_NODES}"
NODE_IP="${3:?missing NODE_IP}"
PEERS_CSV="${4:?missing PEERS_CSV}"
DOCKER_IMAGE="${5:?missing DOCKER_IMAGE}"
CONTAINER_NAME="${6:?missing CONTAINER_NAME}"
MOUNT_REPOSITORY="${7:?missing MOUNT_REPOSITORY}"
DOCKER_CMD="${8:-sleep infinity}"
DOCKERHUB_USER="${9:-}"
DOCKERHUB_TOKEN="${10:-}"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
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
  docker logout >/dev/null 2>&1 || true
  rm -f /root/.docker/config.json || true
}

install_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    retry apt-get update
    retry apt-get install -y docker.io
  fi

  systemctl enable docker
  systemctl restart docker

  for _ in $(seq 1 30); do
    if docker info >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  docker info >/dev/null 2>&1
}

docker_login_if_needed() {
  if [ -n "${DOCKERHUB_USER}" ] && [ -n "${DOCKERHUB_TOKEN}" ]; then
    log "Logging into Docker Hub for private image access"
    mkdir -p /root/.docker
    printf '%s' "${DOCKERHUB_TOKEN}" | docker login -u "${DOCKERHUB_USER}" --password-stdin >/dev/null
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
    --network host
    -e NODE_INDEX="${NODE_INDEX}"
    -e NODE_IP="${NODE_IP}"
    -e PEERS_CSV="${PEERS_CSV}"
    -e TOTAL_NODES="${TOTAL_NODES}"
  )

  if [ "${MOUNT_REPOSITORY}" = "1" ]; then
    docker_run_args+=(-v /local/repository:/workspace)
  fi

  docker run \
    "${docker_run_args[@]}" \
    "${DOCKER_IMAGE}" \
    /bin/sh -lc "${DOCKER_CMD}"
}

log "Bootstrap starting on node index ${NODE_INDEX} (${NODE_IP})"
install_docker
docker_login_if_needed
retry docker pull "${DOCKER_IMAGE}"
docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
start_container
docker ps
log "Bootstrap completed for ${CONTAINER_NAME}"
