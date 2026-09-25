{{- define "kubiverse.name" -}}{{ .Release.Name }}-kubiverse{{- end -}}
{{- define "kubiverse.labels" -}}
app.kubernetes.io/name: kubiverse
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end -}}
{{- define "kubiverse.selector" -}}
app.kubernetes.io/name: kubiverse
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
