# org-gitops

Application Helm charts and Argo CD applications for the org.

## Layout

```
helm/
├── base/                     # library chart — shared templates + org defaults
├── gateway/                  # the cluster's shared Gateway (one per cluster)
├── company/                  # global service (global Postgres + Mongo)
├── employee/                 # regional service (regional Postgres + Redis)
├── regional-data/            # per-region Postgres + Redis (no base dependency)
└── canary-app/               # application chart, depends on base

argocd/
├── bootstrap/root-app.yaml   # applied by hand once; manages the rest
├── projects/                 # AppProjects (staging, prod)
└── applicationsets/          # ApplicationSets (staging, prod)

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
| `company` | global | global Postgres + global Mongo, on the hub VM | 20% in, 5% us |
| `employee` | regional | regional Postgres + regional Redis, in-cluster | 50% both |
| `regional-data` | — | the regional Postgres and Redis themselves | — |

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

One hostname per region, not one per service: each cluster has a single Gateway
behind a single reserved IP, so the two services are separated by path prefix
(`/companies`, `/employees`). `http`, not `https`, until `pynd.dev` is delegated
and Certificate Manager can validate it — see [`helm/gateway`](helm/gateway/values.yaml).

`regional-data` deliberately has **no** per-region overrides: every cluster gets
an identical release, so `regional-data-postgres` resolves to a different server
in each region. The shared name with unshared data is the point. It is a
review-grade data tier — single replica, no backups — and in production would be
replaced by per-region Cloud SQL and Memorystore created in `org-infra`, not
hardened in place.

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

Two environments, **staging** and **prod**, each with its own ApplicationSet:
staging auto-syncs, prod is manual. Each is a **matrix** of a cluster generator
and a git files generator:

```
clusters(env=<env>)  ×  git files(environments/<env>/*/config.yaml)
```

Clusters are identified by the `env` label on their Argo CD cluster Secret, so
prod fans out across **cluster-a** and **cluster-b** automatically — one
Application per app per cluster, named `<app>-<env>-<cluster>`. Deploying an
existing chart to another environment is one new directory; deploying a new app
is a chart plus one directory per environment. Neither touches `argocd/`.

Bootstrap on a cluster that already runs Argo CD:

```bash
kubectl apply -f argocd/bootstrap/root-app.yaml
```

See [`argocd/README.md`](argocd/README.md) for the values layering, the
staging/prod policy split, and the placeholders that need replacing before a
first sync.

### Deploying an app to an environment

```bash
mkdir -p environments/staging/my-app
```

`config.yaml`:

```yaml
app: my-app
env: staging
chartPath: helm/my-app
namespace: my-app-staging
argoProject: apps-staging
```

No cluster is named — the ApplicationSet fans the app out to every cluster
labelled for that environment.

That is the whole registration — there is no per-environment values file. All
values live in the chart's `values.yaml`, so the app deploys the same
configuration in every environment; only the namespace differs. Optionally add
`overrides-<region>.yaml` for settings that differ between regions within an
environment, selected by the cluster's `region` label. Namespaces must match a pattern allowed by the AppProject's
`destinations`. Introducing a third environment means a new AppProject and
ApplicationSet pair under `argocd/`.

Preview exactly what Argo CD will apply:

```bash
helm template my-app helm/my-app \
  --namespace my-app-staging
```
