{{- define "fluent-bit.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "fluent-bit.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- include "fluent-bit.name" . }}
{{- end }}
{{- end }}

{{- define "fluent-bit.namespace" -}}
{{- default .Release.Namespace .Values.namespaceOverride }}
{{- end }}

{{- define "fluent-bit.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ include "fluent-bit.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "fluent-bit.selectorLabels" -}}
app.kubernetes.io/name: {{ include "fluent-bit.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
