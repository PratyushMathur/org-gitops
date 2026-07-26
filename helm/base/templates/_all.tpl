{{/*
Renders the full standard object set for an application.

An app chart's entire templates/ directory is normally just:

  templates/all.yaml
  ---------------------------------
  {{ include "base.all" . }}

Individual templates (base.deployment, base.service, ...) can be included
directly instead if a chart needs finer control.
*/}}
{{- define "base.all" -}}
{{- $ctx := . -}}
{{- $v := fromYaml (include "base.values" $ctx) -}}
{{/*
The workload is a Rollout or a Deployment, never both — see base.rollout. The
canary Service and its HealthCheckPolicy render only on the Rollout path; both
are no-ops otherwise. The policy matters: a Service GKE health-checks on `/`
never reports a healthy endpoint, so the canary would be given weight it could
not receive.
*/}}
{{- $docs := list
      (include "base.serviceaccount" $ctx)
      (include "base.configmap" $ctx)
      (include "base.workload" $ctx)
      (include "base.service" $ctx)
      (include "base.rollout.canaryservice" $ctx)
      (include "base.ingress" $ctx)
      (include "base.httproute" $ctx)
      (include "base.healthcheckpolicy" $ctx)
      (include "base.rollout.canaryhealthcheckpolicy" $ctx)
      (include "base.hpa" $ctx)
      (include "base.pdb" $ctx) -}}
{{- range $v.extraObjects }}
{{- $docs = append $docs (tpl (toYaml .) $ctx) }}
{{- end }}
{{- range $docs }}
{{- $doc := trim . }}
{{- if $doc }}
---
{{ $doc }}
{{- end }}
{{- end }}
{{- end -}}
