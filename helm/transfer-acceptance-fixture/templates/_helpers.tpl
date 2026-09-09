{{- define "transfer-acceptance-fixture.name" -}}
transfer-acceptance-fixture
{{- end -}}

{{- define "transfer-acceptance-fixture.namespace" -}}
{{- default .Release.Namespace .Values.namespaceOverride -}}
{{- end -}}

{{- define "transfer-acceptance-fixture.requireSitNamespace" -}}
{{- if ne (include "transfer-acceptance-fixture.namespace" .) "digital-bank-sit" -}}
{{- fail "transfer-acceptance-fixture may only be enabled in the digital-bank-sit namespace" -}}
{{- end -}}
{{- end -}}

{{- define "transfer-acceptance-fixture.labels" -}}
app.kubernetes.io/name: {{ include "transfer-acceptance-fixture.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{- end -}}

{{- define "transfer-acceptance-fixture.selectorLabels" -}}
app.kubernetes.io/name: {{ include "transfer-acceptance-fixture.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
