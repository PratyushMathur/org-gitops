{{- define "base.pdb" -}}
{{- $v := fromYaml (include "base.values" .) -}}
{{- if $v.pdb.enabled -}}
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ include "base.fullname" . }}
  labels:
    {{- include "base.labels" . | nindent 4 }}
  {{- with $v.commonAnnotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  {{- if $v.pdb.minAvailable }}
  minAvailable: {{ $v.pdb.minAvailable }}
  {{- else }}
  maxUnavailable: {{ $v.pdb.maxUnavailable }}
  {{- end }}
  selector:
    matchLabels:
      {{- include "base.selectorLabels" . | nindent 6 }}
{{- end -}}
{{- end -}}
