{{- define "base.ingress" -}}
{{- $v := fromYaml (include "base.values" .) -}}
{{- if $v.ingress.enabled -}}
{{- $fullName := include "base.fullname" . -}}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ $fullName }}
  labels:
    {{- include "base.labels" . | nindent 4 }}
  {{- $annotations := merge (deepCopy ($v.ingress.annotations | default dict)) ($v.commonAnnotations | default dict) }}
  {{- with $annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  {{- with $v.ingress.className }}
  ingressClassName: {{ . }}
  {{- end }}
  {{- with $v.ingress.tls }}
  tls:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  rules:
    {{- range $v.ingress.hosts }}
    - host: {{ .host | quote }}
      http:
        paths:
          {{- range .paths }}
          - path: {{ .path }}
            pathType: {{ .pathType | default "Prefix" }}
            backend:
              service:
                name: {{ $fullName }}
                port:
                  {{- if .servicePort }}
                  {{- if kindIs "string" .servicePort }}
                  name: {{ .servicePort }}
                  {{- else }}
                  number: {{ .servicePort }}
                  {{- end }}
                  {{- else }}
                  name: http
                  {{- end }}
          {{- end }}
    {{- end }}
{{- end -}}
{{- end -}}
