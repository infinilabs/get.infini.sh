<p align="center">
<a href="https://infinilabs.com/"><img src="docs/images/infinilabs.svg" alt="INFINI Labs Logo" width="200px"></a>
</p>

<p align="center">
<strong>Utilities for rapid local setup and direct installation of INFINI Labs products.</strong>
</p>

# INFINI Labs - Local Setup & Installation Utilities

> **English** | [中文 (Chinese)](README_zh.md)

This repository provides utilities to quickly set up and install INFINI Labs products for local development, testing, or direct host installation.

It offers two main functionalities:

1. **Run via Docker (Recommended for Dev/Test)**: Use `start-local.sh` to quickly spin up INFINI Console and INFINI Easysearch in Docker containers with persistent storage. Ideal for isolated testing and development.
2. **Direct Host Installation**: Use `get.infini.cloud` (aliased via `https://get.infini.cloud`) to download and install INFINI products directly onto your host machine (Linux/macOS).

---

## 🐳 Method 1: Run INFINI Console & Easysearch via Docker (`start-local.sh`)

This method uses Docker and Docker Compose to create a local, persistent environment for INFINI Console and INFINI Easysearch. It's perfect for development, testing features, and quick demonstrations without affecting your host system directly.

### Features

* **One-Command Setup**: Quickly start Console and Easysearch.
* **Persistent Storage**: Configurations, data, and logs are saved locally (default: `./startlocal` directory), surviving container restarts.
* **Version Control**: Specify image versions for Console and Easysearch.
* **Configurable**: Set Easysearch nodes, initial passwords, and optional metrics collection.
* **Cross-Platform**: Designed for Linux and macOS. For Windows, use [WSL](https://learn.microsoft.com/en-us/windows/wsl/install).
* **Easy Cleanup**: A `clean` command removes all related Docker resources and local data.

### Quick Start (Docker Method)

Execute the script directly via `curl`. This always fetches the latest version of `start-local.sh`.

```bash
# Start default setup (INFINI Console + 1 INFINI Easysearch node)
curl -fsSL https://get.infini.cloud/start-local.sh | sh -s -- up

# Example: Start with 3 Easysearch nodes, custom password, and enable metrics
curl -fsSL https://get.infini.cloud/start-local.sh | sh -s -- up --nodes 3 --password "MySecurePass123!" --metrics-agent
```

After execution, a working directory (default: `./startlocal`) will be created containing:
* `.env`: Environment configuration file.
* `docker-compose.yml`: Dynamically generated Docker Compose file.
* `console/`: Subdirectories for Console's persistent config, data, and logs.
* `easysearch/`: Subdirectories for Easysearch's persistent config, data, and logs.

### `start-local.sh` Commands and Options

**Main Commands:**

* `up`: Creates and starts services. Copies initial configs from images if local config dirs are missing.
* `down`: Stops services, removes containers, networks, and associated anonymous volumes. Persisted data in `${WORK_DIR}` remains.
* `logs [SERVICE_NAMES...]`: Follows logs for specified services (or all if none specified).
* `clean`: **Full cleanup**. Performs `down`, then removes the entire working directory (`${WORK_DIR}`).
* `help`: Displays help message.

**Options (mainly for `up` command):**

* `-cv TAG`, `--console-version TAG`: INFINI Console image tag (e.g., `1.29.6`). Defaults to latest stable or a predefined version.
* `-ev TAG`, `--easysearch-version TAG`: INFINI Easysearch image tag (e.g., `1.13.0`). Defaults accordingly.
* `-n N`, `--nodes N`: Number of Easysearch nodes (default: 1).
* `-p PASSWORD`, `--password PASSWORD`: Initial admin password for Easysearch (default: `ShouldChangeme123!`). **Change this!**
* `--services s1[,s2,...]`: Comma-separated services to start with `up` (e.g., `console,easysearch`). Or list after `up` command. Defaults to `console easysearch`.
* `--metrics-agent`: Enables Easysearch metrics collection. `METRICS_CONFIG_SERVER` auto-sets to internal Console.
* `-wd PATH`, `--work-dir PATH`: Custom working directory for operational files and data (default: `./startlocal`).
* `-h`, `--help`: Shows help message.

### Accessing Services (Docker Method)

* **INFINI Console**: Typically at `http://localhost:9000` (check script output for exact port).
* **INFINI Easysearch**:
* HTTP API: Typically at `http://localhost:9200`.
* Default user: `admin`, Password: As set via `-p` or the default.

Refer to the script's `help` command or output for detailed port information.

---

## 💻 Method 2: Direct Host Installation (`get.infini.cloud`)

This method installs INFINI products (Console, Gateway, Easysearch, Loadgen, etc.) directly onto your Linux or macOS host system.

### Prerequisites

* Ensure the current user has **write permissions** for the target installation directory. If installing to system-wide locations like `/opt/`, `sudo` might be required for directory creation and ownership changes initially.
* `curl` and `bash` (or a compatible shell).

### Installation Examples

The installation script is fetched from `https://get.infini.cloud` (this should be the URL for your host installer script).

```bash
# Ensure the current operator user has permission to the installation directory.
# Example: initialize a common installation directory for Console
# sudo mkdir -p /opt/console && sudo chown -R ${USER}:${GROUPS[0]} /opt/console
# (Note: ${GROUPS[0]} might not be portable, consider just ${USER} or a specific group)

# Install Console (latest version) to default or pre-prepared directory
curl -sSL https://get.infini.cloud | bash -s -- -p console

# Install Gateway (latest version) and specify installation directory
curl -sSL https://get.infini.cloud | bash -s -- -p gateway -d /opt/gateway

# Install Loadgen (latest version) to a relative directory in the current path
curl -sSL https://get.infini.cloud | bash -s -- -p loadgen -d loadgen_files

# Install Easysearch, specifying installation directory and version
curl -sSL https://get.infini.cloud | bash -s -- -p easysearch -d /data/my_easysearch -v 1.13.0
```

### Host Installer Script Options (`get.infini.cloud`)


* `-p <product_name>`: **Required**. Specifies the product to install (e.g., `console`, `gateway`, `easysearch`, `loadgen`, `agent`, `coco/app`, `coco/server`).
* `-d <directory_path>`: Optional. Specifies the target installation directory. If not provided, the script might use a default location or install relative to the current directory.
* `-v <version>`: Optional. Specifies the version of the product to install. If not provided, installs the latest stable version.

### Managing Host Installations

After installation, each product will typically have its own `bin/` directory with scripts to start, stop, and manage the service. Please refer to the specific product's documentation for details on management and configuration.

---

## 📝 Diagnostics & Logging

* **`start-local.sh` (Docker method)**: If an error occurs during `up`, a diagnostic log `start-local-error.log` is typically created in the working directory (`./startlocal` by default) containing system info and relevant Docker logs.
* **`get.infini.cloud` (Host install method)**: Just go to the corresponding log directory to view it

## 🤝 Contributing & Feedback

We welcome contributions and feedback! Please feel free to open Issues or Pull Requests.
