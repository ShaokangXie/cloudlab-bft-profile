"""CloudLab repository-based profile for a configurable-node BFT experiment.

Each node:
- joins the same private LAN
- runs the bootstrap script during startup
- optionally logs into Docker Hub for private image access
- pulls the requested image
- starts one container with node-specific environment variables
"""

import geni.portal as portal
import geni.rspec.pg as rspec
import shlex


pc = portal.Context()

pc.defineParameter(
    "num_nodes",
    "Number of nodes to allocate",
    portal.ParameterType.INTEGER,
    3,
)

pc.defineParameter(
    "docker_image",
    "Docker image to run on each node",
    portal.ParameterType.STRING,
    "shaokangxie/oesdk_resdb:2024_11_17",
)

pc.defineParameter(
    "docker_cmd",
    "Command to run inside the container",
    portal.ParameterType.STRING,
    "sleep infinity",
)

pc.defineParameter(
    "container_prefix",
    "Container name prefix",
    portal.ParameterType.STRING,
    "bft-node",
)

pc.defineParameter(
    "mount_repository",
    "Mount /local/repository into the container as /workspace",
    portal.ParameterType.BOOLEAN,
    True,
)

pc.defineParameter(
    "hardware_type",
    "CloudLab hardware type",
    portal.ParameterType.STRING,
    "d710",
)

pc.defineParameter(
    "docker_network_mode",
    "Docker network mode: bridge or host",
    portal.ParameterType.STRING,
    "bridge",
)

pc.defineParameter(
    "container_ssh_host_port",
    "Host port forwarded to container port 22; set 0 to disable",
    portal.ParameterType.INTEGER,
    2222,
)

pc.defineParameter(
    "container_published_ports",
    "Extra published ports in host:container form, comma-separated",
    portal.ParameterType.STRING,
    "",
)

pc.defineParameter(
    "dockerhub_user",
    "Docker Hub username for private image pulls",
    portal.ParameterType.STRING,
    "",
    advanced=True,
)

pc.defineParameter(
    "dockerhub_token",
    "Docker Hub personal access token for private image pulls",
    portal.ParameterType.STRING,
    "",
    advanced=True,
    hide=True,
)

params = pc.bindParameters()

if params.num_nodes < 1:
    pc.reportError(
        portal.ParameterError("num_nodes must be at least 1", ["num_nodes"])
    )

if params.num_nodes > 250:
    pc.reportError(
        portal.ParameterError(
            "num_nodes must be 250 or less so static IP allocation stays valid",
            ["num_nodes"],
        )
    )

if params.docker_network_mode not in ["bridge", "host"]:
    pc.reportError(
        portal.ParameterError(
            "docker_network_mode must be either bridge or host",
            ["docker_network_mode"],
        )
    )

if bool(params.dockerhub_user) != bool(params.dockerhub_token):
    pc.reportError(
        portal.ParameterError(
            "Provide both dockerhub_user and dockerhub_token, or leave both empty",
            ["dockerhub_user", "dockerhub_token"],
        )
    )

pc.verifyParameters()

request = pc.makeRequestRSpec()

lan = request.LAN("bft-lan")

node_ips = ["10.10.1.{}".format(i + 1) for i in range(params.num_nodes)]
all_peers = ",".join(node_ips)


def build_bootstrap_command(node_index, node_ip):
    args = [
        str(node_index),
        str(params.num_nodes),
        node_ip,
        all_peers,
        params.docker_image,
        "{}-{}".format(params.container_prefix, node_index),
        "1" if params.mount_repository else "0",
        params.docker_cmd,
        params.docker_network_mode,
        str(params.container_ssh_host_port),
        params.container_published_ports,
        params.dockerhub_user,
        params.dockerhub_token,
    ]
    quoted_args = " ".join(shlex.quote(arg) for arg in args)
    return (
        "for _ in $(seq 1 60); do "
        "if [ -f /local/repository/scripts/bootstrap.sh ]; then break; fi; "
        "sleep 2; "
        "done; "
        "[ -f /local/repository/scripts/bootstrap.sh ] || "
        "{ echo 'bootstrap.sh was not cloned to /local/repository' >&2; exit 1; }; "
        "/bin/bash /local/repository/scripts/bootstrap.sh {}".format(quoted_args)
    )

for i in range(params.num_nodes):
    node = request.RawPC("node{}".format(i))
    node.hardware_type = params.hardware_type
    node.disk_image = (
        "urn:publicid:IDN+emulab.net+image+emulab-ops//UBUNTU22-64-STD"
    )

    iface = node.addInterface("if0")
    iface.addAddress(rspec.IPv4Address(node_ips[i], "255.255.255.0"))
    lan.addInterface(iface)

    node.addService(
        rspec.Execute(
            shell="/bin/bash",
            command=build_bootstrap_command(i, node_ips[i]),
        )
    )

pc.printRequestRSpec(request)
