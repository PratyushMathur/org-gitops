{{/*
Chart name, overridable via nameOverride.
*/}}
{{- define "base.name" -}}
{{- $v := fromYaml (include "base.values" .) -}}
{{- default .Chart.Name $v.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fully qualified release name, truncated to the 63 char DNS limit.
*/}}
{{- define "base.fullname" -}}
{{- $v := fromYaml (include "base.values" .) -}}
{{- if $v.fullnameOverride -}}
{{- $v.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name $v.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
helm.sh/chart label value.
*/}}
{{- define "base.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
app.kubernetes.io/version. Prefers the image tag over appVersion so GitOps tag
bumps show up on the object, and sanitises characters that are illegal in a
label value (digests, registry ports).
*/}}
{{- define "base.versionLabel" -}}
{{- $v := fromYaml (include "base.values" .) -}}
{{- $ver := $v.image.tag | default .Chart.AppVersion | default "" | toString -}}
{{- $ver | replace ":" "_" | replace "@" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Selector labels. These land in a Deployment's immutable selector, so nothing
that changes between releases may be added here.
*/}}
{{- define "base.selectorLabels" -}}
app.kubernetes.io/name: {{ include "base.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Common labels applied to every object.
*/}}
{{- define "base.labels" -}}
{{- $v := fromYaml (include "base.values" .) -}}
helm.sh/chart: {{ include "base.chart" . }}
{{ include "base.selectorLabels" . }}
app.kubernetes.io/version: {{ include "base.versionLabel" . | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with $v.component }}
app.kubernetes.io/component: {{ . | quote }}
{{- end }}
{{- with $v.partOf }}
app.kubernetes.io/part-of: {{ . | quote }}
{{- end }}
{{- with $v.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
Fully qualified image reference. Digest wins over tag.
*/}}
{{- define "base.image" -}}
{{- $v := fromYaml (include "base.values" .) -}}
{{- $repo := required "image.repository is required" $v.image.repository -}}
{{- with $v.image.registry -}}
{{- $repo = printf "%s/%s" . $repo -}}
{{- end -}}
{{- if $v.image.digest -}}
{{- printf "%s@%s" $repo $v.image.digest -}}
{{- else -}}
{{- $tag := $v.image.tag | default .Chart.AppVersion -}}
{{- printf "%s:%s" $repo (required "image.tag or Chart.appVersion is required" $tag | toString) -}}
{{- end -}}
{{- end -}}

{{/*
Name of the ServiceAccount to use.
*/}}
{{- define "base.serviceAccountName" -}}
{{- $v := fromYaml (include "base.values" .) -}}
{{- if $v.serviceAccount.create -}}
{{- default (include "base.fullname" .) $v.serviceAccount.name -}}
{{- else -}}
{{- default "default" $v.serviceAccount.name -}}
{{- end -}}
{{- end -}}
