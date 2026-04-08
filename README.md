# CloudLab configurable-node BFT profile

This directory contains a repository-based CloudLab profile for running a BFT experiment on a configurable number of `d710` machines.

## Files

- `profile.py`: CloudLab profile entrypoint
- `scripts/bootstrap.sh`: runs on each node at boot, installs Docker, pulls the image, and starts a container

## What this profile does

When you instantiate the profile, CloudLab allocates `num_nodes` physical nodes.

Nodes are named `node0`, `node1`, `node2`, and so on.

Their private LAN addresses are assigned as:

- `node0` -> `10.10.1.1`
- `node1` -> `10.10.1.2`
- `node2` -> `10.10.1.3`
- ...

Each node will:

1. install Docker if needed
2. optionally log into Docker Hub
3. pull the image you specify
4. start one container with:
   - `NODE_INDEX`
   - `NODE_IP`
   - `PEERS_CSV`
   - `TOTAL_NODES`

If `mount_repository=true`, the CloudLab repository checkout is mounted into the container at `/workspace`.

## Your private Docker image

The default image is already set to:

```text
shaokangxie/oesdk_resdb:2024_11_17
```

Because it is private, you should provide Docker Hub credentials when instantiating the profile.

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
- `dockerhub_user`: your Docker Hub username
- `dockerhub_token`: the personal access token you just created

Example `docker_cmd` values:

```sh
sleep infinity
```

```sh
cd /workspace && ./scripts/run_bft.sh
```

## How to verify after startup

SSH into a node and run:

```sh
docker ps
sudo cat /var/log/bft-bootstrap.log
docker logs bft-node-0
```

On other machines, the container names continue as `bft-node-1`, `bft-node-2`, and so on.

## Security note

CloudLab hidden parameters are better than hard-coding secrets in Git, but they are still operational credentials that should be short-lived and scoped minimally. The safest pattern is:

- use a short-lived Docker Hub PAT
- give it the smallest possible scope
- delete or disable it after the experiment
