<p align="center">
<a href="https://infinilabs.com/"><img src="docs/images/infinilabs.svg" alt="INFINI Labs Logo" width="200px"></a>
</p>

<p align="center">
<strong>为 INFINI Labs 产品提供快速本地搭建与直接安装的实用工具集。</strong>
</p>

# INFINI Labs - 本地安装与设置工具

> [English (英文)](README.md) | **中文**

本仓库提供实用工具，帮助您快速搭建和安装 INFINI Labs 产品，用于本地开发、测试或直接主机部署。

主要提供两种功能：

1. **通过 Docker 运行 (推荐用于开发/测试)**: 使用 `start-local.sh` 脚本，通过 Docker 容器快速启动 INFINI Console 和 INFINI Easysearch，并配置持久化存储。非常适合隔离的测试和开发环境。
2. **直接主机安装**: 使用 `get.infini.cloud` (通过 `https://get.infini.cloud` 访问) 将 INFINI 产品直接下载并安装到您的宿主机 (Linux/macOS) 上。

---

## 🐳 方法一：通过 Docker 运行 INFINI Console 和 Easysearch (`start-local.sh`)

此方法使用 Docker 和 Docker Compose 创建一个本地的、持久化的 INFINI Console 和 INFINI Easysearch 环境。它非常适合开发、功能测试以及快速演示，而不会直接影响您的宿主系统。

### ✨ 特性

