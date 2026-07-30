{{- define "akhq.name" -}}
akhq
{{- end -}}

{{- define "akhq.namespace" -}}
{{- default .Release.Namespace .Values.namespaceOverride -}}
{{- end -}}

{{- define "akhq.fullname" -}}
{{ include "akhq.name" . }}
{{- end -}}

{{- define "akhq.labels" -}}
app.kubernetes.io/name: {{ include "akhq.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{- end -}}

{{- define "akhq.selectorLabels" -}}
app.kubernetes.io/name: {{ include "akhq.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
