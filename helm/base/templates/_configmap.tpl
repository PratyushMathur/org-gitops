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
data:
  {{- range $key, $value := $v.config }}
  {{ $key }}: {{ $value | toString | quote }}
  {{- end }}
{{- end -}}
{{- end -}}
