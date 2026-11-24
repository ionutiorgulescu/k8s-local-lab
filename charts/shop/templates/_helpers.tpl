{{/*
Chart name and version, for the helm.sh/chart label.
*/}}
{{- define "shop.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Labels for every object's metadata.
*/}}
{{- define "shop.labels" -}}
helm.sh/chart: {{ include "shop.chart" . }}
{{ include "shop.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Labels used in selectors. Selectors are immutable on Deployments and StatefulSets,
so these must never change between releases. Each workload adds
app.kubernetes.io/component (api or postgres) on top.
*/}}
{{- define "shop.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Image reference: repository:tag, plus @digest when one is given.
Usage: include "shop.image" (dict "image" .Values.api.image "defaultTag" .Chart.AppVersion)
*/}}
{{- define "shop.image" -}}
{{- $tag := .image.tag | default .defaultTag -}}
{{- .image.repository }}:{{ $tag }}{{ with .image.digest }}@{{ . }}{{ end }}
{{- end }}

{{/*
Database host: explicit value, else the in-chart Postgres Service.
*/}}
{{- define "shop.dbHost" -}}
{{- if .Values.database.host }}
{{- .Values.database.host }}
{{- else if .Values.postgres.enabled }}
{{- "postgres" }}
{{- else }}
{{- fail "database.host is required when postgres.enabled is false" }}
{{- end }}
{{- end }}
