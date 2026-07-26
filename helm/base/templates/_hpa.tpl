{{- define "base.hpa" -}}
{{- $v := fromYaml (include "base.values" .) -}}
{{- if $v.autoscaling.enabled -}}
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {{ include "base.fullname" . }}
  labels:
    {{- include "base.labels" . | nindent 4 }}
  {{- with $v.commonAnnotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  {{/*
  A Rollout is scaled through its own scale subresource, so the HPA has to name
  the Rollout. Pointed at a Deployment that no longer exists, the HPA reports
  FailedGetScale and silently stops autoscaling.
  */}}
  scaleTargetRef:
    {{- if $v.rollout.enabled }}
    apiVersion: argoproj.io/v1alpha1
    kind: Rollout
    {{- else }}
    apiVersion: apps/v1
    kind: Deployment
    {{- end }}
    name: {{ include "base.fullname" . }}
  minReplicas: {{ $v.autoscaling.minReplicas }}
  maxReplicas: {{ $v.autoscaling.maxReplicas }}
  metrics:
    {{- with $v.autoscaling.targetCPUUtilizationPercentage }}
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: {{ . }}
    {{- end }}
    {{- with $v.autoscaling.targetMemoryUtilizationPercentage }}
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: {{ . }}
    {{- end }}
    {{- with $v.autoscaling.extraMetrics }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- with $v.autoscaling.behavior }}
  behavior:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end -}}
{{- end -}}
