{{- define "rsr.fullname" -}}
{{- if .Values.nameOverride -}}
{{- .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
redis-sentinel-reconciler
{{- end -}}
{{- end -}}

{{- define "rsr.labels" -}}
app: redis-sentinel-reconciler
app.kubernetes.io/name: redis-sentinel-reconciler
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "rsr.commonArgs" -}}
- --master-name={{ .Values.masterName }}
- --interval={{ .Values.interval }}
- --heal-cooldown={{ .Values.healCooldown }}
{{- if .Values.localSentinel }}
- --local-sentinel
{{- else }}
- --local-sentinel=false
{{- end }}
{{- if .Values.healLease }}
- --heal-lease=true
{{- else }}
- --heal-lease=false
{{- end }}
{{- if .Values.equalEpochEscalate }}
- --equal-epoch-escalate=true
{{- end }}
{{- if .Values.apply }}
- --apply
{{- end }}
{{- if .Values.metrics.enabled }}
- --metrics-addr=:{{ .Values.metrics.port }}
{{- end }}
{{- range .Values.redisAddrs }}
- --redis-addrs={{ . }}
{{- end }}
{{- if .Values.tls.enabled }}
- --tls
{{- end }}
{{- if .Values.tls.skipVerify }}
- --tls-skip-verify
{{- end }}
{{- if .Values.tls.caFile }}
- --tls-ca-file={{ .Values.tls.caFile }}
{{- end }}
{{- if .Values.tls.serverName }}
- --tls-server-name={{ .Values.tls.serverName }}
{{- end }}
{{- if .Values.tls.certFile }}
- --tls-cert={{ .Values.tls.certFile }}
{{- end }}
{{- if .Values.tls.keyFile }}
- --tls-key={{ .Values.tls.keyFile }}
{{- end }}
{{- end -}}

{{- define "rsr.authEnv" -}}
{{- if .Values.auth.existingSecret }}
- name: RSR_REDIS_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.auth.existingSecret | quote }}
      key: {{ .Values.auth.existingSecretKey | default "redis-password" | quote }}
- name: RSR_SENTINEL_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.auth.existingSecret | quote }}
      key: {{ .Values.auth.existingSecretKey | default "redis-password" | quote }}
{{- else }}
{{- if .Values.auth.redisPassword }}
- name: RSR_REDIS_PASSWORD
  value: {{ .Values.auth.redisPassword | quote }}
{{- end }}
{{- if .Values.auth.sentinelPassword }}
- name: RSR_SENTINEL_PASSWORD
  value: {{ .Values.auth.sentinelPassword | quote }}
{{- end }}
{{- end }}
{{- if .Values.auth.redisUsername }}
- name: RSR_REDIS_USERNAME
  value: {{ .Values.auth.redisUsername | quote }}
{{- end }}
{{- if .Values.auth.sentinelUsername }}
- name: RSR_SENTINEL_USERNAME
  value: {{ .Values.auth.sentinelUsername | quote }}
{{- end }}
{{- if .Values.auth.sentinelRedisUsername }}
- name: RSR_SENTINEL_REDIS_USERNAME
  value: {{ .Values.auth.sentinelRedisUsername | quote }}
{{- end }}
{{- if .Values.auth.sentinelRedisPassword }}
- name: RSR_SENTINEL_REDIS_PASSWORD
  value: {{ .Values.auth.sentinelRedisPassword | quote }}
{{- end }}
{{- end -}}
