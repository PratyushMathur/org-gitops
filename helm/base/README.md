# base

Org-wide Helm **library chart**. Every application chart in this repo depends on
it instead of carrying its own copy of a `helm create` scaffold.

It renders the standard object set — ServiceAccount, ConfigMap, Deployment,
Service, Ingress, HTTPRoute, HPA, PodDisruptionBudget — from one shared set of
templates, and supplies the defaults an app chart would otherwise have to
restate.

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
templates instead (`base.deployment`, `base.rollout`, `base.service`,
`base.httproute`, `base.gateway`, `base.configmap`, `base.serviceaccount`),
alongside their own hand-written templates in the same directory.

## Getting traffic in

`httpRoute` is the only north-south path, off by default. It renders an
`HTTPRoute` that attaches to a `Gateway` someone else owns (`helm/gateway`), so
enabling it creates no load balancer of its own. A canary split is expressed as
weighted `backendRefs` on that one object.

The Ingress path was removed in base 0.5.0: the prod clusters run neither
ingress-nginx nor cert-manager and front apps with the GKE Gateway instead.

```yaml
httpRoute:
  enabled: true
  parentRefs:
    - name: api           # the Gateway, by name
      sectionName: http   # which listener
  hostnames: [api-us.pynd.dev]
  paths:
    - path: /companies
      pathType: PathPrefix   # "Prefix" is accepted too
      servicePort: http      # name from service.ports, or a number
```

Anything `paths` cannot express — redirects, rewrites, header mutation — goes in
`httpRoute.extraRules` as raw Gateway API rules, appended after the generated
ones.

Two routes on one Gateway must not claim the same hostname **and** the same
path. Gateway API settles that conflict by creation timestamp, so the loser
stops serving without erroring. Where several apps share a hostname, give each
its own path prefix.

### The Gateway itself

`base.gateway` is deliberately **not** part of `base.all`. A Gateway is
per-cluster infrastructure shared by every app; if each app chart rendered one
they would fight over the same static IP. Exactly one chart renders it —
[`helm/gateway`](../gateway) — and app charts reference it by name:

```yaml
# helm/gateway/values.yaml
gateway:
  enabled: true
  name: api
  className: gke-l7-regional-external-managed
  addressName: api-us     # a reserved static IP, claimed by name
```

The IP is named rather than written literally, so recreating the Gateway does
not renumber the DNS record that Terraform published for it.

## Progressive delivery (Argo Rollouts)

The preferred path. `rollout.enabled` swaps the Deployment for an argoproj.io
**Rollout** and hands the canary to the Argo Rollouts controller, which creates
the canary ReplicaSet whenever the pod template changes, walks `rollout.steps`,
and rewrites the weights on the app's HTTPRoute through the Gateway API
traffic-router plugin.

```yaml
# values.yaml
image:
  tag: "1.0.2"        # changing this is what starts a rollout
rollout:
  enabled: true
  steps:
    - setWeight: 20
    - pause: {}       # waits for `kubectl argo rollouts promote <name>`
    - setWeight: 50
    - pause: {}
```

The trailing `pause` above is deliberate and safe **because the last rung is
below 100**: it parks at 50% until a human decides to finish, and promoting from
there runs the rollout out of steps and completes it.

> **Do not put a `pause` after a `setWeight: 100`.** There is no traffic decision
> left at 100%, so the rollout parks reporting `Paused` (and Argo reports the app
> `Suspended`) with nothing waiting on it. Because it has not *completed*, the
> controller correctly holds the old stable ReplicaSet at full size — that is what
> makes an abort instant — so the old pods are never recycled and it reads as a
> stuck release. End the ladder on the `setWeight` instead and it completes on its
> own. `helm/company/values.yaml` does exactly that.

`base.all` then renders a Rollout, a `<name>-canary` Service and a second
HealthCheckPolicy for it. There is no second image tag to pin: the canary is
whatever the next `image.tag` is, and rolling back is `kubectl argo rollouts
undo` rather than another commit.

The HTTPRoute ships with both backends at **100/0**. The plugin reweights
backends that are already on the route — it does not add them — so a route
carrying only the stable Service would leave the rollout progressing on paper
while every request kept landing on stable.

Requires `httpRoute.enabled` and the controller from `helm/argo-rollouts`. It is
mutually exclusive with `canary` below, and the render fails if both are on.

**`track` is a pod label, not a ConfigMap key.** Both tracks share one pod
template now, so `TRACK` comes from the label through the downward API —
defaulted to `stable`, overridden to `canary` by `canaryMetadata`. The label is
kept out of the selector so both Services still match both tracks; Argo Rollouts
separates them with its own `rollouts-pod-template-hash`.

Note the value is a snapshot. Downward API *env vars* resolve once at container
start, so after a promotion — when Rollouts relabels the pods `stable` — the
processes keep reporting `canary` until they are replaced. Read it as "the track
this pod was introduced in".

## VERSION and TRACK

Any chart that sets `config` gets two keys injected into its ConfigMap:

| Key | Value |
| --- | --- |
| `VERSION` | the image tag (or `Chart.appVersion`) |
| `TRACK` | `stable`, or `canary` on the canary track |

`VERSION` is derived from the image tag rather than restated in `config`, so the
version a workload reports can never drift from the image it is running. A chart
that sets either key explicitly still wins.

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
  template so pods roll when it changes. `VERSION` and `TRACK` are injected —
  see above. For file-style config, declare a ConfigMap under `extraObjects`
  and mount it via `volumes`/`volumeMounts`.
- `ports` — container ports. `service.ports` and probes refer to them by name.
- `httpRoute.paths[]` — the same three keys, except `pathType` defaults to
  `PathPrefix` and also accepts Ingress's `Prefix` spelling. `httpRoute.hostnames`
  is a top-level list, not per-path as on an Ingress.
- `httpRoute.parentRefs` — which Gateway and listener to attach to. Required
  when `httpRoute.enabled`.
- `httpRoute.extraRules` — raw Gateway API rules appended after the generated
  ones, for redirects, rewrites and header mutation.
- `gateway` — the Gateway object. Not in `base.all`; rendered only by
  `helm/gateway`. See the traffic section above.
- `initContainers` / `sidecars` — raw container specs appended to the pod.
- `extraObjects` — raw manifests appended to the release, each run through
  `tpl`, so `{{ include "base.fullname" . }}` works inside them. Entries must be
  **maps, not strings**: they are serialised with `toYaml` before templating, so
  a string entry renders as a YAML block scalar and fails to parse. For the same
  reason, only scalars can be templated — a helper emitting a multi-line block,
  such as `include "base.labels"`, cannot be substituted into a value there.

## Changing this chart

It is a dependency of every app, so a change here ships everywhere on the next
sync. Bump `version` in `Chart.yaml`, and bump the `version` constraint in each
consuming chart's `Chart.yaml` when the change is not backwards compatible.
Verify with `helm template` against at least one consuming chart before merging.
