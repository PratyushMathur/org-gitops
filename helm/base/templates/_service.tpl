{{- define "base.service" -}}
{{- $v := fromYaml (include "base.values" .) -}}
{{- if $v.service.enabled -}}
apiVersion: v1
kind: Service
metadata:
  name: {{ include "base.fullname" . }}
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
