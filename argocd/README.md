# Argo CD

```
argocd/
├── bootstrap/
│   └── root-app.yaml            # the only object applied by hand
├── projects/
│   └── apps-prod.yaml           # AppProject: *-prod
└── applicationsets/
    └── apps-prod.yaml           # manual sync
```

One environment, **prod**. A second one is an AppProject + ApplicationSet pair
here plus a directory under `environments/`; nothing else changes.

## How an app gets deployed

No `Application` manifests are written by hand. Each ApplicationSet is a
**matrix** of two generators:

```
clusters(env=<env>)  ×  git files(environments/<env>/*/config.yaml)
        where                       what
```

giving one Application per app **per cluster**, named
`<app>-<env>-<cluster>`.

`config.yaml` is the registration record. It deliberately carries no cluster —
it says what runs, not where:

```yaml
app: company
env: prod
chartPath: helm/company
namespace: demo
argoProject: apps-prod
```

The AppProject key is `argoProject`, not `project`, because the cluster
generator contributes a `project` parameter of its own — empty unless the
cluster Secret is project-scoped — and in a matrix generator it shadows
anything of the same name coming from `config.yaml`.

Adding an app to an environment is one new directory. Nothing in `argocd/`
changes.

## Clusters

Clusters are identified by a **label on their Argo CD cluster Secret**, never by
a hardcoded API URL:

```bash
argocd cluster add <kube-context> --name cluster-a --label env=prod --label region=in
argocd cluster add <kube-context> --name cluster-b --label env=prod --label region=us
```

Prod currently spans **cluster-a** and **cluster-b**; every app registered under
`environments/prod/` is deployed to both. Rolling out to a new prod cluster is
two steps, on purpose:

1. label its cluster Secret `env=prod` — it is now *discovered*
2. add its name to `destinations` in `argocd/projects/apps-prod.yaml` — it is
   now *authorised*

Discovery and authorisation are separated so a mislabelled cluster cannot
silently start receiving production workloads.

The Application's `destination.name` is the cluster name from the generator, so
the AppProject `destinations` match on `name` rather than `server`.

## Values layering

Three layers, lowest to highest:

1. `helm/base` — org defaults (`templates/_defaults.tpl`)
2. `helm/<app>/values.yaml` — **all** app and environment settings
3. `environments/<env>/<app>/overrides-<region>.yaml` — per-region overrides,
   **optional** (`ignoreMissingValueFiles: true`)

There is deliberately **no per-environment layer**. `helm/<app>/values.yaml` is
the single source of values, so every environment would deploy the same
configuration; the only thing that varies by environment is the namespace, which
comes from `config.yaml`.

That is a deliberate constraint on any environment added later: it would be
prod's configuration in a different namespace, not a lower-scale rehearsal —
same replica count, same resource requests. If one genuinely needs to
differ, reintroduce a layer between 2 and 3 rather than special-casing the
chart.

Layer 3 exists for the cases where two prod clusters genuinely differ. For
`company` and `employee` that is the regional hostname on the HTTPRoute and the
`CLUSTER`/`REGION` config values — see
`environments/prod/company/overrides-{in,us}.yaml`.
Keep it to what actually differs; anything shared belongs in layer 2 where it
cannot drift between clusters.

`company` uses it for one more thing: `rollout.steps` opens at 20% in `in` and
5% in `us`, because rolling a canary out region by region is exactly the kind of
difference this layer is for. Layer 3 also carries `image.tag`, written by
org-apps CI on every push to main. `regional-data` is the opposite case and has no
layer-3 file at all — every cluster gets an identical release, and the data is
separate because the clusters are.

Helm **replaces** lists rather than merging them, so a per-cluster file that
touches `httpRoute.hostnames` must restate the whole list, including the shared
entries. Maps (like `config`) do merge.

Note that layer 2 applies to *each* cluster: `replicaCount: 3` means 3 replicas on
cluster-a and 3 on cluster-b, 6 in total.

Layer 3 lives outside the chart directory, so the Application uses **two
sources**: the chart, plus the same repo again with `ref: values` purely so the
per-cluster file can be addressed as `$values/environments/...`. That is Argo
CD's supported way to reference a file outside the chart path.

Reproduce what a given cluster will get:

```bash
# every cluster with no per-cluster file
helm template company helm/company --namespace demo

# exactly what a region=in cluster will receive
helm template company helm/company \
  -f environments/prod/company/overrides-in.yaml \
  --namespace demo

# diff two prod clusters
diff <(helm template company helm/company \
        -f environments/prod/company/overrides-in.yaml --namespace demo) \
     <(helm template company helm/company \
        -f environments/prod/company/overrides-us.yaml --namespace demo)
```

## One ApplicationSet per environment

An environment gets its own object rather than another generator on a shared
one. Sync policy differences stay explicit instead of hidden in per-generator
template overrides, and prod rollouts can be paused or rolled back by touching
one object. What prod picks:

| | prod |
| --- | --- |
| Cluster selector | `env=prod` |
| Project destinations | `cluster-a`, `cluster-b` — named, not `*` |
| Sync | manual (drift still reported) |
| Application finalizer | no — deleting an Application leaves workloads |
| ApplicationSet deletion | `preserveResourcesOnDeletion: true` |
| `revisionHistoryLimit` | 10 |

Manual prod sync is per-Application, and there is now one Application per
cluster — so a release can be synced to cluster-a, verified, then synced to
cluster-b. The fan-out does not force a simultaneous rollout.

It uses `CreateNamespace=true`, `ServerSideApply=true`, and a capped retry
backoff. `goTemplateOptions: ["missingkey=error"]` is set so a typo'd key in a
`config.yaml` fails the generator instead of rendering an empty string into a
namespace or project name.

## Bootstrap

One manual step, on a cluster that already has Argo CD:

```bash
kubectl apply -f argocd/bootstrap/root-app.yaml
```

The root Application syncs `argocd/` recursively, so the projects and
ApplicationSets — and the root app itself — are managed from git afterwards. It
runs with `prune: false`: removing an AppProject or ApplicationSet should be a
deliberate act, not a side effect of moving a file.

## Before this runs

Repo-specific values are placeholders and need replacing:

- `repoURL` is `https://github.com/PratyushMathur/org-gitops.git` in the
  ApplicationSet and the root app. If the org repo lives elsewhere, update those
  plus `sourceRepos` in the AppProject.
- **Clusters must be registered and labelled** (`env=prod`) before anything
  generates. An unlabelled cluster produces zero Applications, silently — the
  matrix has nothing to multiply by. `argocd cluster list` is the quickest check.
- The per-region files are selected by the cluster Secret's `region` label, not
  by cluster name. A prod cluster with no `region` label silently gets only the
  chart's values — `ignoreMissingValueFiles: true` hides the miss.
- `apps-prod` has no `roles`. Bind it in `argocd-rbac-cm`, or add project roles,
  to gate who can trigger a prod sync — otherwise "manual sync" only means
  "manual", not "authorized".
- A private repo needs its credentials registered with Argo CD separately.

## Requirements

Argo CD **2.6+** for multi-source Applications (`ref: values`). The matrix and
cluster generators and `ignoreMissingValueFiles` are all older than that.
