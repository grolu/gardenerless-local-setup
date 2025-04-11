# Local kcp Management Script for Gardener Dashboard

## Introduction

This repository contains a Bash script designed to simplify the setup and management of a local **kcp** installation for the Gardener Dashboard. It streamlines common administrative tasks—including workspace and project management, applying essential resources, and setting up demo environments—so you can quickly start working with your Gardener Dashboard.

**Important:**  
To use the Gardener Dashboard with kcp, you must use the experimental KCP branch of the Gardener Dashboard. Start the dashboard backend using:

```bash
yarn serve-kcp
```

Then, before logging in via your browser, append the query parameter `?workspace=<workspace-path>` to the login URL (for example, `https://localhost:8443/login?workspace=root:demo-animals`).

---

## Features

- **Temporary Kubeconfig Management:**  
  Automatically creates a temporary kubeconfig copy from your original configuration file to safely manage local settings.

- **Workspace and Context Switching:**  
  Easily switches to the `root` context and navigates through sub-workspaces based on the provided workspace parameter.

- **Gardener CRDs Setup:**  
  Checks for and sets up necessary Gardener CRDs. If the required CRD script is missing, it attempts to clone the repository using your SSH key.

- **Project Management:**  
  Creates project resources using YAML templates and patches project statuses, ensuring that projects are set to a "Ready" phase.

- **Resource Application:**  
  Applies essential cluster resources such as `cloudprofile.yaml` and `seed.yaml` that are required to start a working kcp setup.

- **Token Generation:**  
  Ensures that the dashboard service account exists in the `garden` namespace and retrieves a token valid for 24 hours.

- **Demo Environment Setup:**  
  Provides an option to automatically create demo workspaces and projects (e.g., `demo-animals`, `demo-plants`, `demo-cars`), along with associated shoots and secrets for a quick start.

- **Reset Options:**  
  Offers commands to reset the local kcp installation or specifically reset kcp certificates.

---

## Prerequisites

Before using this script, please ensure you have:

- **A Local kcp Installation:**  
  Your kubeconfig (typically at `~/.kube/config`) must point to a local kcp instance and include the `kcp-admin` context.

- **kubectl:**  
  Installed and configured to communicate with your kcp cluster.

- **Git:**  
  Required for cloning the Gardener CRDs repository if necessary.

- **SSH Key for GitHub:**  
  Needed to authenticate when cloning the repository for Gardener CRDs.

- **Yarn:**  
  To start the Gardener Dashboard backend with `yarn serve-kcp` (ensure you are using the experimental KCP branch of the dashboard).

---

Below is the formatted markdown:

---

## Running kcp Server

Preferably, start kcp using the binary in the **bin** directory:

```bash
./kcp start
```

> **Note:** You may need to build kcp in order to get the binaries. Follow the build instructions provided in the project's documentation.

