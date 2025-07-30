Local kcp Management Script for Gardener Dashboard (`gardenerless-setup.sh`)

## Introduction

This repository provides a Bash script (`gardenerless-setup.sh`) to set up a **local, Gardener-like environment** for development and testing purposes. It allows you to run the Gardener Dashboard against a Kubernetes-like API server without requiring a full Gardener installation (i.e., no controllers or actual Gardener components are running).

Instead, it uses the `kcp` binary to serve a simulated Kubernetes API. This setup enables:

* Making API calls as if interacting with a Gardener API server
* Running the Gardener Dashboard in a self-contained demo environment
* Simulating load and operations via demo resources and a UI

The environment supports two modes:

* **Single-cluster mode**, mimicking a regular Kubernetes API server
* **Multi-workspace mode**, simulating multiple logical clusters via `kcp` workspaces

> **Note:** Running the dashboard in multi-workspace mode requires a *kcp-aware* Dashboard instance. This is currently an experimental feature not yet merged into the main Gardener Dashboard branch.

> **Note:** This script works with a dedicated kcp directory (`kcp/`) and uses hardcoded kubeconfig paths. All network alias handling (for macOS) is built in—no manual aliasing is required.

---

## Prerequisites

* **Git**
* **Go** (for building kcp)
* **kubectl**
* **yq** (CLI YAML processor)

---

## Quickstart

1. **Clone & enter repo**

   ```bash
   git clone <repo-url>
   cd <repo-dir>
   ```

2. **Build kcp**

   ```bash
   ./gardenerless-setup.sh setup-kcp
   ```

3. **Start kcp server**

   ```bash
   ./gardenerless-setup.sh start-kcp
   ```

   > macOS users: loopback alias is added automatically (if needed). You will be prompted for root access

   > The server will run until you terminate the command. You need to open a second terminal to continue with the next steps

4. **Create a single demo workspace**

   ```bash
   ./gardenerless-setup.sh create-single-demo-workspace
   ```

   → Kubeconfig: `kcp/.kcp/dashboard.kubeconfig`

   **Or create full demo suite for kcp mode**

   ```bash
   ./gardenerless-setup.sh create-demo-workspaces
   ```

   → Kubeconfig: `kcp/.kcp/dashboard-kcp.kubeconfig`

5. **Get token for Gardener Dashboard**

   The script automatically creates requires service accounts and rbac rules for you.
   You can obtain a token for a Gardener Dashboard usder with admin privileges by running

   ```bash
   ./gardenerless-setup.sh get-token
   ```

---

## Usage

```bash
./gardenerless-setup.sh [--workspace <ws>] <command> [options]
```

* **Global flag**
  `--workspace <ws>`
  Enter any workspace path under `root` (e.g. `foo`, or nested `root:foo:bar`).

### Commands & Options

| Command                          | Options                                                                      | Description                                                   |                                           |
| -------------------------------- | ---------------------------------------------------------------------------- | ------------------------------------------------------------- | ----------------------------------------- |
| **setup-kcp**                    | —                                                                            | Clone & build the kcp binary                                  |                                           |
| **start-kcp**                    | —                                                                            | Start the kcp server (foreground, macOS alias)                |                                           |
| **reset-kcp**                    | —                                                                            | Delete all `kcp/.kcp` state                                   |                                           |
| **reset-kcp-certs**              | —                                                                            | Remove certs/keys in `kcp/.kcp`                               |                                           |
| **setup-gardener-crds**          | —                                                                            | Apply CRDs from `resources/crds/`                             |                                           |
| **cluster-resources**            | —                                                                            | Apply `cloudprofile-*.yaml` & `seed-*.yaml` from `resources/` |                                           |
| **get-token**                    | —                                                                            | Create/refresh 24h token for `dashboard-user` SA              |                                           |
| **dashboard-kubeconfigs**        | —                                                                            | Print paths of generated dashboard kubeconfigs                |                                           |
| **add-project**                  | `--name <name>`<br>`[--namespace <ns>]`                                      | Create one project (status=Ready)                             |                                           |
| **add-projects**                 | `--count <n>`                                                                | Bulk-create *n* projects (random UIDs, status=Ready)          |                                           |
| **add-shoot**                    | `--shoot <name>`<br>`--project <proj>`                                       | Create one shoot               |                                           |
| **add-shoots**                   | `--project <proj>`<br>`--count <n>`                                          | Bulk-create *n* shoots (healthy by default)                   |                                           |
| **create-demo-workspaces**       | —                                                                            | Build `demo-animals`, `demo-plants`, `demo-cars` with samples |                                           |
| **create-single-demo-workspace** | —                                                                            | Build one `demo` workspace with samples                       |                                           |

---

## Examples

```bash
# Build kcp
./gardenerless-setup.sh setup-kcp

# Start server
./gardenerless-setup.sh start-kcp

# Apply CRDs & resources in demo-animals
./gardenerless-setup.sh --workspace demo-animals setup-gardener-crds
./gardenerless-setup.sh --workspace demo-animals cluster-resources

# Create one project named "foo"
./gardenerless-setup.sh add-project --name foo

# Bulk-create 5 projects
./gardenerless-setup.sh add-projects --count 5

# Add a shoot "bar" to project "foo"
./gardenerless-setup.sh add-shoot --shoot bar --project foo

# Bulk-create 10 shoots in "foo"
./gardenerless-setup.sh add-shoots --project foo --count 10
```

---

## Troubleshooting

* **kcp binary missing?**
  Run `./gardenerless-setup.sh setup-kcp`.

* **issues with kubectl ws plugin**
  Ensure that both your `GOPATH` and `PATH` environment variables are correctly set. Your `PATH` must include `$GOPATH/bin`.


* **Server not running?**
  Run `./gardenerless-setup.sh start-kcp`.

If problems persist, inspect script logs and ensure all prerequisites are met.

