# KCP Gardener UI

A small Vue/Vuetify application for editing resources in the local kcp server.
It features a simple and an advanced mode. The **simple** mode lets you select
common Gardener resource types and automatically fills namespace and name
options. The **advanced** mode allows free entry of API group, version and
resource paths. The UI uses the Gardener Dashboard color theme for a familiar
look.

## Development

```bash
cd ui
yarn install
yarn dev
```

The UI issues API requests relative to its own origin. During development the Vite server runs at `http://localhost:5173` and proxies any `/api` calls to the Express backend on `http://localhost:3000`.
When running the built UI with `yarn serve`, both the static files and API are served from the same Express server on `http://localhost:3000`.

## Build

```bash
yarn build
```

Compiled files are placed in `dist/`. Start the backend with `yarn serve` to use the built UI.

## Editing Resources

In advanced mode the editor requires the API group and version in addition to the resource type, namespace and name. For example, a Shoot would use:

```
API Group: core.gardener.cloud
API Version: v1beta1
Resource Type: shoots
Namespace: garden-myproject
Name: myshoot
```

Leave **API Group** and **API Version** empty for core `v1` resources.

In simple mode you can select from predefined resources (Shoot, Seed, CloudProfile, Project). If the resource is namespaced, the list of namespaces and names is automatically fetched from the API server. A checkbox allows you to patch the `status` subresource. When patching `status` only the status object is shown in the editor for easier editing. After saving, the resource is reloaded so the editor always shows the latest state.
Toggling the checkbox reloads the current resource so you can seamlessly switch between editing the full object or just the status.

The **simulate** tab lets you create tasks that periodically modify resources.
**Toggle Health** tasks work on Shoots or Seeds and randomly flip their status between healthy and unhealthy based on an **error rate** percentage.
The new **Operation Progress** task simulates a running operation on a Shoot.
Choose an operation type (Create, Delete or Reconcile), an update interval and the progress step size. The task updates the `lastOperation` field to `Processing` and increases the progress until it reaches 100% and reports `Succeeded`. If marked as recurring it will pick a random shoot and start over. All tasks can target a single namespace or span all namespaces and multiple can run in parallel.

### TLS Verification

TLS verification is disabled by default so that self-signed certificates work out of the box. If you need to enforce verification, set `SKIP_TLS_VERIFY=false` when starting the server:

```bash
SKIP_TLS_VERIFY=false yarn serve
```

The backend logs all requests with their paths and response codes to aid debugging.
