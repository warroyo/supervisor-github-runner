# supervisor-github-runner

A self-hosted GitHub Actions runner that runs as a single
[vSphere Pod](https://techdocs.broadcom.com/us/en/vmware-cis/vsphere/vsphere-supervisor/8-0/using-tkg-service-with-vsphere-supervisor/deploying-workloads-to-vsphere-pods.html)
on a vSphere Supervisor cluster.

It's a generic way to run GitHub Actions on Supervisor — any workflow that can
run inside a restricted, unprivileged pod works here, not just one kind of job.
The whole thing leans on nothing fancy: no CRDs, no operators, no Helm, just
plain `ServiceAccount`, `Role`, `Secret`, `ConfigMap`, and `Deployment`. If you
can `kubectl apply` it, you can run it.

The one real limitation is building container images. Supervisor enforces a
restricted Pod Security profile — no privileged containers, no Docker-in-Docker
— so workflows that build images (`docker build`, plain Buildah/Kaniko that
need privileges, etc.) won't run here. Everything else — Terraform, CLIs, tests,
deploys, API calls — is fair game. A common use is bootstrap work: running the
Terraform that stands up the rest of the infrastructure before anything heavier
exists to run it on.

A note on the namespace before you start: on Supervisor you don't create
namespaces with YAML. They're Supervisor Namespaces, created in vCenter under
Workload Management → Namespaces, and that's where their resource limits,
storage, and Pod Security policy come from. So there's no `namespace.yaml` in
here — the manifests assume the namespace already exists. They're written for a
namespace called `github-runners`; either name yours that, or do a
find-and-replace on the `namespace:` field.

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

The runner is ephemeral. An init container mints a Just-In-Time runner config,
the runner picks up exactly one job, deregisters itself, and exits. That means
the repo's runner list never fills up with stale "offline" entries. When the
runner exits, the Deployment recreates the pod, the init container mints a fresh
config, and you're ready for the next job.

The interesting bit is the split between the two containers. The init container
does all the privileged GitHub work — signing the App JWT, trading it for an
installation token, asking for a JIT config — and the App private key is only
ever mounted there. The runner container, which is where untrusted workflow code
actually executes, never sees the key or the token. The two hand off through a
shared `emptyDir`: the init container writes the JIT config, the runner reads it.

There's nothing custom to build or host. The token-minting logic is a Python
script living in a ConfigMap, run by the stock `python:3-slim` image, and the
runner is the unmodified `ghcr.io/actions/runner` image. Nothing persists
either — the work directory is an `emptyDir`, wiped on every restart. If a
workflow needs durable state, keep it off the runner and in a remote backend
(an object store, a Terraform remote backend, and so on).

## Security model

The pod is built to pass Supervisor's restricted Pod Security profile, so:
`runAsNonRoot`, no privilege escalation, all capabilities dropped,
`RuntimeDefault` seccomp, no host networking or PID, nothing privileged, and no
Docker-in-Docker.

Both containers run as UID 1001 — that's the `runner` user the official image
ships with — and the pod sets `fsGroup: 1001` so the runner can read the JIT
file the init container drops on the shared volume (written `0600`). The
`github-app` Secret is mounted into the init container only. The runner has its
own ServiceAccount but no RBAC and no mounted token, so the untrusted workflow
code it runs can't reach the Kubernetes API at all. And with `replicas: 1` plus
`strategy: Recreate`, there's only ever one runner identity alive at a time.

## What's in here

Apply them in order; the numbers are the order.

| File | What it does |
|------|--------------|
| `01-serviceaccount.yaml` | The runner's ServiceAccount — no RBAC, no mounted token. |
| `02-secret.yaml` | The GitHub App ID and private key (placeholders for now). |
| `03-configmap-jitconfig.yaml` | The Python token-minting script. |
| `04-deployment.yaml` | The init container, the runner container, and the shared `emptyDir` between them. |

(No `00-namespace.yaml` on purpose — see the namespace note up top.)

## Before you start

You'll need a Supervisor Namespace called `github-runners` (or your own name,
with the manifests adjusted) already created in vCenter, and a `kubectl` context
pointed at it. The pod is already written to satisfy the restricted Pod Security
profile, so you shouldn't have to touch any of that. The one thing worth
checking is egress: the Supervisor needs to reach `api.github.com`, and the init
container needs `ghcr.io` plus PyPI so it can `pip install PyJWT` on startup.

