{{- define "regional-data.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Release-qualified name. The employee service addresses these by Service name, so
the release must be called `regional-data` for `regional-data-postgres` to
resolve — which is what the ApplicationSet does (releaseName is the app name
from config.yaml).
*/}}
{{- define "regional-data.fullname" -}}
{{- $name := include "regional-data.name" . -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "regional-data.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: platform-demo
app.kubernetes.io/component: datastore
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}
