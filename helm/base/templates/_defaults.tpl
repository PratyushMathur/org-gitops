{{/*
Org-wide default values.

A library chart's values.yaml is not merged into the parent, so defaults are
declared here and merged with the app chart's .Values at render time. App values
win.

Caveat: this is a deep merge, so setting a defaulted block to `{}` does NOT clear
it. Override the fields explicitly, or set the block to `null`.
*/}}
{{- define "base.defaultValues" -}}
nameOverride: ""
fullnameOverride: ""

replicaCount: 2
revisionHistoryLimit: 3
terminationGracePeriodSeconds: 30
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxSurge: 25%
    maxUnavailable: 0

# `repository` is required; `digest` wins over `tag`, and `tag` falls back to
# Chart.appVersion.
image:
  registry: ""
  repository: ""
  tag: ""
  digest: ""
  pullPolicy: IfNotPresent
imagePullSecrets: []

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

# No runAsUser on purpose — the image must declare a non-root USER, which keeps
# charts portable across base images.
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

# CPU is deliberately unlimited: CPU limits throttle rather than protect
# neighbours.
resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    memory: 256Mi

# Service ports and probes refer to these by name.
ports:
  - name: http
    containerPort: 8080
    protocol: TCP

command: []
args: []
env: []
envFrom: []
lifecycle: {}

# Rendered as a ConfigMap, wired in via envFrom, and hashed into a pod annotation
# so pods roll on change.
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

# The app's slice of the shared Gateway. Attaches to a Gateway owned by
# helm/gateway, so enabling it creates no load balancer of its own.
httpRoute:
  enabled: false
  # No `sectionName`, deliberately. It pins a route to one named listener, and
  # pinning it to `http` is why routes served on :80 and nothing on :443 when the
  # HTTPS listener was added — the Gateway reported the listener Programmed and
  # Ready with attachedRoutes 0, which looks like working TLS right up until a
  # request returns 404.
  #
  # Omitting it attaches the route to every listener on the Gateway whose
  # protocol and hostnames are compatible, so one route serves both ports and
  # gains any listener added later. Set `sectionName` per app only to keep a route
  # off a listener on purpose.
  parentRefs:
    - name: api
  # Usually set per region — the hostname is what differs between clusters.
  hostnames: []
  annotations: {}
  # `pathType` accepts the Ingress spelling ("Prefix") as well as Gateway API's
  # ("PathPrefix"). `servicePort` takes a name from service.ports or a number.
  paths:
    - path: /
      pathType: PathPrefix
      servicePort: http
  # Raw HTTPRoute rules appended after the generated ones.
  extraRules: []

# What the load balancer probes. On by default because GKE's fallback is to
# health-check `/`, which stalls the rollout of any app that does not serve it.
healthCheck:
  enabled: true
  # Empty means the readiness probe's path, then the liveness probe's, then `/`.
  requestPath: ""
  # Unset means GCP's defaults.
  checkIntervalSec: ""
  timeoutSec: ""
  healthyThreshold: ""
  unhealthyThreshold: ""

# Per-cluster infrastructure rendered by exactly one release (helm/gateway),
# never by each app. Not part of `base.all` — include `base.gateway` explicitly.
gateway:
  enabled: false
  # Defaults to the release fullname; pin it, because httpRoute.parentRefs in
  # other charts reference this name.
  name: ""
  className: gke-l7-regional-external-managed
  # Reserved static IP claimed by name (google_compute_address in org-infra).
  addressName: ""
  # Literal IP, if there is no reserved address to name. `addressName` wins.
  addressIP: ""
  # Certificate Manager map. Empty until the domain is delegated.
  certificateMap: ""
  annotations: {}
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      # Same namespace only, so no ReferenceGrant is needed.
      allowedRoutes:
        namespaces:
          from: Same

# Progressive delivery through Argo Rollouts: the workload becomes a Rollout and
# the controller owns the canary. Requires httpRoute.enabled and the
# argo-rollouts controller with the Gateway API plugin (helm/argo-rollouts).
rollout:
  enabled: false
  # Walked in order each time the pod template changes. `pause: {}` waits
  # indefinitely, so a human runs `kubectl argo rollouts promote <name>`. Use
  # `pause: {duration: 5m}` to promote on a timer.
  steps:
    - setWeight: 20
    - pause: {}
    - setWeight: 50
    - pause: {}
  # An AnalysisTemplate reference to gate the steps on metrics. Empty means the
  # pauses above are the only gate.
  analysis: {}
  # Request header that pins a request to the canary regardless of weight, so a
  # new version can be exercised deterministically. Set header to "" to drop the
  # rule.
  header: X-Canary
  headerValue: always

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
Effective values: org defaults deep-merged with the app chart's values. Every
template starts with:
  {{- $v := fromYaml (include "base.values" .) -}}
*/}}
{{- define "base.values" -}}
{{- $defaults := fromYaml (include "base.defaultValues" .) -}}
{{- toYaml (mergeOverwrite $defaults (deepCopy .Values)) -}}
{{- end -}}
