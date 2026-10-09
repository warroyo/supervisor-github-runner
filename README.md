# supervisor-github-runner

A self-hosted GitHub Actions runner that runs as a
[vSphere Pod](https://techdocs.broadcom.com/us/en/vmware-cis/vsphere/vsphere-supervisor/8-0/using-tkg-service-with-vsphere-supervisor/deploying-workloads-to-vsphere-pods.html)
on a vSphere Supervisor cluster. It can serve a whole GitHub organization or a
single repository.

It's a generic way to run GitHub Actions on Supervisor — any workflow that can
run inside a restricted, unprivileged pod works here, not just one kind of job.
The whole thing leans on nothing fancy: no CRDs, no operators, no Helm, just a
plain `Secret`, `ConfigMap`, and `Deployment`. If you can `kubectl apply` it,
you can run it. Nothing in the manifests is specific to Supervisor either, so
they work on any Kubernetes cluster that enforces the restricted profile.

The one real limitation is building container images. Supervisor enforces a
restricted Pod Security profile — no privileged containers, no Docker-in-Docker
— so workflows that build images (`docker build`, plain Buildah/Kaniko that
need privileges, etc.) won't run here. Container actions and `services:` are
out for the same reason. Everything else — Terraform, CLIs, tests, deploys, API
calls — is fair game. A common use is bootstrap work: running the Terraform
that stands up the rest of the infrastructure before anything heavier exists to
run it on.

A note on the namespace before you start: on Supervisor you don't create
namespaces with YAML. They're Supervisor Namespaces, created in vCenter under
Workload Management → Namespaces, and that's where their resource limits,
storage, and Pod Security policy come from. So there's no `namespace.yaml` in
here, and the manifests don't name a namespace at all — you pick it with `-n`
when you apply.

## How it works

```
                 ┌──────────────────── Pod ─────────────────────┐
                 │                                               │
  github-app     │  container: runner (ghcr.io/actions/actions-runner)
  Secret  ──────►│    entrypoint.sh                              │
  (App key,      │      1. sign JWT with App private key (RS256) │
   as env)       │      2. JWT → installation access token       │
                 │      3. POST .../generate-jitconfig           │
  github-runner  │      4. unset the key and the token           │
  ConfigMap ────►│      5. exec run.sh --jitconfig ...           │
  (GITHUB_URL)   │           → runs exactly ONE job,             │
                 │             deregisters, exits                │
                 └───────────────────────────────────────────────┘
                   container exits → kubelet restarts it → fresh JIT config
```

The runner is ephemeral. On every start, `entrypoint.sh` mints a Just-In-Time
runner config, the runner picks up exactly one job, deregisters itself, and
exits. That means the runner list never fills up with stale "offline" entries.
When the runner exits, Kubernetes restarts the container, the script mints a
fresh config, and you're ready for the next job.

There's nothing custom to build or host. The token-minting logic is a shell
script living in a ConfigMap, and it only uses what the unmodified
`ghcr.io/actions/actions-runner` image already ships: `curl`, `jq`, and
`openssl`. Nothing persists either — the work directory is an `emptyDir`, and
the script empties it before each job. If a workflow needs durable state, keep
it off the runner and in a remote backend (an object store, a Terraform remote
backend, and so on).

Why one container and not an init container for the minting: Kubernetes runs
init containers once per pod, not once per container restart. A runner that
exits after its job gets restarted in place, the init container doesn't run
again, and the runner comes back with a JIT config that has already been used.

## Security model

The pod is built to pass Supervisor's restricted Pod Security profile, so:
`runAsNonRoot`, no privilege escalation, all capabilities dropped,
`RuntimeDefault` seccomp, no host networking or PID, nothing privileged, and no
Docker-in-Docker. It runs as UID 1001 — that's the `runner` user the official
image ships with.

The App private key reaches the container as an environment variable, not a
mounted file. `entrypoint.sh` signs with it through a pipe, so it never lands
on disk, then unsets it along with the installation token before it `exec`s the
runner. Workflow code runs as a child of that process, so it never has the key
or the token in its environment, and there's no file to read them from.

The pod sets `automountServiceAccountToken: false`, so the untrusted workflow
code the runner executes gets no Kubernetes API token at all.

One thing to keep in mind for organization runners: every repository allowed to
use the runner group can run code in this pod, inside your network. On the
Default group, leave "Allow public repositories" off — otherwise a pull request
from a fork gets to run there too.

## What's in here

| Path | What it does |
|------|--------------|
| `base/deployment.yaml` | The runner Deployment. |
| `base/entrypoint.sh` | Mints the JIT config and starts the runner. |
| `base/kustomization.yaml` | Ties the two together; the script becomes a ConfigMap. |
| `examples/org/` | An overlay showing how to change replicas, labels, and memory. |

## Before you start

You'll need a Supervisor Namespace already created in vCenter, and a `kubectl`
context pointed at it. The pod is already written to satisfy the restricted Pod
Security profile, so you shouldn't have to touch any of that. The one thing
worth checking is egress: the namespace needs to reach `ghcr.io` to pull the
image, plus `github.com`, `api.github.com`, and `*.actions.githubusercontent.com`
for the runner itself.

## 1. Create the GitHub App

This uses a GitHub App rather than a personal access token, so there's no
long-lived user token sitting in the cluster — the script mints a fresh,
short-lived installation token every time the container starts.

Head to Settings → Developer settings → GitHub Apps → New GitHub App (under the
org or user that owns what the runner will serve), and:

- Give it any name, e.g. `supervisor-runner`, and any homepage URL.
- Uncheck **Webhook → Active**; this App isn't driven by webhooks.
- Set the one permission it needs, and leave everything else on No access:
  - for an **organization** runner: under organization permissions,
    **Self-hosted runners** → **Read and write**.
  - for a **repository** runner: under repository permissions,
    **Administration** → **Read and write**.
- Set it to be installable on this account only, then create it.

Once it's created, grab the numeric App ID from the settings page, then scroll
down to Private keys and generate one. GitHub hands you a `.pem` file — hang
onto it, that's your signing key.

Last step, install the App: Install App in the sidebar → Install. For a
repository runner, pick "Only select repositories" and choose the repo.

## 2. Create the Secret

Straight from the files you just downloaded:

```sh
kubectl -n <namespace> create secret generic github-app \
  --from-literal=app-id='YOUR_APP_ID' \
  --from-file=private-key.pem=./your-app.private-key.pem
```

## 3. Say what the runner serves

```sh
kubectl -n <namespace> create configmap github-runner \
  --from-literal=GITHUB_URL=https://github.com/YOUR_ORG
```

`GITHUB_URL` decides the scope: `https://github.com/<org>` for an organization,
`https://github.com/<owner>/<repo>` for one repository. The rest is optional:

| Key | Default | What it is |
|-----|---------|------------|
| `GITHUB_URL` | none, required | Organization or repository the runner registers to. A GitHub Enterprise Server host works too. |
| `RUNNER_LABELS` | `self-hosted,supervisor` | The runner's labels, comma separated. These are all of them — nothing is added. |
| `RUNNER_GROUP_ID` | `1` | Numeric ID of the runner group. `1` is the Default group. |

The pod reads the ConfigMap when it starts, so after a change run
`kubectl -n <namespace> rollout restart deploy/github-runner`.

## 4. Apply

No clone needed:

```sh
kubectl -n <namespace> apply -k 'https://github.com/warroyo/supervisor-github-runner//base?ref=main'
```

Or from a checkout: `kubectl -n <namespace> apply -k base`.

For more than the defaults — more runners, more memory — copy
[`examples/org`](examples/org) and apply that instead. One pod is one runner
and takes one job at a time, so `replicas` is how many jobs run at once.

## 5. Check that it works

```sh
kubectl -n <namespace> get pods -w
kubectl -n <namespace> logs deploy/github-runner -f
```

You're looking for `Registered runner <pod-name>-<suffix>`, then
`Connected to GitHub` followed by `Listening for Jobs`. Over in GitHub, under
Settings → Actions → Runners, you should see a runner with that name and your
labels.

If the script stops earlier, it prints the GitHub API call that failed and
GitHub's answer. A `404` on `/installation` means the App isn't installed on
that organization or repository; a `403` on `generate-jitconfig` means the
permission from step 1 is missing.

Now give it something to do. Trigger a workflow that targets those labels:

```yaml
jobs:
  bootstrap:
    runs-on: [self-hosted, supervisor]
    steps:
      - run: echo "hello from the supervisor runner"
```

Watch the runner logs run the job and print `Runner listener exit ...`. Because
the registration was JIT, the runner takes itself out of the Runners list on
the way out — no leftover "offline" entry. A moment later the container is
back, the script mints a new config, and it's back to `Listening for Jobs`.

Kubernetes backs off between restarts of the same container: after several
short jobs in a row the wait grows, up to five minutes, and a queued job waits
with it. It resets once a runner has been up for ten minutes.

## Bumping the runner version

The runner image is pinned in `base/deployment.yaml`:

```yaml
image: ghcr.io/actions/actions-runner:2.338.0
```

When a new release lands on
[github.com/actions/runner/releases](https://github.com/actions/runner/releases),
bump the tag (it's the release version minus the leading `v`). GitHub expects
self-hosted runners to stay reasonably current, so it's worth checking in on
this now and then.

## License

[Apache-2.0](LICENSE)