> **Note:** If you experience certificate errors or startup issues with your kcp server after a network change, please refer to the [Troubleshooting kcp Server Startup and Certificate Errors After Network Changes](#troubleshooting-kcp-server-startup-and-certificate-errors-after-network-changes) guide for detailed instructions.

After building, you can start the server as shown above.

---

## Setup and Installation

1. **Clone the Repository:**

   ```bash
   git clone <repository-url>
   cd <repository-directory>
   ```

2. **Verify Your kubeconfig:**  
   Ensure your kubeconfig file (default is `~/.kube/config`) contains the `kcp-admin` context, as the script uses this to confirm a local kcp setup.

3. **Review the Script:**  
   The script automatically creates a temporary kubeconfig, manages workspace transitions, and applies YAML templates. Adjust paths and template files if your repository structure differs.

---

## Usage

Run the script with various commands and optional global parameters. Display the help message for a list of available commands and usage examples:

```bash
./manage-kcp.sh --help
```

Replace `manage-kcp.sh` with the actual filename (e.g., `kcp-management.sh`).

### Global Options

- `--workspace <workspace>`:  
  Specifies the workspace to use (e.g., `foo:bar` or `root:foo:bar`). If the workspace path doesn’t start with `root`, it will be automatically prepended.

### Commands Overview

- **setup-gardener-crds**  
  Downloads and sets up Gardener CRDs for the current workspace.

- **cluster-resources**  
  Sets up Gardener CRDs and applies `cloudprofile.yaml` and `seed.yaml` to configure essential cluster resources.

- **get-token**  
  Creates the `garden` namespace (if missing), ensures the `dashboard-user` service account exists, and retrieves a token valid for 24 hours.

- **create-project `<name>`**  
  Creates a project resource using a provided YAML template. It creates a corresponding namespace (`garden-<name>`) and patches the project status to `"Ready"`.

- **create-workspace `<name>`**  
  Creates and enters a new workspace under the `root` workspace.

- **delete-workspace `<name>`**  
  Deletes the specified workspace.

- **list-workspaces**  
  Lists all workspaces by displaying the workspace tree.

- **reset-kcp**  
  Resets the local kcp installation by deleting files within the `bin/.kcp/` directory (only applicable if using a local binary kcp server).

- **reset-kcp-certs**  
  Removes certificate files (`*.crt`, `*.key`) in the local kcp directory.

- **create-demo-workspaces**  
  Automatically creates demo workspaces (`demo-animals`, `demo-plants`, `demo-cars`), along with associated projects, shoots, and secrets to give you an instant working setup.

---

## Command Examples

- **Apply Cluster Resources in a Workspace:**

  ```bash
  ./manage-kcp.sh cluster-resources --workspace foo:bar
  ```

- **Retrieve the Dashboard Token:**

  ```bash
  ./manage-kcp.sh get-token --workspace foo:bar
  ```

- **Create a New Project:**

  ```bash
  ./manage-kcp.sh create-project my_project --workspace root:foo:bar
  ```

- **Create a New Workspace:**

  ```bash
  ./manage-kcp.sh create-workspace myws --workspace foo:bar
  ```

- **Delete a Workspace:**

  ```bash
  ./manage-kcp.sh delete-workspace myws --workspace foo:bar
  ```

- **List All Workspaces:**

  ```bash
  ./manage-kcp.sh list-workspaces --workspace foo:bar
  ```

- **Create Demo Workspaces:**

  ```bash
  ./manage-kcp.sh create-demo-workspaces
  ```

---

## Using the Gardener Dashboard with kcp

To integrate the Gardener Dashboard with your kcp setup:

1. **Switch to the Experimental KCP Branch:**  
   Ensure you are using the experimental KCP branch of the Gardener Dashboard.

2. **Start the Dashboard Backend:**

   ```bash
   yarn serve-kcp
   ```

3. **Log In with the Appropriate Workspace:**  
   Append the query parameter to the login URL to specify your workspace. For example:

   ```
   https://localhost:8443/login?workspace=root:demo-animals
   ```

---

## Troubleshooting

- **Kubeconfig Issues:**  
  Ensure that your kubeconfig contains the `kcp-admin` context. The script will abort with an error if this context is missing.

- **CRD Setup Failures:**  
  If the Gardener CRDs setup script (`setup-garderner-api.sh`) is not found, the script attempts to clone the repository. Verify your SSH key configuration and GitHub access if cloning fails.

- **Namespace or Resource Creation Errors:**  
  Check that you have the appropriate permissions and that your kcp cluster is operational.

### Troubleshooting Certificate Errors When Connecting to the kcp Server

If you encounter certificate errors when trying to connect to your local kcp server, it's likely that outdated, corrupted, or mismatched certificate files are causing connectivity issues. Here are some steps you can take to resolve these errors:

1. **Identify the Issue:**  
   Check the error message carefully. Certificate errors often indicate that the client’s certificate files (typically `*.crt` and `*.key`) stored in your kcp local installation are either expired or not matching the server’s current credentials.

2. **Reset the kcp Certificates:**  
   The easiest way to resolve these issues is to clear out the existing certificate files so that new ones can be generated. Use the provided management script’s command to reset the certificates. This command deletes all certificate files from the local kcp directory.  
   
   **Run the following command:**
   ```bash
   ./manage-kcp.sh reset-kcp-certs
   ```

3. **Restart the kcp Server:**  
   After resetting the certificates, ensure that your kcp server is restarted properly. This allows the server to generate or reload the new certificate files.

4. **Verify Your Connection:**  
   Once the server is running again, try connecting. The certificate errors should be resolved if the reset was successful. Check your logs for any recurring issues if problems persist.

5. **Additional Considerations:**  
   - **Kubeconfig Check:** Ensure that your kubeconfig file points to the correct local binary kcp server. An incorrect configuration can also lead to certificate verification errors.  
   - **Network and Permissions:** Make sure there are no network issues or permission restrictions that could be interfering with certificate file creation or access.

By following these steps and using the `reset-kcp-certs` command, you can effectively troubleshoot and resolve certificate errors when connecting to the kcp server. If problems continue after these steps, further investigation of your local kcp installation and configuration may be necessary.

### Troubleshooting kcp Server Startup and Certificate Errors After Network Changes

#### Overview

When the kcp server does not start in an offline environment or binds to a different IP address after a network change, it can lead to invalid certificate errors. This happens because the server's certificate is tied to a specific IP address, and any deviation may cause certificate mismatches.  

#### Common Symptoms

- **Startup Failures:**  
  The kcp server fails to start when the system is offline.

- **IP Address Mismatch:**  
  Following a network change, the kcp server may bind to a different IP address than expected.

- **Certificate Validation Errors:**  
  Due to the change in IP address, the existing certificates become invalid, leading to connection errors.

#### Root Cause

The kcp server is binding to an IP address that changes based on the network configuration. Since the certificates are generated for a specific IP (or hostname), any alteration in the bound address after generation causes a mismatch.

#### Resolution Steps

1. **Assign a Network Alias:**  
   To ensure consistency, add an alias with a private IP address that qualifies as a global unicast address.  
   For example, assign the alias `192.168.65.1` from a private IP range.

   - **On MacOS:**  
     You can add an alias for the loopback interface using the `ifconfig` command:
     ```bash
     sudo ifconfig lo0 alias 192.168.65.1/24
     ```

2. **Start the kcp Server with the Specified Bind Address:**  
   Once the alias is added, start the kcp server binary and explicitly bind it to the new alias:
   ```bash
   kcp start --bind-address=192.168.65.1
   ```

3. **Verify the Setup:**  
   - Confirm that the server has started successfully.
   - Check that the bound IP is indeed `192.168.65.1` using commands like `netstat -tulnp` or `ss -tulnp`.
   - Ensure that the certificate generated corresponds to the alias IP and that there are no certificate-related errors during connectivity.

#### Additional Considerations

- **Persistent Configuration:**  
  If your network configuration is dynamic, consider setting up the IP alias permanently, or include the aliasing step in your startup scripts.

- **Firewall and Routing:**  
  Make sure your firewall and routing settings allow traffic on the alias IP.

- **Certificate Regeneration:**  
  If you still experience certificate errors, you may need to regenerate certificates after binding to the new IP address to ensure consistency between the certificate details and the server configuration.

By following these troubleshooting steps, you should be able to resolve the issues caused by IP changes due to network fluctuations, ensuring that the kcp server consistently binds to a known IP address and the certificate errors are eliminated.

---

Happy clustering and dashboarding!
