{{- define "base.serviceaccount" -}}
{{- $v := fromYaml (include "base.values" .) -}}
{{- if $v.serviceAccount.create -}}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "base.serviceAccountName" . }}
  labels:
    {{- include "base.labels" . | nindent 4 }}
  {{- $annotations := merge (deepCopy ($v.serviceAccount.annotations | default dict)) ($v.commonAnnotations | default dict) }}
  {{- with $annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
automountServiceAccountToken: {{ $v.serviceAccount.automount }}
{{- end -}}
{{- end -}}
