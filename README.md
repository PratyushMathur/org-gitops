# org-gitops

Application Helm charts and Argo CD applications for the org.

## Layout

```
helm/
├── base/                     # library chart — shared templates + org defaults
└── canary-app/               # application chart, depends on base

argocd/
├── bootstrap/root-app.yaml   # applied by hand once; manages the rest
├── projects/                 # AppProjects (staging, prod)
└── applicationsets/          # ApplicationSets (staging, prod)

environments/
└── <env>/<app>/
    ├── config.yaml                 # registers the app in that env
    └── overrides-<cluster>.yaml    # optional per-cluster overrides
```

Charts describe *what* an app is. `environments/` describes *where* it runs and
*how* it differs there. Argo CD joins the two — no `Application` manifests are
written by hand.

## Charts

Every application chart depends on [`helm/base`](helm/base/README.md), a Helm
library chart holding the shared Deployment/Service/Ingress/HPA/PDB/ConfigMap
templates and the org's defaults. An app chart is therefore just a `Chart.yaml`,
a `values.yaml` with the deltas, and a one-line `templates/all.yaml`.

See [`helm/base/README.md`](helm/base/README.md) for the values reference and
the list of defaults.

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
`overrides-<cluster>.yaml` for settings that differ between clusters within an
environment. Namespaces must match a pattern allowed by the AppProject's
`destinations`. Introducing a third environment means a new AppProject and
ApplicationSet pair under `argocd/`.

Preview exactly what Argo CD will apply:

```bash
helm template my-app helm/my-app \
  --namespace my-app-staging
```
