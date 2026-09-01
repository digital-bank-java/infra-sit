{{- define "kafka.name" -}}
kafka
{{- end -}}

{{- define "kafka.namespace" -}}
{{- default .Release.Namespace .Values.namespaceOverride -}}
{{- end -}}

{{- define "kafka.fullname" -}}
{{ include "kafka.name" . }}
{{- end -}}

{{- define "kafka.bootstrapHost" -}}
{{ include "kafka.fullname" . }}.{{ include "kafka.namespace" . }}.svc.cluster.local
{{- end -}}

{{- define "kafka.bootstrapServer" -}}
{{ include "kafka.bootstrapHost" . }}:{{ .Values.service.clientPort }}
{{- end -}}

{{- define "kafka.labels" -}}
app.kubernetes.io/name: {{ include "kafka.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{- end -}}

{{- define "kafka.selectorLabels" -}}
app.kubernetes.io/name: {{ include "kafka.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
