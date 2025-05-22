{{/* Generate basic labels */}}
{{- define "controlplane-operations.labels" }}
{{- $path := index . 0 -}}
{{- $root := index . 1 -}}
app.kubernetes.io/version: {{ $root.Chart.Version }}
app.kubernetes.io/part-of: {{ $root.Release.Name }}
{{- if $root.Values.global.commonLabels}}
{{ toYaml $root.Values.global.commonLabels }}
{{- end }}
{{- end }}

{{- define "controlplane-operations.ruleSelectorLabels" }}
{{- $path := index . 0 -}}
{{- $root := index . 1 -}}
plugin: {{ $root.Release.Name }}
{{- if $root.Values.prometheusRules.ruleSelectors }}
{{- range $i, $target := $root.Values.prometheusRules.ruleSelectors }}
{{ $target.name | required (printf "$.Values.prometheusRules.ruleSelector.[%v].name missing" $i) }}: {{ tpl ($target.value | required (printf "$.Values.prometheusRules.ruleSelector.[%v].value missing" $i)) $root }}
{{- end }}
{{- end }}
{{- end }}

{{- define "controlplane-operations.additionalRuleLabels" }}
{{- if .Values.prometheusRules.additionalRuleLabels }}
  {{- toYaml .Values.prometheusRules.additionalRuleLabels | nindent 6 }}
{{- end }}
{{- if .Values.global.commonLabels }}
{{ tpl (toYaml .Values.global.commonLabels) . }}
{{- end }}
{{- end }}

{{- define "controlplane-operations.dashboardSelectorLabels" }}
{{- $path := index . 0 -}}
{{- $root := index . 1 -}}
plugin: {{ $root.Release.Name }}
{{- if $root.Values.dashboards.persesSelectors }}
{{- range $i, $target := $root.Values.dashboards.persesSelectors }}
{{ $target.name | required (printf "$.Values.dashboards.persesSelectors.[%v].name missing" $i) }}: {{ tpl ($target.value | required (printf "$.Values.dashboards.persesSelectors.[%v].value missing" $i)) $ }}
{{- end }}
{{- end }}
{{- end }}
