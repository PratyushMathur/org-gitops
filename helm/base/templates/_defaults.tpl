{{/*
Org-wide default values.

Library charts do not get their values.yaml merged into the parent, so the
defaults are declared here as YAML and merged with the app chart's `.Values`
at render time. App values always win.

Caveat: because this is a deep merge, setting a defaulted block to `{}` in an
app chart does NOT clear it. To turn off a defaulted block, set its fields
explicitly (e.g. `securityContext: {readOnlyRootFilesystem: false}`) or set the
block to `null`.
*/}}
{{- define "base.defaultValues" -}}
nameOverride: ""
fullnameOverride: ""

# Workload
replicaCount: 2
revisionHistoryLimit: 3
terminationGracePeriodSeconds: 30
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxSurge: 25%
    maxUnavailable: 0

# Image. `repository` is required; `digest` wins over `tag`, and `tag` falls
# back to Chart.appVersion.
image:
  registry: ""
  repository: ""
  tag: ""
  digest: ""
  pullPolicy: IfNotPresent
imagePullSecrets: []

# Metadata. `component`/`partOf` populate the recommended k8s labels.
component: ""
partOf: ""
commonLabels: {}
commonAnnotations: {}
podLabels: {}
podAnnotations: {}

serviceAccount:
  create: true
  # Off by default: most workloads do not talk to the API server.
  automount: false
  annotations: {}
  name: ""

# Hardened by default. Note there is no runAsUser here on purpose - the image
# must declare a non-root USER, which keeps charts portable across base images.
podSecurityContext:
  runAsNonRoot: true
  seccompProfile:
    type: RuntimeDefault
securityContext:
  allowPrivilegeEscalation: false
  privileged: false
  readOnlyRootFilesystem: true
  capabilities:
    drop:
      - ALL

# Memory is limited, CPU deliberately is not - CPU limits cause throttling
# rather than protecting neighbours.
resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    memory: 256Mi

# Container ports. Service ports and probes refer to these by name.
ports:
  - name: http
    containerPort: 8080
    protocol: TCP

command: []
args: []
env: []
envFrom: []
lifecycle: {}

# Key/value app config. Rendered as a ConfigMap, wired into the container via
# envFrom, and hashed into a pod annotation so pods roll on change.
config: {}

livenessProbe: {}
readinessProbe: {}
startupProbe: {}

service:
  enabled: true
  type: ClusterIP
  annotations: {}
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP

# Legacy north-south path, for clusters running an Ingress controller. The prod
# clusters front apps with the GKE Gateway instead — see `httpRoute` below.
ingress:
  enabled: false
  className: ""
  annotations: {}
  hosts: []
  tls: []

# The app's slice of the shared Gateway. Rendered by `base.all`; attaches to a
# Gateway someone else owns (helm/gateway), so enabling it here creates no load
# balancer of its own.
httpRoute:
  enabled: false
  # Which Gateway to attach to. `sectionName` picks the listener by name.
  parentRefs:
    - name: api
      sectionName: http
  # Usually set per region, since the hostname is what differs between clusters.
  hostnames: []
  annotations: {}
  # `pathType` accepts the Ingress spelling ("Prefix") as well as Gateway API's
  # ("PathPrefix"). `servicePort` takes a name from service.ports or a number.
  paths:
    - path: /
      pathType: PathPrefix
      servicePort: http
  # Raw HTTPRoute rules appended after the generated ones — redirects, rewrites,
  # header mutation, anything `paths` does not express.
  extraRules: []

# What the load balancer probes. Rendered only alongside `httpRoute`, and on by
# default there because GKE's fallback is to health-check `/` — which stalls the
# rollout of any app that does not serve it. See _healthcheckpolicy.tpl.
healthCheck:
  enabled: true
  # Empty means "the readiness probe's path", falling back to the liveness
  # probe's and then `/`. Set explicitly to override.
  requestPath: ""
  # Unset means GCP's defaults.
  checkIntervalSec: ""
  timeoutSec: ""
  healthyThreshold: ""
  unhealthyThreshold: ""

