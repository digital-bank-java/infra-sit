{{- define "opensearch.name" -}}
opensearch
{{- end -}}

{{- define "opensearch.fullname" -}}
{{ include "opensearch.name" . }}
{{- end -}}

{{- define "opensearch.dashboardsName" -}}
opensearch-dashboards
{{- end -}}

{{- define "opensearch.namespace" -}}
{{- default .Release.Namespace .Values.namespaceOverride -}}
{{- end -}}

{{- define "opensearch.labels" -}}
app.kubernetes.io/name: {{ include "opensearch.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{- end -}}

{{- define "opensearch.selectorLabels" -}}
app.kubernetes.io/name: {{ include "opensearch.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "opensearch.dashboardsLabels" -}}
app.kubernetes.io/name: {{ include "opensearch.dashboardsName" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{- end -}}

{{- define "opensearch.dashboardsSelectorLabels" -}}
app.kubernetes.io/name: {{ include "opensearch.dashboardsName" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
