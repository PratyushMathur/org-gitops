{{/*
Rollout — the Argo Rollouts replacement for base.deployment.

`rollout.enabled: true` makes base.all render an argoproj.io Rollout plus a
`<fullname>-canary` Service. The controller then owns the canary: it creates the
canary ReplicaSet when the pod template changes, walks `rollout.steps`, and
rewrites the weights on the app's HTTPRoute through the Gateway API plugin.

The pod template comes from `base.deployment` rather than being restated, so the
two paths cannot drift. Only the wrapper differs.

TRACK is a pod *label*, not a ConfigMap key — both tracks share one pod template.
It is surfaced through the downward API, and deliberately kept out of the
selector so the Services match both tracks; Argo Rollouts tells them apart with
its own `rollouts-pod-template-hash`.

KNOWN WRINKLE: TRACK is a snapshot. A downward API env var resolves once at
container start, so a pod relabelled `track=stable` on promotion keeps reporting
`canary` until it is replaced. Read it as "the track this pod was introduced in".
Making it live needs a downward API volume read at request time — an application
change, not a chart one.
*/}}
{{- define "base.rollout" -}}
{{- $v := fromYaml (include "base.values" .) -}}
{{- if $v.rollout.enabled -}}
{{- $fullName := include "base.fullname" . -}}

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
  replicas: {{ $v.replicaCount }}
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
  {{/*
    Every annotation is carried over from the stable Service except the NEG one,
    which is dropped rather than copied. A standalone NEG is named, and two
    Services in one zone asking for the same name is a fight the NEG controller
    resolves by flipping the endpoint set between the stable and canary pods —
    so a backend service attached to it would swing between tracks with nothing
    in the Rollout to explain why.

    Giving the canary its own NEG name would be the other fix, but there is
    nothing to attach it to: the global ALB deliberately serves stable only, so a
    disaster path is never the first place a new build takes traffic. Canary
    traffic is shifted on the HTTPRoute by the Rollouts plugin, which does not go
    through a NEG of its own.
  */}}
  {{- $annotations := omit (merge (deepCopy ($v.service.annotations | default dict)) ($v.commonAnnotations | default dict)) "cloud.google.com/neg" }}
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
