{{/*
The cluster's north-south Gateway.

Unlike every other template here this one is NOT part of `base.all`: a Gateway is
per-cluster infrastructure shared by every app, not something each release owns.
Exactly one chart renders it — `helm/gateway` — and the app charts attach to it
by name through `httpRoute.parentRefs`. If two app charts both rendered a
Gateway they would fight over the same static IP.

The load balancer itself is created by the GKE Gateway controller from this
object. Terraform owns only what must outlive it — the reserved regional IP and
the public DNS name (org-infra `live/prod/cluster-a/platform/main.tf`) — and the
Gateway claims that IP by name rather than by address, so recreating the Gateway
does not renumber the DNS record.

  templates/all.yaml
  ---------------------------------
  {{ include "base.gateway" . }}
*/}}
{{- define "base.gateway" -}}
{{- $v := fromYaml (include "base.values" .) -}}
{{- if $v.gateway.enabled -}}
{{- $annotations := merge (deepCopy ($v.gateway.annotations | default dict)) ($v.commonAnnotations | default dict) -}}
{{/*
Certificate Manager map, attached by annotation rather than by a `certificateRefs`
entry on the listener: the certificates are Google-managed and live outside the
cluster, so there is no Secret for a listener to reference.
*/}}
{{- with $v.gateway.certificateMap -}}
{{- $_ := set $annotations "networking.gke.io/certmap" . -}}
{{- end -}}
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: {{ $v.gateway.name | default (include "base.fullname" .) }}
  labels:
    {{- include "base.labels" . | nindent 4 }}
  {{- with $annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  gatewayClassName: {{ required "gateway.className is required" $v.gateway.className }}
  {{- /*
  A named address, not a literal one: the name is stable across Gateway
  recreation, while the IP behind it is Terraform's to allocate and DNS's to
  publish. Omit both and GKE allocates an ephemeral IP, which programs happily
  and quietly does not match the A record — so this is worth getting right.

  `NamedAddress` is bare, with no domain prefix. Gateway API reserves prefixed
  types for implementation extensions, so `networking.gke.io/NamedAddress` looks
  like the more correct spelling, but the GKE controller rejects it:

    Error GWCER106: Gateway is invalid, err: unsupported address type
    "networking.gke.io/NamedAddress".

  That failure is asynchronous — admission accepts the object and the listener
  only later reports UnsupportedAddress, so a wrong type here surfaces as a
  Gateway that never programs, not as a rejected apply.
  */ -}}
  {{- if $v.gateway.addressName }}
  addresses:
    - type: NamedAddress
      value: {{ $v.gateway.addressName | quote }}
  {{- else if $v.gateway.addressIP }}
  addresses:
    - type: IPAddress
      value: {{ $v.gateway.addressIP | quote }}
  {{- end }}
  listeners:
    {{- toYaml (required "gateway.listeners must not be empty" $v.gateway.listeners) | nindent 4 }}
{{- end -}}
{{- end -}}