* **一键启动**: 快速启动 Console 和 Easysearch。
* **持久化存储**: 配置、数据和日志都将保存在本地（默认为 `./startlocal` 目录），容器重启后依然存在。
* **版本控制**: 支持指定 Console 和 Easysearch 的镜像版本。
* **可配置性**: 支持配置 Easysearch 节点数、初始密码以及可选的指标收集。
* **跨平台**: 为 Linux 和 macOS 设计。对于 Windows 用户，请使用 [WSL](https://learn.microsoft.com/zh-cn/windows/wsl/install)。
* **易于清理**: 提供 `clean` 命令，可彻底移除所有相关的 Docker 资源和本地数据。

### 🚀 快速开始 (Docker 方式)

直接通过 `curl` 执行脚本。这将始终获取最新版本的 `start-local.sh`。

```bash
# 启动默认配置 (INFINI Console + 1个 INFINI Easysearch 节点)
curl -fsSL https://get.infini.cloud/start-local.sh | sh -s -- up

# 示例：启动3个 Easysearch 节点，自定义密码，并开启指标收集
curl -fsSL https://get.infini.cloud/start-local.sh | sh -s -- up --nodes 3 --password "MySecurePass123." --metrics-agent
```

脚本执行后，将在当前目录下创建一个工作目录（默认为 `./startlocal`），其中包含：
* `.env`: 环境变量配置文件。
* `docker-compose.yml`: 动态生成的 Docker Compose 文件。
* `console/`: Console 持久化配置、数据和日志的子目录。
* `easysearch/`: Easysearch 持久化配置、数据和日志的子目录。

### `start-local.sh` 命令与选项

**主要命令:**

* `up`: 创建并启动服务。如果本地持久化目录中的 `config` 子目录不存在，会从镜像中复制初始配置。
* `down`: 停止服务，移除容器、网络和关联的匿名卷。`${WORK_DIR}` 下的持久化数据和配置文件**不会**被删除。
* `logs [服务名...]`: 实时跟踪指定服务（如果未指定则查看所有服务）的日志输出。按 `Ctrl+C` 停止查看。
* `clean`: **彻底清理**。执行 `down`，然后删除整个工作目录 (`${WORK_DIR}`)，包括所有数据和配置。
* `help`: 显示帮助信息。

**选项 (主要用于 `up` 命令):**

* `-cv TAG`, `--console-version TAG`: INFINI Console 镜像标签 (例如 `1.29.6`)。默认为最新稳定版或预定义版本。
* `-ev TAG`, `--easysearch-version TAG`: INFINI Easysearch 镜像标签 (例如 `1.13.0`)。默认为最新稳定版或预定义版本。
* `-n N`, `--nodes N`: Easysearch 节点数量 (默认: 1)。
* `-p PASSWORD`, `--password PASSWORD`: Easysearch `admin` 用户初始密码 (默认: `ShouldChangeme123.`)。**请务必修改！**
* `--services s1[,s2,...]`: 指定 `up` 命令启动的服务 (例如 `console,easysearch`)。也可在 `up`后直接列出。默认启动 `console easysearch`。
* `--metrics-agent`: 启用 Agent 指标收集。`METRICS_CONFIG_SERVER` 将自动设为内部 Console 地址。
* `-wd PATH`, `--work-dir PATH`: 自定义工作目录，用于存放操作文件和持久化数据 (默认: `./startlocal`)。
* `-h`, `--help`: 显示帮助信息。

### 访问服务 (Docker 方式)

* **INFINI Console**: 访问 `http://localhost:9000` 。
* **INFINI Easysearch**:
* HTTP API: 通常在 `http://localhost:9200`。
* 默认用户: `admin`, 密码: 通过 `-p` 设置的密码或默认密码。

详细端口信息请参考脚本的 `help` 命令或其输出。

---

## 💻 方法二：直接主机安装 (`get.infini.cloud`)

此方法将 INFINI 产品（Console, Gateway, Easysearch, Loadgen 等）直接安装到您的 Linux 或 macOS 宿主机系统上。

### 前提条件

* 确保当前用户对目标安装目录拥有**写入权限**。默认安装到 `/opt` 系统级位置，初始创建目录和更改所有权可能需要 `sudo`。
* 已安装 `curl` 和 `bash` (或兼容的 shell)。

### 安装示例

安装脚本从 `https://get.infini.cloud` 获取。

```bash
# 确保当前操作用户对安装目录有权限。
# 例如：为 Console 初始化一个通用的安装目录
# sudo mkdir -p /opt/console && sudo chown -R ${USER} /opt/console

# 安装 Console (最新版)到默认或预先准备好的目录
curl -sSL https://get.infini.cloud | bash -s -- -p console

# 安装 Gateway (最新版) 并指定安装目录
curl -sSL https://get.infini.cloud | bash -s -- -p gateway -d /opt/gateway

# 安装 Loadgen (最新版) 到当前路径下的相对目录
curl -sSL https://get.infini.cloud | bash -s -- -p loadgen -d loadgen_files

# 安装 Easysearch，并指定安装目录和版本
curl -sSL https://get.infini.cloud | bash -s -- -p easysearch -d /data/my_easysearch -v 1.13.0
```

### 主机安装脚本选项 (`get.infini.cloud`)

* `-p <产品名称>`: **必需**。指定要安装的产品 (例如 `console`, `gateway`, `easysearch`, `loadgen`, `agent`, `coco/app`, `coco/server`)。
* `-d <目录路径>`: 可选。指定目标安装目录。如果未提供，脚本可能使用默认位置或相对于当前目录安装。
* `-v <版本号>`: 可选。指定要安装的产品版本。如果未提供，则安装最新的稳定版本。

### 管理主机安装

安装完成后，每个产品通常会在其安装目录的 `bin/` 子目录下提供用于启动、停止和管理服务的脚本。请参考具体产品的官方文档以获取管理和配置的详细信息。

---

## 📝 诊断与日志

* **`start-local.sh` (Docker 方式)**: 如果在执行 `up` 命令时发生错误，通常会在工作目录（默认为 `./startlocal`）下创建一个名为 `start-local-error.log` 的诊断日志文件，其中包含系统信息和相关的 Docker 日志。
* **`get.infini.cloud` (主机安装方式)**: 直接进入相应的日志目录查看即可。

## 🤝 贡献与反馈

我们欢迎各种贡献和反馈！请随时通过 Issues 或 Pull Requests 提出问题、报告错误或贡献代码。
