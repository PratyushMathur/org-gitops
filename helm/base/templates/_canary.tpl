{{/*
Canary release support.

`base.all` renders the stable track. `base.canary` renders a second, smaller
copy of the same workload — Deployment, Service and, on the legacy Ingress path,
a second Ingress — so a share of live traffic reaches the new version while the
rest keeps hitting stable.

Where the split is expressed depends on which north-south path is in use:

  httpRoute.enabled   the split is weighted `backendRefs` inside the app's single
                      HTTPRoute (see `base.httproute.rules`). This template then
                      renders only the workload, and no second routing object.
  ingress.enabled     the split is a second Ingress carrying ingress-nginx's
                      canary annotations, described further down.

Gateway API takes the weight natively, which is why the HTTPRoute path needs one
object where the Ingress path needs two.

An app chart opts in with:

  templates/all.yaml
  ---------------------------------
  {{ include "base.all" . }}
  {{ include "base.canary" . }}

and values like:

  canary:
    enabled: true
    weight: 20          # percent of requests sent to the canary
    image:
      tag: "2.0.0"

Everything under `canary` other than the control keys (`enabled`, `weight`,
`header`, `headerValue`) is deep-merged over the stable values, so the canary
inherits probes, resources and config unless it deliberately differs.

Why ingress-level and not a second Deployment behind one Service: with one
Service the split is whatever the replica ratio happens to be, it cannot be set
or changed without scaling, and nothing in the response says which track
answered. Splitting at the ingress makes the weight an explicit, adjustable
number and gives each track its own Service, which is what makes the split
observable from outside.

Note the split is north-south only. In-cluster callers resolve the stable
Service and never reach the canary; that is deliberate, so a canary cannot
silently take east-west traffic that nobody is watching.
*/}}
{{- define "base.canary" -}}
{{- $v := fromYaml (include "base.values" .) -}}
{{- if $v.canary.enabled -}}
{{- $weight := $v.canary.weight | int -}}
{{- if or (lt $weight 0) (gt $weight 100) -}}
{{- fail (printf "canary.weight must be between 0 and 100, got %d" $weight) -}}
{{- end -}}

{{/* Control keys configure the split itself; the rest describes the workload. */}}
{{- $overrides := omit $v.canary "enabled" "weight" "header" "headerValue" -}}
{{- $cv := mergeOverwrite (deepCopy $v) $overrides -}}

{{/*
Distinct names and, crucially, a distinct app.kubernetes.io/name — that label is
what the stable Service selects on, so overriding it here is what keeps canary
pods out of the stable Service.
*/}}
{{- $_ := set $cv "nameOverride" (printf "%s-canary" (include "base.name" .)) -}}
{{- $_ = set $cv "fullnameOverride" (printf "%s-canary" (include "base.fullname" .)) -}}

{{/* The canary reuses the stable ServiceAccount rather than creating a second. */}}
{{- $_ = set $cv "serviceAccount" (mergeOverwrite (deepCopy $v.serviceAccount)
      (dict "create" false "name" (include "base.serviceAccountName" .))) -}}

{{/*
TRACK is set here rather than left to the app chart: the whole point of a canary
is that the response can be attributed to it, and a track label that has to be
remembered per chart is one that eventually is not.
*/}}
{{- $_ = set $cv "config" (mergeOverwrite (deepCopy ($v.config | default dict))
      (dict "TRACK" "canary")
      (deepCopy ($v.canary.config | default dict))) -}}

{{/* Drop the recursive key so the derived context cannot render its own canary. */}}
{{- $_ = unset $cv "canary" -}}

{{- $ctx := dict "Chart" .Chart "Release" .Release "Capabilities" .Capabilities "Template" .Template "Values" $cv -}}

{{/*
The ConfigMap is rendered too, not just the Deployment: base.deployment wires
`envFrom` to a ConfigMap named after the release, and the canary's name differs,
so omitting it would leave the canary pods referencing a ConfigMap that does not
exist. It also has to be the canary's own, since this is where TRACK=canary and
the canary's VERSION are carried.
*/}}
{{- $docs := list (include "base.configmap" $ctx) (include "base.deployment" $ctx) (include "base.service" $ctx) -}}

{{/*
The canary Service needs its own HealthCheckPolicy. Policies are per-Service, so
without this one the canary is health-checked on `/`, its NEG never reports a
healthy endpoint, and it receives none of the traffic the weight promises it.
*/}}
{{- if and $v.httpRoute.enabled $v.healthCheck.enabled -}}
{{- $docs = append $docs (include "base.healthcheckpolicy.for" (dict
      "ctx" $ctx "name" (printf "%s-canary" (include "base.fullname" .)))) -}}
{{- end -}}

{{/*
The canary Ingress duplicates the stable host rules with the canary annotations
attached. ingress-nginx requires both Ingresses to cover the same host/path for
the split to apply.
*/}}
{{/*
Only on the legacy Ingress path. With an HTTPRoute the weight already lives on
that route's backendRefs, and rendering a second routing object here would give
the Gateway two routes claiming the same hostname and path — a conflict Gateway
API settles by creation timestamp, silently.
*/}}
{{- if and $v.ingress.enabled (not $v.httpRoute.enabled) -}}
{{- $annotations := dict -}}
{{- range $key, $value := ($v.ingress.annotations | default dict) -}}
{{/*
cert-manager annotations are stripped: they would make the canary Ingress
request a second certificate for hosts the stable Ingress already owns, which
at best duplicates issuance and at worst trips rate limits. The canary reuses
the stable Ingress's TLS secret instead.
*/}}
{{- if not (hasPrefix "cert-manager.io/" $key) -}}
{{- $_ := set $annotations $key $value -}}
{{- end -}}
{{- end -}}
{{- $_ := set $annotations "nginx.ingress.kubernetes.io/canary" "true" -}}
{{- $_ = set $annotations "nginx.ingress.kubernetes.io/canary-weight" (printf "%d" $weight) -}}
{{/*
A header override alongside the weight, so the canary can be reached on demand
instead of only by chance. Without it, confirming a 5% canary means issuing
enough requests to be statistically sure — with it, one curl is proof.
*/}}
{{- with $v.canary.header -}}
{{- $_ = set $annotations "nginx.ingress.kubernetes.io/canary-by-header" . -}}
{{- $_ = set $annotations "nginx.ingress.kubernetes.io/canary-by-header-value" ($v.canary.headerValue | default "always") -}}
{{- end -}}
{{/*
`set` rather than `mergeOverwrite`: a deep merge would fold the stripped
cert-manager keys back in from the stable annotations. The canary's annotation
map has to replace the stable one outright, not merge with it.
*/}}
{{- $canaryIngress := deepCopy $v.ingress -}}
{{- $_ = set $canaryIngress "annotations" $annotations -}}
{{- $_ = set $cv "ingress" $canaryIngress -}}
{{- $docs = append $docs (include "base.ingress" $ctx) -}}
{{- end -}}

{{- range $docs }}
{{- $doc := trim . }}
{{- if $doc }}
---
{{ $doc }}
{{- end }}
{{- end }}
{{- end -}}
{{- end -}}
