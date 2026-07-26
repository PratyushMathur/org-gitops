{{- define "base.configmap" -}}
{{- $v := fromYaml (include "base.values" .) -}}
{{- if $v.config -}}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "base.fullname" . }}
  labels:
    {{- include "base.labels" . | nindent 4 }}
  {{- with $v.commonAnnotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{/*
VERSION and TRACK are injected rather than left to each chart. VERSION is
derived from the image tag, so the version a workload reports can never drift
from the image it is actually running — restating it in `config` would be a
second source of truth that nothing keeps in step. TRACK defaults to stable and
is overridden to canary by `base.canary`. A chart that sets either key
explicitly still wins.
*/}}
{{- $data := mergeOverwrite (dict "VERSION" (include "base.versionLabel" .) "TRACK" "stable") (deepCopy $v.config) -}}
data:
  {{- range $key, $value := $data }}
  {{ $key }}: {{ $value | toString | quote }}
  {{- end }}
{{- end -}}
{{- end -}}
