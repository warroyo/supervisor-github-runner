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
  github-app Secret ─┐     ┌──────────────────── Pod ─────────────────────┐
  (App key, as env)  └────►│ container: minter           (mint.sh)         │
  github-runner          ┌►│   JWT → installation token (cached 50 min)    │
  ConfigMap ─────────────┘ │   POST .../generate-jitconfig                 │
  (GITHUB_URL)             │   write config ──────────┐                    │
                           │   wait until GitHub no   │                    │
                           │   longer lists the runner│                    │
                           │                          ▼ handoff (emptyDir) │
                           │ container: runner      (entrypoint.sh)        │
                           │   wait for config, read and delete it         │
                           │   empty _work                                 │
                           │   run.sh --jitconfig → ONE job, deregisters   │
                           │   kill leftover processes, loop               │
                           └───────────────────────────────────────────────┘
```

The runner is ephemeral. Each config is a Just-In-Time registration, the runner
picks up exactly one job, deregisters itself, and the runner list never fills
up with stale "offline" entries.

The pod has two containers, both from the same stock image. `minter` runs
`mint.sh`. It's the only container with the GitHub App key. It mints one JIT
config at a time and drops it in a shared `handoff` volume. `runner` runs
`entrypoint.sh`, a loop: wait for a config, run one job with it, kill whatever
the job left running, wait for the next one. It never exits, so Kubernetes
never applies restart backoff, and the next job starts within seconds of the
last one finishing.

`minter` mints the next config only after GitHub no longer lists the previous
runner. It polls the runner every 10 seconds, treats a 404 as gone, then waits
5 more seconds. If a runner took its config and stays offline for 180 seconds,
it died without leaving GitHub, so `minter` deletes it through the API and mints
the next. It caches the installation token and gets a new one after 50 minutes.
Errors are retried every 30 seconds; the container doesn't exit.

There's nothing custom to build or host. Both scripts live in a ConfigMap, and
they only use what the unmodified `ghcr.io/actions/actions-runner` image already
ships: `curl`, `jq`, and `openssl`. The only state is the `work` directory, an
`emptyDir` that the script empties before each job. If a workflow needs durable
state, keep it off the runner and in a remote backend (an object store, a
Terraform remote backend, and so on).

Why a sidecar and not an init container for the minting: Kubernetes runs init
containers once per pod, not once per job. The runner needs a new config after
every job, so something has to keep running next to it, and that's `minter`.
It's also what keeps the key out of the container that runs your jobs.

## Security model

The pod is built to pass Supervisor's restricted Pod Security profile, so:
`runAsNonRoot`, no privilege escalation, all capabilities dropped,
`RuntimeDefault` seccomp, no host networking or PID, nothing privileged, and no
Docker-in-Docker. It runs as UID 1001 — that's the `runner` user the official
image ships with.

The App private key reaches only the `minter` container, as an environment
variable, not a mounted file. It signs through a pipe, so the key never lands on
disk. Jobs run in the `runner` container, which has no App credentials at all.
The containers don't share a process namespace, so a job can't read the
minter's environment or `/proc`. In testing, a job saw no `GITHUB_APP_*`
variables.

A job also can't get a config for a runner of its own. `minter` only mints after
the job's runner has left GitHub, and the `runner` container kills every
leftover process before that. Each job still gets a fresh one-time JIT
registration.

One thing changed from running one container per job: the container now
persists across jobs. The workspace (`_work`) is emptied between jobs, but the
rest of the container's filesystem isn't, so something a job writes to the home
directory, like a cache or a config file, is still there for the next job.
Don't treat the runner as clean between jobs outside `_work`.

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
| `base/mint.sh` | The `minter` container: holds the App key and mints one JIT config at a time. |
| `base/entrypoint.sh` | The `runner` container: loops, running one job per config. |
| `base/kustomization.yaml` | Ties them together; the two scripts become a ConfigMap. |
| `examples/org/` | An overlay showing how to change replicas, labels, memory, and disk. |
| `.github/dependabot.yml` | Keeps the pinned runner image current. |

## Before you start

You'll need a Supervisor Namespace already created in vCenter, and a `kubectl`
context pointed at it. The pod is already written to satisfy the restricted Pod
Security profile, so you shouldn't have to touch any of that. The one thing
worth checking is egress: the namespace needs to reach `ghcr.io` to pull the
image, plus `github.com`, `api.github.com`, and `*.actions.githubusercontent.com`
for the runner itself.

## 1. Create the GitHub App

This uses a GitHub App rather than a personal access token, so there's no
long-lived user token sitting in the cluster — `minter` mints a fresh,
short-lived installation token about every 50 minutes.

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

For more than the defaults — more runners, more memory, more disk — copy
[`examples/org`](examples/org) and apply that instead. One pod is one runner
and takes one job at a time, so `replicas` is how many jobs run at once.

## 5. Check that it works

```sh
kubectl -n <namespace> get pods -w
kubectl -n <namespace> logs deploy/github-runner -c minter -f
kubectl -n <namespace> logs deploy/github-runner -c runner -f
```

`minter` should print `Minted runner <pod-name>-<suffix>`. In the `runner` log
you're looking for `Connected to GitHub` followed by `Listening for Jobs`. Over
in GitHub, under Settings → Actions → Runners, you should see a runner with that
name and your labels.

If `minter` stops earlier, it prints the GitHub API call that failed and
GitHub's answer, then tries again in 30 seconds. A `404` on `/installation`
means the App isn't installed on that organization or repository; a `403` on
`generate-jitconfig` means the permission from step 1 is missing.

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
the way out — no leftover "offline" entry. The runner loops, so the next job
starts within seconds: `minter` waits for the old runner to leave GitHub, mints
a new config, and `runner` is back to `Listening for Jobs`.

## Disk space

A job gets 4 GB of disk, mounted at the runner's work directory. That's where
the checkout, downloaded tools, and things like Terraform providers land.

It's worth knowing why that number is set at all. A vSphere Pod only gets
about 250 MB of disk unless it asks for more, and a job that runs out fails
with `no space left on device` — `terraform init` hits it on the first
provider download. The pod has to ask in two places, and it needs both: the
container's `ephemeral-storage` request and limit, and the `sizeLimit` on the
`work` volume. Keep the two equal.

The disk belongs to the pod. It's created with the pod and deleted with it, so
there's no PersistentVolumeClaim and nothing left behind to clean up. The
[`examples/org`](examples/org) overlay shows how to make it bigger.

## Deleting the pod cancels its job

Anything that deletes the pod takes the running job with it: a rollout (the
Deployment uses `strategy: Recreate`), scaling down, `kubectl delete pod`, or
the host going into maintenance. The runner gets the default 30 seconds to
stop, and GitHub marks the job as cancelled or failed.

For most jobs that just means running it again. For a job that changes real
things it's worse — a `terraform apply` stopped halfway leaves a half-applied
change and a state lock that nobody holds, which you clear with
`terraform force-unlock`. So check that the runner is idle before you roll it
out, bump the image, or scale down:

```sh
kubectl -n <namespace> logs deploy/github-runner -c runner --tail=5
```

`Listening for Jobs` as the last line means it's safe. `Running job: ...`
means wait.

## Bumping the runner version

The runner image is pinned in `base/deployment.yaml`:

```yaml
image: ghcr.io/actions/actions-runner:2.338.0
```

When a new release lands on
[github.com/actions/runner/releases](https://github.com/actions/runner/releases),
bump the tag (it's the release version minus the leading `v`). GitHub expects
self-hosted runners to stay reasonably current, and one that falls too far
behind stops getting jobs without telling you.

This repo has a Dependabot config (`.github/dependabot.yml`) that opens a pull
request for each new image. If you apply the base straight from GitHub, the new
version reaches you the next time you run `kubectl apply -k`. If you keep your
own copy, point Dependabot or Renovate at it the same way.

## License

[Apache-2.0](LICENSE)
