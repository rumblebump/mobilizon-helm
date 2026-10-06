{{- define "mobilizon.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "mobilizon.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "mobilizon.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{ include "mobilizon.selectorLabels" . }}
{{- end }}

{{- define "mobilizon.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mobilizon.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "mobilizon.postgresql.fullname" -}}
{{- printf "%s-postgresql" (include "mobilizon.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "mobilizon.database.host" -}}
{{- if .Values.database.host }}
{{- .Values.database.host }}
{{- else if .Values.postgresql.enabled }}
{{- include "mobilizon.postgresql.fullname" . }}
{{- else }}
{{- fail "database.host is required when postgresql.enabled=false" }}
{{- end }}
{{- end }}

{{/*
secretKeyRef to a user-supplied Secret, or to the chart-managed one.
Usage: include "mobilizon.secretKeyRef" (list $ .Values.x.existingSecret .Values.x.secretKeys.y "generated-key")
*/}}
{{- define "mobilizon.secretKeyRef" -}}
{{- $root := index . 0 }}
{{- $existing := index . 1 -}}
valueFrom:
  secretKeyRef:
    name: {{ $existing | default (include "mobilizon.fullname" $root) }}
    key: {{ ternary (index . 2) (index . 3) (ne $existing "") }}
{{- end }}

{{/* Username as a plain value, or from existingSecret when secretKeys.username is set. */}}
{{- define "mobilizon.username" -}}
{{- $cfg := index . 1 -}}
{{- if and $cfg.existingSecret $cfg.secretKeys.username -}}
valueFrom:
  secretKeyRef:
    name: {{ $cfg.existingSecret }}
    key: {{ $cfg.secretKeys.username }}
{{- else -}}
value: {{ $cfg.username | quote }}
{{- end }}
{{- end }}

{{- define "mobilizon.database.env" -}}
- name: MOBILIZON_DATABASE_HOST
  value: {{ include "mobilizon.database.host" . | quote }}
- name: MOBILIZON_DATABASE_PORT
  value: {{ .Values.database.port | quote }}
- name: MOBILIZON_DATABASE_DBNAME
  value: {{ .Values.database.name | quote }}
- name: MOBILIZON_DATABASE_USERNAME
  {{- include "mobilizon.username" (list . .Values.database) | nindent 2 }}
- name: MOBILIZON_DATABASE_PASSWORD
  {{- include "mobilizon.secretKeyRef" (list . .Values.database.existingSecret .Values.database.secretKeys.password "database-password") | nindent 2 }}
- name: MOBILIZON_DATABASE_SSL
  value: {{ .Values.database.ssl | quote }}
{{- end }}

{{/* Caddyfile: caddy.caddyfile verbatim, or TLS for mobilizon.host in front of the Mobilizon service. */}}
{{- define "mobilizon.caddyfile" -}}
{{- if .Values.caddy.caddyfile -}}
{{ tpl .Values.caddy.caddyfile . }}
{{- else -}}
{
	http_port 8080
	https_port 8443
	# The pod listens on 8080/8443, so build the HTTPS redirect below without the port.
	auto_https disable_redirects
	{{- with .Values.caddy.email }}
	email {{ . }}
	{{- end }}
	{{- with .Values.caddy.globalOptions }}
	{{- tpl . $ | trim | replace "\n" "\n\t" | printf "\n\t%s" }}
	{{- end }}
}

http://{{ required "mobilizon.host is required (the public hostname, fixed after the first start)" .Values.mobilizon.host }} {
	redir https://{host}{uri} permanent
}

{{ .Values.mobilizon.host }} {
	{{- with .Values.caddy.siteConfig }}
	{{- tpl . $ | trim | replace "\n" "\n\t" | printf "\n\t%s" }}
	{{- end }}
	{{- with include "mobilizon.dex.path" . }}
	reverse_proxy {{ trimSuffix "/" . }}/* {{ include "mobilizon.dex.fullname" $ }}:5556
	{{- end }}
	reverse_proxy {{ include "mobilizon.fullname" . }}:{{ .Values.service.port }}
}
{{- with .Values.caddy.extraSites }}

{{ tpl . $ }}
{{- end }}
{{- end }}
{{- end }}

{{- define "mobilizon.dex.fullname" -}}
{{- printf "%s-dex" (include "mobilizon.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "mobilizon.dex.issuer" -}}
{{- .Values.dex.issuer | default (printf "https://%s/dex" .Values.mobilizon.host) }}
{{- end }}

{{/* Path of the Dex issuer when it is served on mobilizon.host, so the chart can route it. Empty otherwise. */}}
{{- define "mobilizon.dex.path" -}}
{{- if .Values.dex.enabled }}
{{- $url := urlParse (include "mobilizon.dex.issuer" .) }}
{{- if eq $url.host .Values.mobilizon.host }}
{{- $url.path | default "/" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "mobilizon.oidc.enabled" -}}
{{- if or .Values.oidc.enabled .Values.dex.enabled }}true{{ end }}
{{- end }}

{{- define "mobilizon.oidc.issuer" -}}
{{- if .Values.oidc.issuer }}
{{- .Values.oidc.issuer }}
{{- else if .Values.dex.enabled }}
{{- include "mobilizon.dex.issuer" . }}
{{- else }}
{{- fail "oidc.issuer is required when oidc.enabled=true" }}
{{- end }}
{{- end }}

{{- define "mobilizon.oidc.clientId" -}}
{{- if .Values.oidc.clientId }}
{{- .Values.oidc.clientId }}
{{- else if .Values.dex.enabled }}mobilizon
{{- else }}
{{- fail "oidc.clientId is required when oidc.enabled=true" }}
{{- end }}
{{- end }}

{{- define "mobilizon.oidc.clientSecret" -}}
{{- include "mobilizon.secretKeyRef" (list . .Values.oidc.existingSecret .Values.oidc.secretKeys.clientSecret "oidc-client-secret") }}
{{- end }}

{{/* Loaded through MOBILIZON_CONFIG_PATH instead of the image's config.exs, which it imports first. */}}
{{- define "mobilizon.configExs" -}}
import Config

import_config "/etc/mobilizon/config.exs"

config :ueberauth_oidcc, :issuers, [
  %{
    name: :chart_oidc,
    issuer: {{ include "mobilizon.oidc.issuer" . | toJson }}
    {{- if .Values.oidc.plainAuthorizationRequest }},
    # oidcc otherwise signs the request with the client secret (HS256 request object), pushes it
    # to the PAR endpoint and asks for a JWT-wrapped response when the provider advertises
    # them. Authelia does, and rejects that unless the client is set up for it; Mobilizon answers
    # such a failure on /auth/keycloak with a 500. Hide them to send a plain code + PKCE request.
    provider_configuration_opts: %{
      quirks: %{
        document_overrides: %{
          "request_parameter_supported" => false,
          "pushed_authorization_request_endpoint" => :undefined,
          "response_modes_supported" => ["query"]
        }
      }
    }
    {{- end }}
  }
]

# The login page only shows buttons for provider ids in a fixed list (src/utils/auth.ts) that
# has no "oidc", so the generic OIDC strategy runs under the "keycloak" id with our own label.
config :ueberauth, Ueberauth,
  providers: [
    keycloak:
      {Ueberauth.Strategy.Oidcc,
       [
         issuer: :chart_oidc,
         client_id: {{ include "mobilizon.oidc.clientId" . | toJson }},
         client_secret: System.fetch_env!("MOBILIZON_OIDC_CLIENT_SECRET"),
         scopes: {{ .Values.oidc.scopes | toJson }},
         # Mobilizon sees plain HTTP on port 4000 behind the proxy, so fix the redirect URI.
         callback_url: {{ printf "https://%s/auth/keycloak/callback" .Values.mobilizon.host | toJson }}
         {{- if .Values.oidc.userinfo }},
         # Read email and name from the userinfo endpoint, not only the ID token.
         userinfo: true
         {{- end }}
         {{- with .Values.oidc.tokenEndpointAuthMethod }}
         {{- if not (has . (list "client_secret_basic" "client_secret_post" "client_secret_jwt" "private_key_jwt")) }}
         {{- fail "oidc.tokenEndpointAuthMethod must be client_secret_basic, client_secret_post, client_secret_jwt or private_key_jwt" }}
         {{- end }},
         # Otherwise oidcc picks the strongest method the provider advertises.
         preferred_auth_methods: [:{{ . }}]
         {{- end }}
       ]}
  ]

# ueberauth_oidcc looks up runtime options by the provider name, which Mobilizon passes as a
# string. Without this map that lookup hits a keyword list and raises an ArgumentError.
config :ueberauth_oidcc, :providers, %{"keycloak" => []}

config :mobilizon, :auth,
  oauth_consumer_strategies: [{:keycloak, {{ .Values.oidc.label | default (ternary "Dex" "OpenID Connect" .Values.dex.enabled) | toJson }}}]
{{- end }}

{{/* Dex config: static client for Mobilizon and local users, with dex.config merged over it. */}}
{{- define "mobilizon.dex.config" -}}
{{- $config := dict
  "issuer" (include "mobilizon.dex.issuer" .)
  "storage" (dict "type" "memory")
  "web" (dict "http" "0.0.0.0:5556")
  "telemetry" (dict "http" "0.0.0.0:5558")
  "oauth2" (dict "passwordConnector" "local" "skipApprovalScreen" true)
  "enablePasswordDB" true
  "staticClients" (list (dict
    "id" (include "mobilizon.oidc.clientId" .)
    "name" .Values.mobilizon.name
    "secretEnv" "DEX_CLIENT_SECRET"
    "redirectURIs" (list (printf "https://%s/auth/keycloak/callback" .Values.mobilizon.host))))
  "staticPasswords" .Values.dex.staticPasswords
}}
{{- mergeOverwrite $config (deepCopy .Values.dex.config) | toYaml }}
{{- end }}