# The Gateway itself. Off for application charts: it is per-cluster
# infrastructure rendered by exactly one release (helm/gateway), never by each
# app. Not part of `base.all` — include `base.gateway` explicitly.
gateway:
  enabled: false
  # Defaults to the release fullname; pin it, because httpRoute.parentRefs
  # references this name from other charts.
  name: ""
  # Regional external ALB, matching the regional static IPs Terraform reserves.
  className: gke-l7-regional-external-managed
  # Reserved static IP claimed by name (google_compute_address in org-infra).
  addressName: ""
  # Literal IP, if there is no reserved address to name. `addressName` wins.
  addressIP: ""
  # Certificate Manager map — Google-managed certs, so there is no Secret and no
  # listener certificateRef. Empty until the domain is delegated.
  certificateMap: ""
  annotations: {}
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      # Same namespace only: the Gateway sits alongside the apps it serves, so
      # no ReferenceGrant is needed. Widen to `All` for a cross-namespace one.
      allowedRoutes:
        namespaces:
          from: Same

autoscaling:
  enabled: false
  minReplicas: 2
  maxReplicas: 10
  targetCPUUtilizationPercentage: 80
  targetMemoryUtilizationPercentage: ""
  behavior: {}

# Canary track, rendered by `base.canary` (opt-in — see templates/_canary.tpl).
# Progressive delivery through Argo Rollouts. When enabled, base.all renders a
# Rollout instead of a Deployment and the controller owns the canary — see
# base.rollout. Requires httpRoute.enabled and the argo-rollouts controller with
# the Gateway API plugin (helm/argo-rollouts).
#
# This and `canary` below are mutually exclusive, and base.rollout fails the
# render if both are on. `canary` is the older self-managed path: a second
# Deployment and a weight edited by hand in git.
rollout:
  enabled: false
  # Walked in order each time the pod template changes. `pause: {}` waits
  # indefinitely, so a human runs `kubectl argo rollouts promote <name>` — the
  # same posture as prod's manual Argo CD sync. Use `pause: {duration: 5m}` to
  # promote on a timer instead.
  steps:
    - setWeight: 20
    - pause: {}
    - setWeight: 50
    - pause: {}
  # An AnalysisTemplate reference to gate the steps on metrics, e.g.
  #   analysis:
  #     templates:
  #       - templateName: success-rate
  # Empty means the steps are gated only by the pauses above.
  analysis: {}

# Keys other than enabled/weight/header/headerValue are deep-merged over the
# stable values, so the canary inherits everything it does not restate.
canary:
  enabled: false
  # Percent of ingress traffic sent to the canary.
  weight: 10
  # Request header that forces a request onto the canary regardless of weight,
  # so the new version can be exercised deterministically. Set to "" to disable.
  header: X-Canary
  headerValue: always
  # A fixed, small canary: it exists to be observed, not to carry load, and an
  # HPA underneath it would make the traffic share and the capacity disagree.
  replicaCount: 1
  autoscaling:
    enabled: false
  # No PDB: draining a node should never be blocked by the canary.
  pdb:
    enabled: false

# Opt-in: a PDB in front of a single replica blocks node drains.
pdb:
  enabled: false
  minAvailable: ""
  maxUnavailable: 1

initContainers: []
sidecars: []
volumes: []
volumeMounts: []

nodeSelector: {}
tolerations: []
affinity: {}
topologySpreadConstraints: []
priorityClassName: ""

# Raw manifests appended to the release. Each entry is run through `tpl`.
extraObjects: []
{{- end -}}

{{/*
Effective values: org defaults deep-merged with the app chart's values.
Every template starts with:
  {{- $v := fromYaml (include "base.values" .) -}}
*/}}
{{- define "base.values" -}}
{{- $defaults := fromYaml (include "base.defaultValues" .) -}}
{{- toYaml (mergeOverwrite $defaults (deepCopy .Values)) -}}
{{- end -}}
