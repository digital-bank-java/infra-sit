{{- define "zipkin.name" -}}
zipkin
{{- end -}}

{{- define "zipkin.fullname" -}}
{{ include "zipkin.name" . }}
{{- end -}}

{{- define "zipkin.namespace" -}}
{{- default .Release.Namespace .Values.namespaceOverride -}}
{{- end -}}

{{- define "zipkin.labels" -}}
app.kubernetes.io/name: {{ include "zipkin.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{- end -}}

{{- define "zipkin.selectorLabels" -}}
app.kubernetes.io/name: {{ include "zipkin.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
