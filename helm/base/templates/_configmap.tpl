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
VERSION is derived from the image tag so a workload's reported version cannot
drift from the image it runs. TRACK defaults to stable and is overridden by the
Rollout's pod label. A chart setting either key explicitly still wins.
*/}}
{{- $data := mergeOverwrite (dict "VERSION" (include "base.versionLabel" .) "TRACK" "stable") (deepCopy $v.config) -}}
data:
  {{- range $key, $value := $data }}
  {{ $key }}: {{ $value | toString | quote }}
  {{- end }}
{{- end -}}
{{- end -}}
