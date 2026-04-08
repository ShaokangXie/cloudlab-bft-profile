# CloudLab configurable-node BFT profile

This directory contains a repository-based CloudLab profile for running a BFT experiment on a configurable number of CloudLab machines.

## Files

- `profile.py`: CloudLab profile entrypoint
- `scripts/bootstrap.sh`: runs on each node at boot, installs Docker, pulls the image, and starts a container

The profile uses a direct CloudLab `Execute` startup service to invoke `scripts/bootstrap.sh` on each node.

## What this profile does

When you instantiate the profile, CloudLab allocates `num_nodes` physical nodes.

Nodes are named `node0`, `node1`, `node2`, and so on.

Their private LAN addresses are assigned as:

- `node0` -> `10.10.1.1`
- `node1` -> `10.10.1.2`
- `node2` -> `10.10.1.3`
- ...

Each node will:

1. run the bootstrap script during startup
2. install Docker if needed
3. install a host-side `systemd` unit so the same bootstrap logic runs again after host reboot
4. optionally log into Docker Hub
5. pull the image you specify
6. start one container with:
   - `NODE_INDEX`
   - `NODE_IP`
   - `PEERS_CSV`
   - `TOTAL_NODES`

By default the container runs in Docker `host` mode.

The bootstrap script also starts `sshd` inside the container and installs the configured public key into `root`'s `authorized_keys`.

This means:

- SSH to host port `22` reaches the host itself
- SSH to host port `2222` reaches the container

If `mount_repository=true`, the CloudLab repository checkout is mounted into the container at `/workspace`.

## Your private Docker image

The default image is already set to:

```text
shaokangxie/oesdk_resdb:2024_11_17
```

Because it is private, you should provide Docker Hub credentials when instantiating the profile.

To keep the startup path reliable, the profile passes `dockerhub_user` and `dockerhub_token` directly to the bootstrap command that CloudLab executes on the node. That means the token can appear in generated manifests or spew logs for the experiment, so you should use a short-lived token and revoke it after the run.

## How to create a Docker Hub access token

I cannot generate the token on your behalf because it is tied to your Docker Hub account and is only shown once by Docker. You need to create it in the Docker web UI, then paste it into CloudLab when you instantiate the profile.

According to Docker's current docs, create a Personal Access Token here:

- Docker docs: https://docs.docker.com/docker-hub/access-tokens/

Current Docker flow:

1. Sign in to Docker Hub / Docker Home.
2. Open `Account settings`.
3. Open `Personal access tokens`.
4. Click `Generate new token`.
5. Give it a short description like `cloudlab-private-pull`.
6. Set a short expiration date.
7. Choose the minimum permissions you need.

For this use case, a read-only token is the right choice if Docker offers a read-only scope for your account tier. You only need pull access, not push access.

Important:

- Copy the token immediately when Docker shows it.
- Docker does not let you retrieve the full token later.
- Treat it like a password.

## How to use this in CloudLab

Put this directory into its own Git repository, then create a repository-based profile in CloudLab using `profile.py` as the entry file.

At instantiate time, fill in:

- `num_nodes`: how many nodes you want to allocate
- `docker_image`: `shaokangxie/oesdk_resdb:2024_11_17`
- `docker_cmd`: your container start command
- `docker_network_mode`: `host` by default; use `bridge` only if you specifically want Docker port publishing
- `container_ssh_host_port`: `2222` by default, or `0` to disable container SSH setup
- `container_published_ports`: optional extra mappings like `8080:8080,9000:9000`
- `dockerhub_user`: your Docker Hub username
- `dockerhub_token`: the personal access token you just created; this is passed to the bootstrap command at startup

Example `docker_cmd` values:

```sh
sleep infinity
```

```sh
cd /workspace && ./scripts/run_bft.sh
```

If your BFT service also needs inbound ports from other nodes, add them to `container_published_ports`. For example:

```sh
8080:8080,10000:10000
```

With the default `docker_network_mode=host`, the container shares the host network namespace, so the container's `sshd` listens directly on host port `2222`. If you switch to `bridge`, the profile falls back to Docker's `-p 2222:22` mapping.

The host also gets a `systemd` unit named like `bft-bootstrap-bft-node-0.service`. On reboot, that unit reruns the bootstrap script so Docker, the container, and container SSH come back automatically.

## How to verify after startup

SSH into a node and run:

```sh
sudo docker ps
cat /tmp/bft-bootstrap.log
sudo docker logs bft-node-0
ssh -p 2222 localhost
```

On other machines, the container names continue as `bft-node-1`, `bft-node-2`, and so on.

## Security note

This profile now favors a startup path that is known to execute reliably on the testbed. The tradeoff is that Docker Hub credentials may be visible in experiment control-plane artifacts. The safest pattern is:

- use a short-lived Docker Hub PAT
- give it the smallest possible scope
- delete or disable it after the experiment
