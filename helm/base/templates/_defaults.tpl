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

ingress:
  enabled: false
  className: ""
  annotations: {}
  hosts: []
  tls: []

autoscaling:
  enabled: false
  minReplicas: 2
  maxReplicas: 10
  targetCPUUtilizationPercentage: 80
  targetMemoryUtilizationPercentage: ""
  behavior: {}

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
