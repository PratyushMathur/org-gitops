# Argo CD

```
argocd/
├── bootstrap/
│   └── root-app.yaml            # the only object applied by hand
├── projects/
│   ├── apps-staging.yaml        # AppProject: *-staging
│   └── apps-prod.yaml           # AppProject: *-prod
└── applicationsets/
    ├── apps-staging.yaml        # auto-sync
    └── apps-prod.yaml           # manual sync
```

Two environments: **staging** and **prod**.

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
app: canary-app
env: staging
chartPath: helm/canary-app
namespace: canary-staging
argoProject: apps-staging
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
argocd cluster add <kube-context> --name cluster-a --label env=prod
argocd cluster add <kube-context> --name cluster-b --label env=prod
argocd cluster add <kube-context> --name cluster-s --label env=staging
```

Prod currently spans **cluster-a** and **cluster-b**; every app registered under
`environments/prod/` is deployed to both. Rolling out to a new prod cluster is
two steps, on purpose:

1. label its cluster Secret `env=prod` — it is now *discovered*
2. add its name to `destinations` in `argocd/projects/apps-prod.yaml` — it is
   now *authorised*

Discovery and authorisation are separated so a mislabelled cluster cannot
silently start receiving production workloads. Staging skips step 2: its
AppProject allows `name: "*"` within `*-staging` namespaces.

The Application's `destination.name` is the cluster name from the generator, so
the AppProject `destinations` match on `name` rather than `server`.

## Values layering

Four layers, lowest to highest:

1. `helm/base` — org defaults (`templates/_defaults.tpl`)
2. `helm/<app>/values.yaml` — app-wide settings
3. `environments/<env>/<app>/values.yaml` — environment overrides
4. `environments/<env>/<app>/values-<cluster>.yaml` — per-cluster overrides,
   **optional** (`ignoreMissingValueFiles: true`)

Layer 4 exists for the cases where two prod clusters genuinely differ. For
`canary-app` that is the regional ingress hostname and the `CLUSTER`/`REGION`
config values — see `environments/prod/canary-app/values-cluster-{a,b}.yaml`.
Keep it to what actually differs; anything shared belongs in layer 3 where it
cannot drift between clusters.

Helm **replaces** lists rather than merging them, so a per-cluster file that
touches `ingress.hosts` must restate the whole list, including the shared
entries. Maps (like `config`) do merge.

Note that layer 3 applies to *each* cluster: `replicaCount: 3` in a prod values
file means 3 replicas on cluster-a and 3 on cluster-b, 6 in total.

Layers 3 and 4 live outside the chart directory, so the Application uses **two
sources**: the chart, plus the same repo again with `ref: values` purely so the
values files can be addressed as `$values/environments/...`. That is Argo CD's
supported way to reference a file outside the chart path.

Reproduce what a given cluster will get:

```bash
# exactly what cluster-a will receive
helm template canary-app helm/canary-app \
  -f environments/prod/canary-app/values.yaml \
  -f environments/prod/canary-app/values-cluster-a.yaml \
  --namespace canary-prod

# diff two prod clusters
diff <(helm template canary-app helm/canary-app \
        -f environments/prod/canary-app/values.yaml \
        -f environments/prod/canary-app/values-cluster-a.yaml --namespace canary-prod) \
     <(helm template canary-app helm/canary-app \
        -f environments/prod/canary-app/values.yaml \
        -f environments/prod/canary-app/values-cluster-b.yaml --namespace canary-prod)
```

## Why two ApplicationSets

Prod is a separate object rather than another generator on the staging set. The
sync policy differences stay explicit instead of hidden in per-generator
template overrides, and prod rollouts can be paused or rolled back by touching
one object.

| | staging | prod |
| --- | --- | --- |
| Cluster selector | `env=staging` | `env=prod` |
| Project destinations | `name: "*"` | `cluster-a`, `cluster-b` |
| Sync | automated, `prune` + `selfHeal` | manual (drift still reported) |
| Application finalizer | yes — delete cascades | no — delete leaves workloads |
| ApplicationSet deletion | removes Applications | `preserveResourcesOnDeletion: true` |
| `revisionHistoryLimit` | 5 | 10 |

Manual prod sync is per-Application, and there is now one Application per
cluster — so a release can be synced to cluster-a, verified, then synced to
cluster-b. The fan-out does not force a simultaneous rollout.

Both use `CreateNamespace=true`, `ServerSideApply=true`, and a capped retry
backoff. `goTemplateOptions: ["missingkey=error"]` is set on both so a typo'd
key in a `config.yaml` fails the generator instead of rendering an empty string
into a namespace or project name.

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

- `repoURL` is `https://github.com/PratyushMathur/org-gitops.git` in both
  ApplicationSets and the root app. If the org repo lives elsewhere, update
  those plus `sourceRepos` in both AppProjects.
- **Clusters must be registered and labelled** (`env=prod` / `env=staging`)
  before anything generates. An unlabelled cluster produces zero Applications,
  silently — the matrix has nothing to multiply by. `argocd cluster list` is the
  quickest check.
- The staging cluster name is assumed, not known — nothing here hardcodes it,
  but the `argocd cluster add` example uses `cluster-s`.
- Hostnames are `*.example.com`, and the regions in the per-cluster values files
  (`ap-south-1`, `ap-southeast-1`) are placeholders. Both prod clusters serve the
  shared `canary.example.com` plus a per-cluster `canary-{a,b}.example.com`,
  which assumes active/active behind a global load balancer. If that is not the
  topology, drop the shared host from the per-cluster files.
- Both prod clusters reference the same `canary-app-tls` secret name, but each
  covers a different SAN list — they are separate certificates in separate
  clusters, issued by cert-manager per cluster.
- `apps-prod` has no `roles`. Bind it in `argocd-rbac-cm`, or add project roles,
  to gate who can trigger a prod sync — otherwise "manual sync" only means
  "manual", not "authorized".
- A private repo needs its credentials registered with Argo CD separately.

## Requirements

Argo CD **2.6+** for multi-source Applications (`ref: values`). The matrix and
cluster generators and `ignoreMissingValueFiles` are all older than that.
