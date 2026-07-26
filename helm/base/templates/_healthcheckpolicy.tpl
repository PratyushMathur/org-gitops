{{/*
HealthCheckPolicy — what the load balancer probes to decide a pod is serving.

Only relevant on the Gateway path, so it renders with `httpRoute`. Without it
GKE health-checks `/` on the serving port, which is wrong for anything that does
not serve `/`: the app answers 404, the NEG never reports a healthy endpoint, and
because GKE also injects the `cloud.google.com/load-balancer-neg-ready` readiness
gate, the *pod* never becomes Ready either. The result is a rollout that stalls
with a container passing its own probes:

  ContainersReady=True
  Ready=False  ReadinessGatesNotReady  ... "cloud.google.com/load-balancer-neg-ready" is not "True"

Nothing in the Deployment, the Service or the HTTPRoute looks wrong at that
point, which is what makes this worth defaulting rather than leaving to each app.

The probed path defaults to the readiness probe's, so the load balancer and
Kubernetes agree on what "serving" means — a pod that has lost its database
leaves the LB instead of being sent traffic it cannot answer.

The port is taken from the serving endpoint (`USE_SERVING_PORT`) rather than
named here, so changing a container port does not have to be mirrored in a
second place.
*/}}
{{- define "base.healthcheckpolicy" -}}
{{- $v := fromYaml (include "base.values" .) -}}
{{- if and $v.httpRoute.enabled $v.healthCheck.enabled -}}
{{- include "base.healthcheckpolicy.for" (dict "ctx" . "name" (include "base.fullname" .)) -}}
{{- end -}}
{{- end -}}

{{/*
The policy for one Service. Takes a dict so the canary track can render its own
against `<fullname>-canary` — a second Service needs a second policy, or the
canary is health-checked on `/` and silently never receives traffic.
  (dict "ctx" $ "name" "company-canary")
*/}}
{{- define "base.healthcheckpolicy.for" -}}
{{- $ctx := .ctx -}}
{{- $v := fromYaml (include "base.values" $ctx) -}}
{{- $path := $v.healthCheck.requestPath -}}
{{- if not $path -}}
{{- $path = dig "httpGet" "path" "" ($v.readinessProbe | default dict) -}}
{{- end -}}
{{- if not $path -}}
{{- $path = dig "httpGet" "path" "/" ($v.livenessProbe | default dict) -}}
{{- end -}}
apiVersion: networking.gke.io/v1
kind: HealthCheckPolicy
metadata:
  name: {{ .name }}
  labels:
    {{- include "base.labels" $ctx | nindent 4 }}
spec:
  default:
    config:
      type: HTTP
      httpHealthCheck:
        requestPath: {{ $path | quote }}
        portSpecification: USE_SERVING_PORT
    {{- with $v.healthCheck.checkIntervalSec }}
    checkIntervalSec: {{ . }}
    {{- end }}
    {{- with $v.healthCheck.timeoutSec }}
    timeoutSec: {{ . }}
    {{- end }}
    {{- with $v.healthCheck.healthyThreshold }}
    healthyThreshold: {{ . }}
    {{- end }}
    {{- with $v.healthCheck.unhealthyThreshold }}
    unhealthyThreshold: {{ . }}
    {{- end }}
  targetRef:
    group: ""
    kind: Service
    name: {{ .name }}
{{- end -}}