## 1. Create the GitHub App

This uses a GitHub App rather than a personal access token, so there's no
long-lived user token sitting in the cluster — the init container mints a
fresh, short-lived installation token every time the pod starts.

Head to Settings → Developer settings → GitHub Apps → New GitHub App (under your
user or org), and:

- Give it any name, e.g. `lab-supervisor-runner`, and any homepage URL.
- Uncheck **Webhook → Active**; this App isn't driven by webhooks.
- Under repository permissions, set **Self-hosted runners** to **Read and
  write**. That's the only permission it needs — leave everything else on No
  access.
- Set it to be installable on this account only, then create it.

Once it's created, grab the numeric App ID from the settings page, then scroll
down to Private keys and generate one. GitHub hands you a `.pem` file — hang
onto it, that's your signing key.

Last step, install the App on the repo it'll serve: Install App in the sidebar →
Install → pick "Only select repositories" → choose the repo.

## 2. Create the Secret

Easiest to do this straight from the files you just downloaded — it sidesteps
the base64 and whitespace headaches of pasting a multi-line PEM into YAML:

```sh
kubectl -n github-runners create secret generic github-app \
  --from-literal=app-id='YOUR_APP_ID' \
  --from-file=private-key.pem=./your-app.private-key.pem
```

That gives you the same `github-app` Secret that `02-secret.yaml` describes. If
you'd rather keep it in Git, edit `02-secret.yaml` instead and run it through
something like SOPS or Sealed Secrets — just don't commit a plaintext key.

## 3. Fill in the repo placeholders

Open `04-deployment.yaml` and point it at your repo by replacing the two
placeholders in the init container's env:

```yaml
- name: REPO_OWNER
  value: "REPLACE_WITH_REPO_OWNER"   # e.g. "warroyo"
- name: REPO_NAME
  value: "REPLACE_WITH_REPO_NAME"    # e.g. "supervisor-github-runner"
```

If you went the declarative route in step 2, remember to fill in the `app-id`
and `private-key.pem` placeholders in `02-secret.yaml` too.

## 4. Apply

With the namespace already in place:

```sh
kubectl apply -f 01-serviceaccount.yaml
kubectl apply -f 02-secret.yaml            # skip if you used `kubectl create secret`
kubectl apply -f 03-configmap-jitconfig.yaml
kubectl apply -f 04-deployment.yaml
```

## 5. Check that it works

First, watch the pod come up and make sure the init container did its job:

```sh
kubectl -n github-runners get pods -w
kubectl -n github-runners logs deploy/github-runner -c mint-jitconfig
```

The init log should finish with something like
`Wrote JIT config for runner '<pod-name>' to /runner-config/jitconfig`.

Then tail the runner itself:

```sh
kubectl -n github-runners logs deploy/github-runner -c runner -f
```

You're looking for `Connected to GitHub` followed by `Listening for Jobs`. Over
in the repo, under Settings → Actions → Runners, you should see a runner named
after the pod, tagged `self-hosted, lab-supervisor`.

Now give it something to do. Trigger a workflow that targets those labels:

```yaml
jobs:
  bootstrap:
    runs-on: [self-hosted, lab-supervisor]
    steps:
      - run: echo "hello from the supervisor runner"
```

Watch the runner logs run the job, print `Runner listener exit ...`, and the pod
terminates. Because the registration was JIT, the runner takes itself out of the
repo's Runners list on the way out — no leftover "offline" entry. A moment
later the Deployment brings the pod back, the init container mints a new config,
and it's back to `Listening for Jobs` waiting on the next one.

## Bumping the runner version

The runner image is pinned in `04-deployment.yaml`:

```yaml
image: ghcr.io/actions/runner:2.335.1
```

When a new release lands on
[github.com/actions/runner/releases](https://github.com/actions/runner/releases),
bump the tag (it's the release version minus the leading `v`). GitHub expects
self-hosted runners to stay reasonably current, so it's worth checking in on
this now and then.
