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
	reverse_proxy {{ include "mobilizon.fullname" . }}:{{ .Values.service.port }}
}
{{- with .Values.caddy.extraSites }}

{{ tpl . $ }}
{{- end }}
{{- end }}
{{- end }}
