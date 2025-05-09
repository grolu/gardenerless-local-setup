Local kcp Management Script for Gardener Dashboard (gardenerless-setup.sh)

## Introduction

This repository provides a Bash script (`gardenerless-setup.sh`) to simplify the setup and management of a local **kcp** installation for the Gardener Dashboard. It automates workspace and project management, CRD/application of essential resources, and demo environment creation—enabling you to get started quickly with a dedicated, self-contained kcp setup.

> **Note:** This script works with a dedicated kcp directory (`kcp/`) and uses hardcoded kubeconfig paths. All network alias handling (for macOS) is built in—no manual aliasing is required.

---

## Features

* **Dedicated kcp Repository Management**
  Clones or updates the `kcp` repository under `./kcp`, builds the binary, and ensures it’s up to date.

* **Automatic kubeconfig Handling**
  Creates a temporary kubeconfig based on `kcp/.kcp/admin.kubeconfig` and switches contexts/workspaces as needed.

* **Workspace and Context Switching**
  Switches to the `root` context and navigates into any specified workspace (or nested workspaces).

* **Local CRD and Resource Application**
  Applies Gardener CRDs and essential cluster resources (`cloudprofile` and `seed` YAMLs) from the `resources/` directory—no external cloning needed.

* **Project and Shoot Management**

  * `add-project`, `add-projects`: Create single or bulk projects (with status patched to **Ready**).
  * `add-shoot`, `add-shoots`: Add single or bulk shoots under a project (with **Ready** or **Error** status based on naming).

* **Demo Environment Setup**

  * `create-demo-workspaces`: Builds `demo-animals`, `demo-plants`, and `demo-cars` workspaces with projects, shoots, and AWS secrets.
  * `create-single-demo-workspace`: Builds a single `demo` workspace for quick testing.

* **Token Retrieval**
  Creates or updates the `dashboard-user` service account in the `garden` namespace and retrieves a 24-hour token.

* **Reset Options**

  * `reset-kcp`: Clears local kcp state.
  * `reset-kcp-certs`: Removes certificate and key files for clean reconnection.

* **Built‑in macOS Network Alias**
  Automatically configures `lo0` alias (`192.168.65.1/24`) on macOS if not already present.

---

## Prerequisites

* **Git**
* **Go toolchain** (for building kcp)
* **kubectl**
* **YQ** (CLI YAML processor)

---

## Setup & Installation

1. **Clone this repository**

   ```bash
   git clone <repository-url>
   cd <repository-directory>
   ```
2. **Ensure prerequisites are installed** (Git, Go, kubectl, yq).
3. **Initial kcp Installation**
   Download, build, and install kcp:

   ```bash
   ./gardenerless-setup.sh setup-kcp
   ```
4. **Start kcp Server**
   After building, start the kcp server:

   ```bash
   ./gardenerless-setup.sh start-kcp
   ```

   This will also configure the macOS network alias automatically.
5. **Reset kcp State**
   To clear the local kcp database and state at any time, run:

   ```bash
   ./gardenerless-setup.sh reset-kcp
   ```
6. **Demo Workspace for Standard Dashboard**
   For a quick start with the standard Gardener Dashboard (without kcp mode), create a single demo workspace:

   ```bash
   ./gardenerless-setup.sh create-single-demo-workspace
   ```

   A ready-to-use kubeconfig is generated at `kcp/.kcp/dashboard.kubeconfig`.
7. **Demo Workspaces for kcp Dashboard Mode**
   To test the Gardener Dashboard’s experimental kcp integration (feature branch required), use:

   ```bash
   ./gardenerless-setup.sh create-demo-workspaces
   ```

   This creates multiple demo workspaces (`demo-animals`, `demo-plants`, `demo-cars`) with CRDs and demo resources preconfigured. The kubeconfig targeting the base context is generated at `kcp/.kcp/dashboard-kcp.kubeconfig`, allowing the dashboard to work directly in kcp mode.

---

## Usage

Run the script with optional `--workspace <ws>` (workspace path under `root`) and a command:

```bash
./gardenerless-setup.sh --workspace <workspace> <command> [args]
```

### Global Option

* `--workspace <ws>`
  Specify the workspace (e.g., `foo` or `root:foo:bar`). Automatically prepended with `root` if missing.

### Commands

| Command                        | Description                                                      |
| ------------------------------ | ---------------------------------------------------------------- |
| `setup-kcp`                    | Clone/update and build the kcp binary.                           |
| `start-kcp`                    | Start the kcp server (foreground, with built‑in macOS alias).    |
| `reset-kcp`                    | Delete all state under `kcp/.kcp/`.                              |
| `reset-kcp-certs`              | Remove certificates and keys under `kcp/.kcp/`.                  |
| `setup-gardener-crds`          | Apply Gardener CRDs from `resources/crds/`.                      |
| `cluster-resources`            | Apply `cloudprofile-*.yaml` and `seed-*.yaml` from `resources/`. |
| `get-token`                    | Create/refresh `dashboard-user` token for 24 hours.              |
| `add-project <name>`           | Create a project (namespace `garden-<name>`) and mark **Ready**. |
| `add-projects <count>`         | Bulk-create `<count>` projects (random UIDs).                    |
| `add-shoot <shoot> <project>`  | Add a shoot to project (Ready or Error based on suffix).         |
| `add-shoots <project> <count>` | Bulk-create `<count>` shoots under a project.                    |
| `create-demo-workspaces`       | Build `demo-animals`, `demo-plants`, `demo-cars` with demos.     |
| `create-single-demo-workspace` | Build a single `demo` workspace with demos.                      |
| `dashboard-kubeconfigs`        | Print paths for generated dashboard kubeconfigs.                 |

---

## Command Examples

* **Clone & Build kcp**:

  ```bash
  ./gardenerless-setup.sh setup-kcp
  ```

* **Start kcp Server**:

  ```bash
  ./gardenerless-setup.sh start-kcp
  ```

* **Apply CRDs & Resources**:

  ```bash
  ./gardenerless-setup.sh --workspace demo-animals setup-gardener-crds
  ./gardenerless-setup.sh --workspace demo-animals cluster-resources
  ```

* **Create a Project**:

  ```bash
  ./gardenerless-setup.sh add-project myproject
  ```

* **Bulk Projects & Shoots**:

  ```bash
  ./gardenerless-setup.sh add-projects 5
  ./gardenerless-setup.sh add-shoots myproject 10
  ```

---

## Troubleshooting

* **Missing kcp binary**
  If commands other than `setup-kcp` or `start-kcp` fail, run:

  ```bash
  ./gardenerless-setup.sh setup-kcp
  ```

* **No kcp server detected**
  Ensure kcp is running:

  ```bash
  ./gardenerless-setup.sh start-kcp
  ```

* **Admin kubeconfig not found**
  Verify `kcp/.kcp/admin.kubeconfig` exists and is accessible.

* **Permission Errors**
  Check your Git, Go, and `kubectl` access rights.

If issues persist, inspect script logs and ensure your environment meets all prerequisites.

---

Happy clustering and dashboarding!
