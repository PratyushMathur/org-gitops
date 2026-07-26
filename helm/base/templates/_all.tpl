{{/*
The standard object set for an application. An app chart's templates/ is
normally just `{{ include "base.all" . }}`; individual templates can be included
directly if a chart needs finer control.
*/}}
{{- define "base.all" -}}
{{- $ctx := . -}}
{{- $v := fromYaml (include "base.values" $ctx) -}}
{{/*
The canary Service and its HealthCheckPolicy render only on the Rollout path.
The policy matters: GKE health-checks a Service on `/` by default, which never
reports a healthy endpoint, so the canary would get weight it cannot serve.
*/}}
{{- $docs := list
      (include "base.serviceaccount" $ctx)
      (include "base.configmap" $ctx)
      (include "base.workload" $ctx)
      (include "base.service" $ctx)
      (include "base.rollout.canaryservice" $ctx)
      (include "base.httproute" $ctx)
      (include "base.healthcheckpolicy" $ctx)
      (include "base.rollout.canaryhealthcheckpolicy" $ctx) -}}
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
