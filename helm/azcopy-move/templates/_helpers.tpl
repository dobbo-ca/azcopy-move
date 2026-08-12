{{- define "azcopy-move.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "azcopy-move.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "azcopy-move.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "azcopy-move.labels" -}}
app.kubernetes.io/name: {{ include "azcopy-move.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{- define "azcopy-move.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "azcopy-move.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "azcopy-move.secretName" -}}
{{- if .Values.sas.create -}}
{{- printf "%s-sas" (include "azcopy-move.fullname" .) -}}
{{- else -}}
{{- required "sas.existingSecret is required when sas.create is false" .Values.sas.existingSecret -}}
{{- end -}}
{{- end -}}

{{/*
Resolve one side's base URL: pass .Values.move.source or .Values.move.dest.
Verbatim endpoint when set, else derived from storageAccount + type. "type"
doubles as the endpoint subdomain (blob.core.windows.net / file.core.windows.net),
so no lookup table is needed.
*/}}
{{- define "azcopy-move.endpoint" -}}
{{- if .endpoint -}}
{{- .endpoint -}}
{{- else -}}
{{- printf "https://%s.%s.core.windows.net" .storageAccount .type -}}
{{- end -}}
{{- end -}}

{{/*
azcopy --from-to value: title(source.type) + title(dest.type), e.g.
BlobFile, BlobBlob, FileBlob, FileFile.
*/}}
{{- define "azcopy-move.fromTo" -}}
{{- printf "%s%s" (.Values.move.source.type | title) (.Values.move.dest.type | title) -}}
{{- end -}}

{{/*
"repository:tag", or bare "repository" when tag is empty so the reference
never renders a trailing colon. image.tag is "" in git; CI writes the pinned
image semver in at chart package time.
*/}}
{{- define "azcopy-move.image" -}}
{{- if .Values.image.tag -}}
{{- printf "%s:%s" .Values.image.repository .Values.image.tag -}}
{{- else -}}
{{- .Values.image.repository -}}
{{- end -}}
{{- end -}}

{{/* Fail early on the settings that would otherwise fail at runtime. */}}
{{- define "azcopy-move.validate" -}}
{{- required "image.repository is required. Build ./containers/azcopy and push it." .Values.image.repository -}}
{{- if not .Values.image.tag -}}
{{- fail "image.tag is empty. Install the packaged chart from oci://ghcr.io/dobbo-ca/azcopy-move, or set image.tag explicitly. An empty tag renders a bare repository, which resolves to :latest." -}}
{{- end -}}
{{- required "move.source.container is required" .Values.move.source.container -}}
{{- required "move.dest.container is required" .Values.move.dest.container -}}
{{- if and (not .Values.move.source.endpoint) (not .Values.move.source.storageAccount) -}}
{{- fail "move.source.storageAccount is required when move.source.endpoint is empty" -}}
{{- end -}}
{{- if and (not .Values.move.dest.endpoint) (not .Values.move.dest.storageAccount) -}}
{{- fail "move.dest.storageAccount is required when move.dest.endpoint is empty" -}}
{{- end -}}
{{- if ne .Values.concurrencyPolicy "Forbid" -}}
{{- fail "concurrencyPolicy must be Forbid. Overlapping runs would copy and delete the same files at once." -}}
{{- end -}}
{{- $srcRoot := printf "%s/%s/%s" (include "azcopy-move.endpoint" .Values.move.source) .Values.move.source.container .Values.move.source.prefix -}}
{{- $dstRoot := printf "%s/%s/%s" (include "azcopy-move.endpoint" .Values.move.dest) .Values.move.dest.container .Values.move.dest.prefix -}}
{{- if and (eq (include "azcopy-move.endpoint" .Values.move.source) (include "azcopy-move.endpoint" .Values.move.dest)) (eq .Values.move.source.container .Values.move.dest.container) -}}
{{- $srcPrefix := trimSuffix "/" .Values.move.source.prefix -}}
{{- $dstPrefix := trimSuffix "/" .Values.move.dest.prefix -}}
{{- $srcIsAncestor := or (eq $srcPrefix "") (hasPrefix (printf "%s/" $srcPrefix) $dstPrefix) -}}
{{- $dstIsAncestor := or (eq $dstPrefix "") (hasPrefix (printf "%s/" $dstPrefix) $srcPrefix) -}}
{{- if or (eq $srcPrefix $dstPrefix) (not (or $srcIsAncestor $dstIsAncestor)) -}}
{{- fail (printf "move.source and move.dest resolve to the same or overlapping location (%s vs %s). Reconcile/cleanup would delete the entire source." $srcRoot $dstRoot) -}}
{{- end -}}
{{- end -}}
{{- end -}}
