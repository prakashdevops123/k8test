{{/*
============================================================
_helpers.tpl  =  reusable "functions" (named templates)
File ka naam underscore se shuru hota hai -> Helm isko
Kubernetes object nahi maanta, sirf helper maanta hai.
Isse naam aur labels ek hi jagah define hote hain (DRY).
============================================================
*/}}

{{/* Chart ka base naam, nameOverride se badla ja sakta hai */}}
{{- define "nginx.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Full resource name = "<release>-<chart>"  e.g. "nginx-lab-nginx"
Agar release ka naam pehle se chart naam rakhta hai to duplicate nahi karte.
trunc 63 kyunki Kubernetes name/label limit 63 chars hai (DNS-1123 rule).
*/}}
{{- define "nginx.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* "nginx-0.1.0" -- chart label ke liye. "+" label mein illegal hai, isliye "_" */}}
{{- define "nginx.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
SELECTOR labels -- sirf yeh Deployment ke selector mein jate hain.
YEH KABHI MAT BADLO ek live Deployment par: selector IMMUTABLE hai,
badlo to Argo CD/Helm "field is immutable" error dega.
*/}}
{{- define "nginx.selectorLabels" -}}
app.kubernetes.io/name: {{ include "nginx.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
COMMON labels -- selector labels + extra metadata.
Yeh sab resources par lagte hain (standard Kubernetes recommended labels).
version/managed-by safely badal sakte hain kyunki selector mein nahi hain.
*/}}
{{- define "nginx.labels" -}}
helm.sh/chart: {{ include "nginx.chart" . }}
{{ include "nginx.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: web
{{- end -}}
