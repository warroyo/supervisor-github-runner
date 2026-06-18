# supervisor-github-runner

A GitHub Actions **self-hosted, ephemeral runner** that runs as a single
[vSphere Pod](https://techdocs.broadcom.com/us/en/vmware-cis/vsphere/vsphere-supervisor/8-0/using-tkg-service-with-vsphere-supervisor/deploying-workloads-to-vsphere-pods.html)
on a VMware vSphere **Supervisor** cluster.

It is a **bootstrap-tier runner**: its purpose is to run Terraform that
provisions infrastructure, so it deliberately relies on **core Kubernetes
resources only** — no CRDs, no operators, no Helm. Everything here is plain
`Namespace` / `ServiceAccount` / `Role` / `Secret` / `ConfigMap` / `Deployment`.

## How it works

```
                 ┌──────────────────────── Pod (replicas: 1) ───────────────────────┐
                 │                                                                   │
  github-app     │  initContainer: mint-jitconfig (python:3-slim)                    │
  Secret  ──────►│    1. sign JWT with App private key (RS256, PyJWT)                │
  (App key)      │    2. JWT → installation access token                             │
                 │    3. POST .../generate-jitconfig                                 │
                 │    4. write encoded JIT config ──┐                                │
                 │                                  ▼                                 │
                 │                          emptyDir (runner-config)                 │
                 │                                  │                                 │
                 │  container: runner (ghcr.io/actions/runner)                       │
                 │    run.sh --jitconfig "$(cat /runner-config/jitconfig)" ◄─────────┘
                 │      → runs exactly ONE job, deregisters, exits                   │
                 └───────────────────────────────────────────────────────────────────┘
                         pod exits → Deployment recreates it → fresh JIT config
```

Key design points:

- **Ephemeral / JIT registration.** The init container mints a Just-In-Time
  runner config. A JIT runner runs exactly one job and then deregisters itself,
  so the repo's runner list never accumulates stale "offline" entries. When the
  runner exits, the `Deployment` recreates the pod and the init container mints
  a fresh config for the next job.
- **The App private key never touches the runner container.** All privileged
  GitHub API work happens in the init container. The runner — which executes
  untrusted workflow code — only ever sees the single-use JIT config blob handed
  over through a shared `emptyDir`.
- **No custom image.** The token-minting logic is a Python script stored in a
  `ConfigMap` and executed by the stock `python:3-slim` image. The runner is the
  unmodified `ghcr.io/actions/runner` image. Nothing to build or host.
- **No persistence.** The work directory is an `emptyDir`; Terraform state is
  stored in the [Kubernetes backend](https://developer.hashicorp.com/terraform/language/settings/backends/kubernetes)
  (an in-cluster `Secret` + a `Lease` for locking), not on the runner's disk.

## Files (apply in numeric order)

| File | Purpose |
|------|---------|
| `00-namespace.yaml` | The `github-runners` namespace (labeled `restricted` PSS). |
| `01-serviceaccount-rbac.yaml` | `ServiceAccount` + `Role`/`RoleBinding` granting the Terraform Kubernetes backend access to **secrets** and **leases** in this namespace only. |
| `02-secret.yaml` | The GitHub App ID + private key (placeholders — see below). |
| `03-configmap-jitconfig.yaml` | The Python token-minting script. |
| `04-deployment.yaml` | The init container + stock runner container + shared `emptyDir`. |

## Prerequisites

- A vSphere Supervisor namespace with a `kubectl` context pointing at it, and
  permission to create the resources above.
- The Supervisor's **restricted** Pod Security profile is satisfied by the pod
  spec as written (`runAsNonRoot`, all capabilities dropped,
  `allowPrivilegeEscalation: false`, `RuntimeDefault` seccomp, no host
  namespaces, no privileged containers).
- Egress from the Supervisor to `https://api.github.com` and to
  `ghcr.io` / PyPI (so the init container can `pip install PyJWT`).

## 1. Create the GitHub App

Using a GitHub App (not a Personal Access Token) keeps a long-lived user token
out of the cluster: the init container mints a fresh, short-lived installation
token on every pod start.

1. Go to **Settings → Developer settings → GitHub Apps → New GitHub App**
   (under your user or org).
2. **GitHub App name:** anything, e.g. `lab-supervisor-runner`.
3. **Homepage URL:** any valid URL (e.g. your repo URL).
4. **Webhook:** uncheck **Active** — this App is not driven by webhooks.
5. **Repository permissions:** set **Self-hosted runners → Read and write.**
   That single permission is all that is required to call
   `generate-jitconfig`. Leave everything else as **No access**.
6. **Where can this GitHub App be installed?** Choose **Only on this account**.
7. Click **Create GitHub App.**

### Note the App ID and generate a private key

- On the App's settings page, copy the numeric **App ID**.
- Scroll to **Private keys → Generate a private key.** GitHub downloads a
  `.pem` file. Keep it safe — this is the signing key.

### Install the App on the target repo

1. On the App's settings page, open **Install App** (left sidebar).
2. Click **Install** next to your account/org.
3. Choose **Only select repositories** and select the target repo (the one this
   runner will serve). Confirm.

## 2. Populate the Secret

Create the Secret directly from your files (recommended — avoids
base64/whitespace mistakes with the multi-line PEM):

```sh
kubectl apply -f 00-namespace.yaml

kubectl -n github-runners create secret generic github-app \
  --from-literal=app-id='YOUR_APP_ID' \
  --from-file=private-key.pem=./your-app.private-key.pem
```

This produces the same `github-app` Secret that `02-secret.yaml` documents
declaratively. (If you prefer to track it in Git, edit `02-secret.yaml` and
manage it through an encryption tool such as SOPS or Sealed Secrets — never
commit a plaintext private key.)

## 3. Fill in the repo placeholders

Edit **`04-deployment.yaml`** and replace the two clearly-marked placeholders in
the init container's `env`:

```yaml
- name: REPO_OWNER
  value: "REPLACE_WITH_REPO_OWNER"   # e.g. "warroyo"
- name: REPO_NAME
  value: "REPLACE_WITH_REPO_NAME"    # e.g. "supervisor-github-runner"
```

If you populated the Secret declaratively via `02-secret.yaml` instead of the
`kubectl create secret` command, also replace the `app-id` and
`private-key.pem` placeholders there.

## 4. Apply (in order)

```sh
kubectl apply -f 00-namespace.yaml
kubectl apply -f 01-serviceaccount-rbac.yaml
kubectl apply -f 02-secret.yaml            # skip if you used `kubectl create secret`
kubectl apply -f 03-configmap-jitconfig.yaml
kubectl apply -f 04-deployment.yaml
```

## 5. Verify the runner picks up a job and disappears cleanly

1. **Watch the pod come up and the init container succeed:**

   ```sh
   kubectl -n github-runners get pods -w
   kubectl -n github-runners logs deploy/github-runner -c mint-jitconfig
   ```

   The init log should end with
   `Wrote JIT config for runner '<pod-name>' to /runner-config/jitconfig`.

2. **Confirm the runner connected and is idle:**

   ```sh
   kubectl -n github-runners logs deploy/github-runner -c runner -f
   ```

   You should see `Connected to GitHub` and `Listening for Jobs`. In the repo
   under **Settings → Actions → Runners**, a runner named after the pod appears
   with the labels `self-hosted, lab-supervisor`.

3. **Send it a job.** Trigger a workflow that targets the labels, e.g.:

   ```yaml
   jobs:
     bootstrap:
       runs-on: [self-hosted, lab-supervisor]
       steps:
         - run: echo "hello from the supervisor runner"
   ```

4. **Watch it run one job and exit.** The runner logs show the job running, then
   `Runner listener exit ...` and the pod terminates. Because the registration
   was ephemeral/JIT, the runner **removes itself** from the repo's Runners list
   — no stale "offline" entry is left behind.

5. **Watch the recycle.** The `Deployment` immediately recreates the pod; the
   init container mints a brand-new JIT config and the runner returns to
   `Listening for Jobs`, ready for the next job.

## Updating the runner version

The runner image is pinned in `04-deployment.yaml`:

```yaml
image: ghcr.io/actions/runner:2.335.1
```

To upgrade, check
[github.com/actions/runner/releases](https://github.com/actions/runner/releases)
for the latest stable tag and bump the version (the image tag is the release
version without the leading `v`). GitHub requires self-hosted runners to stay
reasonably current, so update this periodically.

## Terraform Kubernetes backend (for the workflows that run here)

The RBAC in `01-serviceaccount-rbac.yaml` grants exactly what the
[Kubernetes backend](https://developer.hashicorp.com/terraform/language/settings/backends/kubernetes)
needs in the `github-runners` namespace: `secrets` (state) and `leases`
(locking). Configure Terraform like:

```hcl
terraform {
  backend "kubernetes" {
    secret_suffix = "bootstrap"
    namespace     = "github-runners"
    in_cluster_config = true   # uses the pod's ServiceAccount token
  }
}
```

Because `in_cluster_config = true`, Terraform authenticates as the
`github-runner` ServiceAccount and the backend can read/write its state Secret
and acquire its lock Lease without any extra credentials.
