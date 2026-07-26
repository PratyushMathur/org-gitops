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
{{- $docs := list
      (include "base.serviceaccount" $ctx)
      (include "base.configmap" $ctx)
      (include "base.deployment" $ctx)
      (include "base.service" $ctx)
      (include "base.ingress" $ctx)
      (include "base.httproute" $ctx)
      (include "base.healthcheckpolicy" $ctx)
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
