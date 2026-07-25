# Gardenerless local dashboard fixture

`gardenerless-setup.sh` prepares a local, fixture-backed Gardener-like API for
Dashboard development and visual verification. It uses [kcp](https://github.com/kcp-dev/kcp)
to expose Kubernetes-style resources; it is not a real Gardener installation
and does not run Gardener controllers or create Shoot clusters.

The supported verification workflow is deliberately local-only. Commands that
contact Kubernetes validate an explicit gardenerless kubeconfig before making a
request. The validation accepts only the selected local runtime, an HTTPS
loopback API endpoint, and that runtime's serving certificate chain. Ambient
`KUBECONFIG` is ignored by the guarded workflow.

## Prerequisites

Install `git`, `go`, `make`, `kubectl`, `yq`, and `openssl`. Building the local
kcp runtime also needs network access to fetch kcp; normal fixture inspection
does not.

## Select the local runtime

By default, the script uses `kcp/` next to `gardenerless-setup.sh`. To reuse a
separate local runtime—for example, from another worktree—set an absolute path
explicitly:

```bash
export GARDENERLESS_KCP_DIR=/absolute/path/to/local/kcp
```

The selected directory contains the kcp source checkout, binary, `.kcp` state,
admin kubeconfig, and generated dashboard kubeconfigs. Repository-owned CRDs
and fixture templates are always read from this checkout.

Do not point `GARDENERLESS_KCP_DIR` at a shared, remote, staging, or production
environment. A missing, unexpected, non-loopback, or TLS-mismatched kubeconfig
is rejected before an API request is sent.

## Safe local fixture workflow

In one terminal, build and start a local kcp runtime if it does not already
exist:

```bash
./gardenerless-setup.sh setup-kcp
./gardenerless-setup.sh start-kcp
```

`start-kcp` runs in the foreground. On macOS it can request permission to add a
loopback alias when required. Do not run `setup-kcp`, `reset-kcp`, or
`reset-kcp-certs` in an automated verification flow; resetting removes reusable
local state.

From a second terminal, first inspect the selected runtime:

```bash
./gardenerless-setup.sh status
```

`status` is read-only. It reports local prerequisites, the selected runtime,
kcp process state, guarded kubeconfig, API readiness, context/workspace, and
fixture resource counts. It is also safe when kcp is absent or stopped. A
`--workspace` value is deliberately ignored by `status`.

Create the supported baseline only when needed:

```bash
./gardenerless-setup.sh ensure-single-demo-workspace
```

This creates only missing resources in the local `demo` fixture and leaves
healthy existing resources unchanged. It reuses a generated Dashboard
kubeconfig only while that credential can list Gardener Projects, and refreshes
the generated credential when the capability check fails. The command prints
the single-workspace dashboard kubeconfig at:

```text
$GARDENERLESS_KCP_DIR/.kcp/dashboard.kubeconfig
```

Use `./gardenerless-setup.sh dashboard-kubeconfigs` to print both generated
dashboard kubeconfig paths without contacting the API.

## Guarded inspection

For ad-hoc inspection, invoke the checked-in wrapper from this repository:

```bash
./kubectl-gardenerless get shoots -A
./kubectl-gardenerless get projects
```

The wrapper validates the local admin kubeconfig, supplies it explicitly, and
forwards ordinary kubectl arguments unchanged. It rejects caller-provided
connection, context, kubeconfig, certificate, TLS-bypass, and proxy overrides.
The setup workflow and wrapper use the same guarded invocation path. Validation
is cached only while the selected kubeconfig and runtime certificate remain
unchanged, so context or workspace changes are revalidated before the next API
request.
Do not substitute plain `kubectl` for this guarded workflow, and no `PATH`
installation is required.

## Named visual-verification scenarios

Each scenario first ensures the baseline fixture, then applies a deterministic
local state for Dashboard verification:

```bash
./gardenerless-setup.sh scenario healthy-shoot
./gardenerless-setup.sh scenario failing-shoot
./gardenerless-setup.sh scenario many-shoots
./gardenerless-setup.sh scenario operation-in-progress
```

`healthy-shoot`, `failing-shoot`, and `operation-in-progress` set the status of
the fixture Shoot `pine-oak` in `garden-pine`. `many-shoots` adds the bounded,
deterministically named `visual-many-01` through `visual-many-12` Shoots to the
same fixture; repeating it after a healthy application does not replace or
modify existing fixture resources.

These commands mutate only the validated local fixture. They are not suitable
for a real Gardener API or any shared environment.

## Dashboard access

The baseline creates the local `dashboard-user` service account and its local
fixture permissions. Generate a short-lived token only when a Dashboard login
requires it:

```bash
./gardenerless-setup.sh get-token
```

The baseline also applies `resources/system-viewer-rbac.yaml`. To generate a
read-only token for its `landscape-viewer` service account, select that account
explicitly:

```bash
./gardenerless-setup.sh get-token --service-account landscape-viewer
```

Treat the output as a credential: paste it directly into the local login UI and
do not save it in source files, fixtures, screenshots, issue comments, or
documentation.

The generated dashboard kubeconfig can be used to configure a local Dashboard
or the optional `ui/` editor. For the latter, set `KUBECONFIG` only in that
process's environment, using the printed path from
`ensure-single-demo-workspace` or `dashboard-kubeconfigs`. See
[`ui/README.md`](ui/README.md) for the editor's development commands.

## Command reference

```text
./gardenerless-setup.sh [--workspace <ws>] <command> [options]
```

All API-contacting commands use the shared local-target guard before workspace
selection or resource access. `--workspace` selects a workspace directly under
`root` for commands that support it; do not use it with `status`.

| Command | Purpose |
| --- | --- |
| `setup-kcp` | Clone and build the local kcp binary and plugins. |
| `start-kcp` | Start the local kcp server in the foreground. |
| `status` | Read-only local runtime and guarded fixture status. |
| `ensure-single-demo-workspace` | Create only missing baseline fixture resources. |
| `scenario <name>` | Apply `healthy-shoot`, `failing-shoot`, `many-shoots`, or `operation-in-progress`. |
| `dashboard-kubeconfigs` | Print local generated dashboard-kubeconfig paths; no API request. |
| `get-token [--service-account NAME]` | Print a 24-hour local service-account token (default: `dashboard-user`). |
| `create-demo-workspaces` | Create the legacy multi-workspace sample fixture. |
| `setup-gardener-crds`, `cluster-resources` | Apply repository fixture CRDs and cluster resources. |
| `add-project`, `add-shoot`, `add-projects`, `add-shoots` | Add local fixture resources for manual experimentation. |
| `reset-kcp`, `reset-kcp-certs` | Destructive local-runtime maintenance; do not use for normal verification. |

Run `./gardenerless-setup.sh --help` for the current flags and arguments.

## Troubleshooting

- Run `status` first. If it reports an unavailable guarded kubeconfig, confirm
  that `GARDENERLESS_KCP_DIR` names the intended local runtime and that its
  `.kcp/admin.kubeconfig` exists.
- If the API is unavailable, start only the local kcp process that belongs to
  the selected runtime. Preserve reusable state rather than resetting it.
- If `kubectl-gardenerless` rejects an argument, remove any connection-routing
  option such as `--kubeconfig`, `--server`, `--context`, or TLS/proxy override.
  The wrapper owns those settings.
- If kcp or its workspace plugin is missing, use `setup-kcp` only when building
  a new local runtime. Check `status` again after starting it.

For script changes, run the fixture-only guard suite:

```bash
bash tests/gardenerless-setup-guard-test.sh
```

The suite supplies temporary kubeconfigs, certificates, process stubs, and a
kubectl stub; it does not contact a running kcp server or any external API.
