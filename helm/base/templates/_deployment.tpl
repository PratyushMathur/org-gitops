{{- define "base.deployment" -}}
{{- $v := fromYaml (include "base.values" .) -}}
{{/*
No rollout guard here on purpose: base.rollout renders this template to lift the
pod spec out of it, so a guard would make the Rollout render nothing. base.all
picks between the two through base.workload.
*/}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "base.fullname" . }}
  labels:
    {{- include "base.labels" . | nindent 4 }}
  {{- with $v.commonAnnotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  replicas: {{ $v.replicaCount }}
  revisionHistoryLimit: {{ $v.revisionHistoryLimit }}
  {{- with $v.strategy }}
  strategy:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  selector:
    matchLabels:
      {{- include "base.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      {{- $podAnnotations := deepCopy ($v.podAnnotations | default dict) }}
      {{- if $v.config }}
      {{- $_ := set $podAnnotations "checksum/config" (include "base.configmap" . | sha256sum) }}
      {{- end }}
      {{- with $podAnnotations }}
      annotations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      labels:
        {{- include "base.selectorLabels" . | nindent 8 }}
        {{- with $v.podLabels }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
    spec:
      {{- with $v.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      serviceAccountName: {{ include "base.serviceAccountName" . }}
      automountServiceAccountToken: {{ $v.serviceAccount.automount }}
      {{- with $v.podSecurityContext }}
      securityContext:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $v.priorityClassName }}
      priorityClassName: {{ . }}
      {{- end }}
      terminationGracePeriodSeconds: {{ $v.terminationGracePeriodSeconds }}
      {{- with $v.initContainers }}
      initContainers:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      containers:
        - name: {{ include "base.name" . }}
          image: {{ include "base.image" . | quote }}
          imagePullPolicy: {{ $v.image.pullPolicy }}
          {{- with $v.command }}
          command:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with $v.args }}
          args:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with $v.ports }}
          ports:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with $v.env }}
          env:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- $envFrom := $v.envFrom | default list }}
          {{- if $v.config }}
          {{- $envFrom = append $envFrom (dict "configMapRef" (dict "name" (include "base.fullname" .))) }}
          {{- end }}
          {{- with $envFrom }}
          envFrom:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with $v.startupProbe }}
          startupProbe:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with $v.livenessProbe }}
          livenessProbe:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with $v.readinessProbe }}
          readinessProbe:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with $v.lifecycle }}
          lifecycle:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with $v.securityContext }}
          securityContext:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with $v.resources }}
          resources:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with $v.volumeMounts }}
          volumeMounts:
            {{- toYaml . | nindent 12 }}
          {{- end }}
        {{- with $v.sidecars }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      {{- with $v.volumes }}
      volumes:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $v.nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $v.affinity }}
      affinity:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $v.tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $v.topologySpreadConstraints }}
      topologySpreadConstraints:
        {{- toYaml . | nindent 8 }}
      {{- end }}
{{- end -}}
