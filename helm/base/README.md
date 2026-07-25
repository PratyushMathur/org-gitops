# base

Org-wide Helm **library chart**. Every application chart in this repo depends on
it instead of carrying its own copy of a `helm create` scaffold.

It renders the standard object set — ServiceAccount, ConfigMap, Deployment,
Service, Ingress, HPA, PodDisruptionBudget — from one shared set of templates,
and supplies the defaults an app chart would otherwise have to restate.

## Using it

`Chart.yaml`:

```yaml
apiVersion: v2
name: my-app
type: application
version: 0.1.0
appVersion: "1.2.3"

dependencies:
  - name: base
    version: 0.1.0
    repository: "file://../base"
```

`templates/all.yaml` — the whole templates directory:

```yaml
{{ include "base.all" . }}
```

`values.yaml` — only the deltas from the defaults below.

Then `helm dependency update .` once, and commit the resulting `Chart.lock`.

Charts needing finer control can skip `base.all` and include the individual
templates instead (`base.deployment`, `base.service`, `base.ingress`,
`base.hpa`, `base.pdb`, `base.configmap`, `base.serviceaccount`), alongside
their own hand-written templates in the same directory.

## How defaults work

Helm does **not** merge a library chart's `values.yaml` into the parent, so
defaults cannot live in `values.yaml`. They are declared as YAML in
`templates/_defaults.tpl` (`base.defaultValues`) and deep-merged with the app
chart's `.Values` at render time by `base.values`. App values win.

One consequence worth knowing: because it is a deep merge, setting a defaulted
block to `{}` does **not** clear it. To drop a default, either set the specific
fields (`securityContext: {readOnlyRootFilesystem: false}`) or set the whole
block to `null`.

## Opinions baked in

These are the defaults that differ from a stock `helm create`:

| Setting | Default | Why |
| --- | --- | --- |
| `replicaCount` | `2` | Single replicas have no rollout headroom. |
| `strategy.rollingUpdate.maxUnavailable` | `0` | Surge up before terminating. |
| `revisionHistoryLimit` | `3` | Stock 10 clutters `kubectl get rs`. |
| `serviceAccount.automount` | `false` | Most workloads never call the API server. |
| `podSecurityContext` | `runAsNonRoot`, `RuntimeDefault` seccomp | Baseline hardening. No `runAsUser` — the image must declare a non-root `USER`, which keeps this portable across base images. |
| `securityContext` | drop `ALL`, no privilege escalation, read-only rootfs | Baseline hardening. |
| `resources` | requests set; **memory limit only** | CPU limits throttle rather than protect. |
| `ports[0].containerPort` | `8080` | Non-root images cannot bind `:80`. |
| `pdb.enabled` | `false` | A PDB over a single replica blocks node drains. |

## Values reference

`templates/_defaults.tpl` is the source of truth and is commented. Beyond the
table above, the notable keys are:

- `image.registry` / `repository` / `tag` / `digest` / `pullPolicy` —
  `repository` is required; `digest` wins over `tag`; `tag` falls back to
  `Chart.appVersion`.
- `component` / `partOf` — populate `app.kubernetes.io/component` and
  `.../part-of`.
- `commonLabels` / `commonAnnotations` — applied to every rendered object.
- `config` — a flat key/value map. Rendered as a ConfigMap, wired into the
  container via `envFrom`, and hashed into `checksum/config` on the pod
  template so pods roll when it changes. For file-style config, declare a
  ConfigMap under `extraObjects` and mount it via `volumes`/`volumeMounts`.
- `ports` — container ports. `service.ports` and probes refer to them by name.
- `ingress.hosts[].paths[]` — `path`, `pathType` (default `Prefix`), and
  optional `servicePort` (name or number, defaults to `http`).
- `initContainers` / `sidecars` — raw container specs appended to the pod.
- `extraObjects` — raw manifests appended to the release, each run through
  `tpl`, so `{{ include "base.fullname" . }}` works inside them.

## Changing this chart

It is a dependency of every app, so a change here ships everywhere on the next
sync. Bump `version` in `Chart.yaml`, and bump the `version` constraint in each
consuming chart's `Chart.yaml` when the change is not backwards compatible.
Verify with `helm template` against at least one consuming chart before merging.
