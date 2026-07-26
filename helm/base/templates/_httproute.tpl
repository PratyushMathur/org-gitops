{{/*
HTTPRoute — an app's slice of the shared Gateway.

This replaces `base.ingress` for anything fronted by the GKE Gateway. The route
does not create a load balancer; it attaches to the Gateway named in
`httpRoute.parentRefs` and claims a set of hostnames and paths on it.

Two apps attached to the same Gateway must not claim the same hostname AND the
same path — Gateway API resolves that conflict by creation timestamp, so the
loser silently stops serving. Because both prod clusters expose a single
hostname (api-ind / api-us), the apps are separated by path prefix instead:
`company` owns /companies, `employee` owns /employees.

Canary traffic splitting lives here rather than in a second object. Gateway API
takes weights natively on `backendRefs`, so one route describes the whole split
— see the comment on the weighted rule below.
*/}}
{{- define "base.httproute" -}}
{{- $v := fromYaml (include "base.values" .) -}}
{{- if $v.httpRoute.enabled -}}
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: {{ include "base.fullname" . }}
  labels:
    {{- include "base.labels" . | nindent 4 }}
  {{- $annotations := merge (deepCopy ($v.httpRoute.annotations | default dict)) ($v.commonAnnotations | default dict) }}
  {{- with $annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  parentRefs:
    {{- toYaml (required "httpRoute.parentRefs is required" $v.httpRoute.parentRefs) | nindent 4 }}
  {{- with $v.httpRoute.hostnames }}
  hostnames:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  rules:
    {{- include "base.httproute.rules" . | nindent 4 }}
{{- end -}}
{{- end -}}

{{/*
Resolves a Service port given either its name or its number, so `servicePort`
can be written the same way it is on an Ingress backend. Takes a dict:
  (dict "ctx" $ "port" .servicePort)
*/}}
{{- define "base.httproute.portNumber" -}}
{{- $v := fromYaml (include "base.values" .ctx) -}}
{{- $want := .port | default "http" -}}
{{- if kindIs "string" $want -}}
{{- $found := "" -}}
{{- range $v.service.ports -}}
{{- if eq .name $want -}}
{{- $found = .port -}}
{{- end -}}
{{- end -}}
{{- if eq (toString $found) "" -}}
{{- fail (printf "httpRoute: no service port named %q — service.ports defines %v" $want $v.service.ports) -}}
{{- end -}}
{{- $found -}}
{{- else -}}
{{- $want -}}
{{- end -}}
{{- end -}}

{{/*
The rule list. One weighted rule per configured path, optionally preceded by a
header-match rule that pins a request to the canary.
*/}}
{{- define "base.httproute.rules" -}}
{{- $ctx := . -}}
{{- $v := fromYaml (include "base.values" $ctx) -}}
{{- $fullName := include "base.fullname" $ctx -}}
{{- $canaryName := printf "%s-canary" $fullName -}}
{{- $canary := $v.canary | default dict -}}
{{- $weight := $canary.weight | default 0 | int -}}
{{- if $canary.enabled -}}
{{- if or (lt $weight 0) (gt $weight 100) -}}
{{- fail (printf "canary.weight must be between 0 and 100, got %d" $weight) -}}
{{- end -}}
{{- end -}}
{{- $rules := list -}}
{{- range $v.httpRoute.paths -}}
{{/* Ingress spells this "Prefix"; Gateway API spells it "PathPrefix". */}}
{{- $pathType := .pathType | default "PathPrefix" -}}
{{- if eq $pathType "Prefix" -}}
{{- $pathType = "PathPrefix" -}}
{{- end -}}
{{- $port := include "base.httproute.portNumber" (dict "ctx" $ctx "port" .servicePort) | int -}}
{{- $match := dict "path" (dict "type" $pathType "value" (.path | default "/")) -}}
{{/*
The header rule comes first for readability only. Gateway API ranks matches by
specificity, not by order, and a rule carrying header matches always outranks
one that does not — so `curl -H "X-Canary: always"` is deterministic proof the
canary is live, independent of the weight.
*/}}
{{- if and $canary.enabled $canary.header -}}
{{- $headerMatch := merge (dict "headers" (list (dict
      "name" $canary.header
      "value" ($canary.headerValue | default "always")))) (deepCopy $match) -}}
{{- $rules = append $rules (dict
      "matches" (list $headerMatch)
      "backendRefs" (list (dict "name" $canaryName "port" $port))) -}}
{{- end -}}
{{/*
Weights are relative, not percentages, but they are written to sum to 100 so the
rendered manifest reads as the percentage split it is meant to be.
*/}}
{{- $backendRefs := list (dict "name" $fullName "port" $port) -}}
{{- if $canary.enabled -}}
{{- $backendRefs = list
      (dict "name" $fullName  "port" $port "weight" (sub 100 $weight))
      (dict "name" $canaryName "port" $port "weight" $weight) -}}
{{- end -}}
{{- $rules = append $rules (dict "matches" (list $match) "backendRefs" $backendRefs) -}}
{{- end -}}
{{- range $v.httpRoute.extraRules -}}
{{- $rules = append $rules . -}}
{{- end -}}
{{- if not $rules -}}
{{- fail "httpRoute.enabled is true but neither httpRoute.paths nor httpRoute.extraRules produced a rule" -}}
{{- end -}}
{{- toYaml $rules -}}
{{- end -}}
