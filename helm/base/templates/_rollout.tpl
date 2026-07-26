{{/*
Rollout — the Argo Rollouts replacement for base.deployment.

Set `rollout.enabled: true` and `base.all` renders an argoproj.io Rollout
instead of a Deployment, plus a second `<fullname>-canary` Service. Argo
Rollouts then owns the canary: it creates the canary ReplicaSet when the pod
template changes, walks `rollout.steps`, and rewrites the weights on the app's
HTTPRoute through the Gateway API plugin.

WHAT THIS REPLACES. The older `base.canary` shipped a whole second Deployment
pinned to a second image tag, with the split written into the HTTPRoute by hand.
The weight only moved when someone edited git, nothing tied the canary's health
to whether it kept receiving traffic, and rolling back meant another commit. A
Rollout makes the progression the controller's job — the chart declares the
shape of the release, not each step of it.

The pod template is taken from `base.deployment` rather than restated, so the
two paths cannot drift: probes, security context, envFrom and sidecars are
defined once. Only the wrapper differs.

TRACK. Both tracks run the same pod template, so TRACK can no longer come from
the ConfigMap the way it did when the canary was its own Deployment. Instead
`track` is a pod *label* — defaulted to `stable` here and overridden to `canary`
by canaryMetadata below — which is surfaced to the container through the
downward API. The label is deliberately NOT part of the selector: the Services
must match both tracks, and Argo Rollouts tells them apart by injecting its own
`rollouts-pod-template-hash`.

KNOWN WRINKLE: TRACK is a snapshot, not a live value. A downward API *env var*
is resolved once when the container starts; only a downward API *volume* tracks
later label changes. On promotion Argo Rollouts relabels the canary pods
`track=stable`, but the processes inside them keep the value they booted with,
so a promoted pod goes on reporting `track: canary` until it is replaced. The
label on the pod is correct; the env var is stale.

Read it as "the track this pod was introduced in", which is what it accurately
records. Making it live means reading the label from a downward API volume at
request time, which is an application change, not a chart one.

  templates/all.yaml
  ---------------------------------
  {{ include "base.all" . }}

  values.yaml
  ---------------------------------
  rollout:
    enabled: true
    steps:
      - setWeight: 20
      - pause: {}
*/}}
{{- define "base.rollout" -}}
{{- $v := fromYaml (include "base.values" .) -}}
{{- if $v.rollout.enabled -}}
{{- $fullName := include "base.fullname" . -}}

{{- if $v.canary.enabled -}}
{{- fail "rollout.enabled and canary.enabled are both set: the Rollout controller owns the canary, so the second Deployment base.canary renders would be a duplicate workload behind the same Service. Turn canary.enabled off." -}}
{{- end -}}

{{- if not $v.httpRoute.enabled -}}
{{- fail "rollout.enabled requires httpRoute.enabled: the Gateway API traffic router shifts weight by rewriting the app's HTTPRoute, and there is nothing to rewrite without one." -}}
{{- end -}}

{{/*
Reuse the Deployment's pod template verbatim, then add what only the Rollout
needs. `strategy` is deliberately not carried over — a Deployment's
RollingUpdate block and a Rollout's canary block occupy the same field name and
mean different things.
*/}}
{{- $dep := fromYaml (include "base.deployment" .) -}}
{{- $podTemplate := $dep.spec.template -}}

{{/* The floor for the track label, so TRACK resolves even before the first
     rollout has run and there is no canary ReplicaSet to carry metadata. */}}
{{- $_ := set $podTemplate.metadata "labels" (merge (dict "track" "stable") ($podTemplate.metadata.labels | default dict)) -}}

{{/* Surface the label to the app. An explicit `env` entry beats anything the
     ConfigMap supplies through envFrom, so this wins over the static
     TRACK=stable base.configmap writes. */}}
{{- $container := index $podTemplate.spec.containers 0 -}}
{{- $env := $container.env | default list -}}
{{- $env = append $env (dict "name" "TRACK" "valueFrom" (dict "fieldRef" (dict "fieldPath" "metadata.labels['track']"))) -}}
{{- $_ = set $container "env" $env -}}

apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: {{ $fullName }}
  labels:
    {{- include "base.labels" . | nindent 4 }}
  {{- with $v.commonAnnotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  {{- if not $v.autoscaling.enabled }}
  replicas: {{ $v.replicaCount }}
  {{- end }}
  revisionHistoryLimit: {{ $v.revisionHistoryLimit }}
  selector:
    matchLabels:
      {{- include "base.selectorLabels" . | nindent 6 }}
  template:
    {{- toYaml $podTemplate | nindent 4 }}
  strategy:
    canary:
      stableService: {{ $fullName }}
      canaryService: {{ $fullName }}-canary
      {{- /*
      What makes a response attributable to a track. Without these the two
      ReplicaSets are indistinguishable from inside the pod, and `/version`
      could not report which one answered.
      */}}
      stableMetadata:
        labels:
          track: stable
      canaryMetadata:
        labels:
          track: canary
      trafficRouting:
        plugins:
          {{- /*
          The key is defined by the plugin, and must match the `name` the
          controller registers it under — see controller.trafficRouterPlugins in
          helm/argo-rollouts/values.yaml. A mismatch is not a template error:
          the controller simply never shifts any traffic.
          */}}
          argoproj-labs/gatewayAPI:
            httpRoute: {{ $fullName }}
            namespace: {{ .Release.Namespace }}
      steps:
        {{- toYaml $v.rollout.steps | nindent 8 }}
      {{- with $v.rollout.analysis }}
      analysis:
        {{- toYaml . | nindent 8 }}
      {{- end }}
{{- end -}}
{{- end -}}

{{/*
The canary Service. Identical to the stable one in every respect — same
selector, same ports — because Argo Rollouts is what tells them apart, by
writing a `rollouts-pod-template-hash` selector into each as the rollout
progresses. Defining it with a different selector here would fight the
controller for ownership of that field.
*/}}
{{- define "base.rollout.canaryservice" -}}
{{- $v := fromYaml (include "base.values" .) -}}
{{- if and $v.rollout.enabled $v.service.enabled -}}
apiVersion: v1
kind: Service
metadata:
  name: {{ include "base.fullname" . }}-canary
  labels:
    {{- include "base.labels" . | nindent 4 }}
  {{- $annotations := merge (deepCopy ($v.service.annotations | default dict)) ($v.commonAnnotations | default dict) }}
  {{- with $annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  type: {{ $v.service.type }}
  ports:
    {{- toYaml $v.service.ports | nindent 4 }}
  selector:
    {{- include "base.selectorLabels" . | nindent 4 }}
{{- end -}}
{{- end -}}

{{/*
Which workload kind owns the pods. base.all calls this rather than either
template directly, so exactly one of them is ever rendered — two objects with
the same selector would otherwise both manage pods behind the same Service.
*/}}
{{- define "base.workload" -}}
{{- $v := fromYaml (include "base.values" .) -}}
{{- if $v.rollout.enabled -}}
{{- include "base.rollout" . -}}
{{- else -}}
{{- include "base.deployment" . -}}
{{- end -}}
{{- end -}}

{{/*
The canary Service's HealthCheckPolicy. Policies are per-Service, so the canary
needs its own: without it GKE probes `/` on those pods, the NEG reports no
healthy endpoint, and the canary is handed a weight it can never serve — a
rollout that looks like it is progressing while every request still lands on
stable.
*/}}
{{- define "base.rollout.canaryhealthcheckpolicy" -}}
{{- $v := fromYaml (include "base.values" .) -}}
{{- if and $v.rollout.enabled (and $v.httpRoute.enabled $v.healthCheck.enabled) -}}
{{- include "base.healthcheckpolicy.for" (dict "ctx" . "name" (printf "%s-canary" (include "base.fullname" .))) -}}
{{- end -}}
{{- end -}}
