{{- define "wordpress.labels" -}}
app.kubernetes.io/name: wordpress
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{- define "wordpress.selectorLabels" -}}
app.kubernetes.io/name: wordpress
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "wordpress.uploadsClaim" -}}
{{- if .Values.uploads.existingClaim -}}
{{ .Values.uploads.existingClaim }}
{{- else -}}
{{ .Release.Name }}-uploads
{{- end -}}
{{- end }}

{{- define "wordpress.configExtra" -}}
{{- with .Values.siteUrl }}
define('WP_HOME', '{{ . }}');
define('WP_SITEURL', '{{ . }}');
{{- end }}
{{ .Values.wpConfigExtra }}
{{- end }}
