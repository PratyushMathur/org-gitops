{{/*
HTTPRoute — an app's slice of the shared Gateway. It creates no load balancer; it
attaches to the Gateway named in `httpRoute.parentRefs` and claims hostnames and
paths on it.

Two apps on the same Gateway must not claim the same hostname AND path — Gateway
API resolves that by creation timestamp, so the loser silently stops serving.
Both prod clusters expose one hostname, so apps are separated by path instead:
company owns /companies, employee owns /employees.
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
Resolves a Service port given either its name or its number. Takes a dict:
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
One rule per configured path, preceded on the Rollout path by a header-match rule
pinning a request to the canary.
*/}}
{{- define "base.httproute.rules" -}}
{{- $ctx := . -}}
{{- $v := fromYaml (include "base.values" $ctx) -}}
{{- $fullName := include "base.fullname" $ctx -}}
{{- $canaryName := printf "%s-canary" $fullName -}}
{{- $rollout := $v.rollout | default dict -}}
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
Gateway API ranks matches by specificity, not order, and a rule carrying header
matches always outranks one that does not — so `curl -H "X-Canary: always"` is
deterministic proof the canary is live, independent of the weight.
*/}}
{{- if and $rollout.enabled $rollout.header -}}
{{- $headerMatch := merge (dict "headers" (list (dict
      "name" $rollout.header
      "value" ($rollout.headerValue | default "always")))) (deepCopy $match) -}}
{{- $rules = append $rules (dict
      "matches" (list $headerMatch)
      "backendRefs" (list (dict "name" $canaryName "port" $port))) -}}
{{- end -}}
{{/*
Both backends have to be present from the start: the Gateway API plugin rewrites
the weights of backends already on the route, it does not add them. Written 100/0
and the controller moves it from there.
*/}}
{{- $backendRefs := list (dict "name" $fullName "port" $port) -}}
{{- if $rollout.enabled -}}
{{- $backendRefs = list
      (dict "name" $fullName   "port" $port "weight" 100)
      (dict "name" $canaryName "port" $port "weight" 0) -}}
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
