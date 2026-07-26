# org-gitops

Application Helm charts and Argo CD applications for the org.

## Layout

```
helm/
├── base/                     # library chart — shared templates + org defaults
├── argo-rollouts/            # the progressive-delivery controller + GW API plugin
├── gateway/                  # the cluster's shared Gateway (one per cluster)
├── company/                  # global service (global Cloud SQL Postgres)
├── employee/                 # regional service (regional Cloud SQL Postgres + Redis)
└── regional-data/            # per-region Redis (no base dependency)

argocd/
├── bootstrap/root-app.yaml   # applied by hand once; manages the rest
├── projects/                 # AppProject (prod)
└── applicationsets/          # ApplicationSet (prod)

environments/
└── <env>/<app>/
    ├── config.yaml                 # registers the app in that env
    └── overrides-<region>.yaml     # optional per-region overrides
```

Charts describe *what* an app is. `environments/` describes *where* it runs and
*how* it differs there. Argo CD joins the two — no `Application` manifests are
written by hand.

## Charts

Every application chart depends on [`helm/base`](helm/base/README.md), a Helm
library chart holding the shared Deployment/Service/Ingress/HPA/PDB/ConfigMap
templates and the org's defaults. An app chart is therefore just a `Chart.yaml`,
a `values.yaml` with the deltas, and a one-line `templates/all.yaml`.

See [`helm/base/README.md`](helm/base/README.md) for the values reference, the
list of defaults, and how canary releases work.

### The demo services

`company` and `employee` are deployed to both prod clusters — code in
[`org-apps/services`](../org-apps/services). Between them they cover both data
paths:

| Chart | Tier | Databases | Canary |
| --- | --- | --- | --- |
| `company` | global | one global Cloud SQL Postgres, shared by both regions | 20→50% in, 5→20→50% us |
| `employee` | regional | that region's Cloud SQL Postgres + in-cluster Redis | 50% both |
| `regional-data` | — | the per-region Redis itself | — |

Companies are global, so both regions read the same list. Employees are
regional, so each region has its own. Adding an employee also looks the company
up through the `company` service in the same cluster, which is the round trip to
the global database from that region:

```bash
curl -X POST "http://api-ind.pynd.dev/companies?name=acme"
curl -s      "http://api-us.pynd.dev/companies"          # same list

curl -X POST "http://api-ind.pynd.dev/employees?name=asha&company=acme"
curl -s      "http://api-us.pynd.dev/employees"          # different list
```

Releases are progressive. Both services render as Argo Rollouts **Rollouts**, so
changing `image.tag` starts a canary rather than a straight replacement: the
controller shifts weight on the app's HTTPRoute a step at a time and waits at
each pause for a human.

```bash
kubectl argo rollouts get rollout company -n demo --watch
kubectl argo rollouts promote company -n demo      # advance one step
kubectl argo rollouts undo    company -n demo      # roll back

curl -H 'X-Canary: always' http://api-ind.<ip>.sslip.io/companies   # pin to the canary
```

India leads at 20% then 50%; the US starts at 5% and adds a step. The weights
live in the chart, not in anyone's head — see `helm/company/values.yaml` and
`environments/prod/company/overrides-us.yaml`.

One hostname per region, not one per service: each cluster has a single Gateway
behind a single reserved IP, so the two services are separated by path prefix
(`/companies`, `/employees`). `http`, not `https`, until `pynd.dev` is delegated
and Certificate Manager can validate it — see [`helm/gateway`](helm/gateway/values.yaml).

Both Postgres tiers are managed instances created in
[`org-infra`](../org-infra/configs/prod/cluster-a/config.yaml) under
`data.cloud_sql`, never containers in the cluster. The charts address them by
name through the split-horizon `internal.` DNS zone:

| Name | Resolves to |
| --- | --- |
| `global-postgres.internal` | one us-central1 instance, from **every** VPC — a different PSC endpoint IP per region, the same database |
| `regional-postgres.internal` | that VPC's **own** regional instance, and it does not resolve anywhere else |

Same trick, opposite intent: one name that is deliberately shared, one name that
is deliberately not. Peering alone could not deliver the global case — it is
non-transitive, so a spoke can never reach a hub instance through the hub's
other peering — which is why each VPC gets its own Private Service Connect
endpoint instead.

`regional-data` is what is left in the cluster: a Redis per region, with
deliberately **no** per-region overrides, so `regional-data-redis` resolves to a
different server in each. It is a cache, so one per cluster is the right shape
rather than a stand-in for Memorystore. It stays review-grade — single replica,
no backups.

The regional and global tiers are told apart in every response by a `scope`
field, and the identity in it is reported by the *server*, not echoed from
config — see [`org-apps/services/README.md`](../org-apps/services/README.md).

### Adding a new app chart

```bash
mkdir -p helm/my-app/templates
echo '{{ include "base.all" . }}' > helm/my-app/templates/all.yaml
```

`helm/my-app/Chart.yaml`:

```yaml
apiVersion: v2
name: my-app
type: application
version: 0.1.0
appVersion: "1.0.0"
dependencies:
  - name: base
    version: 0.1.0
    repository: "file://../base"
```

Put the app's overrides in `helm/my-app/values.yaml`, then:

```bash
helm dependency update helm/my-app   # writes Chart.lock — commit it
helm lint helm/my-app
helm template my-app helm/my-app
```

The `base` dependency resolves over `file://` against this repo. Argo CD's
repo-server checks out the whole repository and runs `helm dependency build`,
so the base chart does not need publishing to a registry. `charts/` is
gitignored; `Chart.lock` is committed.

## Argo CD

One environment, **prod**, with its own ApplicationSet and a manual sync policy.
It is a **matrix** of a cluster generator and a git files generator:

```
clusters(env=<env>)  ×  git files(environments/<env>/*/config.yaml)
```

Clusters are identified by the `env` label on their Argo CD cluster Secret, so
prod fans out across **cluster-a** and **cluster-b** automatically — one
Application per app per cluster, named `<app>-<env>-<cluster>`. Deploying a new
app is a chart plus one directory under `environments/prod/`; it does not touch
`argocd/`.

Bootstrap on a cluster that already runs Argo CD:

```bash
kubectl apply -f argocd/bootstrap/root-app.yaml
```

See [`argocd/README.md`](argocd/README.md) for the values layering, the prod
sync policy, and the placeholders that need replacing before a first sync.

### Deploying an app

```bash
mkdir -p environments/prod/my-app
```

`config.yaml`:

```yaml
app: my-app
env: prod
chartPath: helm/my-app
namespace: demo
argoProject: apps-prod
```

No cluster is named — the ApplicationSet fans the app out to every cluster
labelled for that environment.

That is the whole registration — there is no per-environment values file. All
values live in the chart's `values.yaml`. Optionally add `overrides-<region>.yaml`
for settings that differ between regions, selected by the cluster's `region`
label. Namespaces must match a pattern allowed by the AppProject's
`destinations`. Adding a second environment means a new AppProject and
ApplicationSet pair under `argocd/`.

Preview exactly what Argo CD will apply:

```bash
helm template my-app helm/my-app --namespace demo
```
