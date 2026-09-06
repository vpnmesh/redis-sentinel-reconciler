package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"strconv"
	"strings"
	"time"

	"github.com/vpnmesh/redis-sentinel-reconciler/internal/reconcile"
	"github.com/vpnmesh/redis-sentinel-reconciler/internal/redisconn"
)

type getenvFunc func(string) string

func parseConfig(args []string, getenv getenvFunc, errOut io.Writer) (reconcile.Config, error) {
	if getenv == nil {
		getenv = func(string) string { return "" }
	}

	configPath, err := peekConfigPath(args, getenv)
	if err != nil {
		return reconcile.Config{}, err
	}
	var file map[string]string
	if configPath != "" {
		file, err = loadEnvFile(configPath)
		if err != nil {
			return reconcile.Config{}, err
		}
	}
	getenv = layerGetenv(getenv, file)

	fs := flag.NewFlagSet("reconciler", flag.ContinueOnError)
	if errOut != nil {
		fs.SetOutput(errOut)
	}
	fs.Usage = func() { writeFlagUsage(fs, errOut) }

	_ = fs.String("config", "", "KEY=VALUE file (also CONFIG / RSR_CONFIG). Process env and flags override.")

	var sentinelAddrs, redisAddrs multiFlag
	masterName := fs.String("master-name", envStr(getenv, "mymaster", "master-name"), "Sentinel master name")
	interval := fs.Duration("interval", envDuration(getenv, 30*time.Second, "interval"), "Reconcile interval")
	apply := fs.Bool("apply", envApply(getenv), "Apply heals (default dry-run)")
	once := fs.Bool("once", envBool(getenv, false, "once"), "Run a single reconcile tick then exit")
	redisPassword := fs.String("redis-password", envStr(getenv, "", "redis-password"), "Redis ACL/password")
	sentinelPassword := fs.String("sentinel-password", envStr(getenv, "", "sentinel-password"), "Sentinel ACL/password")
	redisUsername := fs.String("redis-username", envStr(getenv, "", "redis-username"), "Redis ACL username (empty = default user)")
	sentinelUsername := fs.String("sentinel-username", envStr(getenv, "", "sentinel-username"), "Sentinel ACL username")
	sentinelRedisUsername := fs.String("sentinel-redis-username", envStr(getenv, "", "sentinel-redis-username"), "SENTINEL SET auth-user after MONITOR (default: --redis-username)")
	sentinelRedisPassword := fs.String("sentinel-redis-password", envStr(getenv, "", "sentinel-redis-password"), "SENTINEL SET auth-pass after MONITOR (default: --redis-password)")
	localSentinel := fs.Bool("local-sentinel", envBool(getenv, true, "local-sentinel"), "Only this host's Sentinel (first --sentinel-addr). Default on")
	quorum := fs.Int("quorum", envInt(getenv, 2, "quorum"), "Quorum for SENTINEL MONITOR fallback")
	healCooldown := fs.Duration("heal-cooldown", envDuration(getenv, 15*time.Minute, "heal-cooldown"), "Min time between heal attempts (0 disables)")
	allowGlobalApply := fs.Bool("allow-global-apply", envBool(getenv, false, "allow-global-apply"), "Allow --apply with --local-sentinel=false (dangerous)")
	minReachable := fs.Int("min-reachable-redis", envInt(getenv, 0, "min-reachable-redis"), "Refuse apply if fewer REDIS_ADDRS hosts are reachable (0=auto)")
	skipFailover := fs.Bool("skip-on-failover-in-progress", envBool(getenv, true, "skip-on-failover-in-progress"), "Refuse apply while Sentinel failover_in_progress")
	jitter := fs.Float64("interval-jitter", envFloat(getenv, 0.2, "interval-jitter"), "Extra random fraction of --interval")
	metricsAddr := fs.String("metrics-addr", envStr(getenv, "", "metrics-addr"), "If set, serve Prometheus text metrics (e.g. 127.0.0.1:9123)")
	healLease := fs.Bool("heal-lease", envBool(getenv, true, "heal-lease"), "Redis SET NX lease on the writable master before apply")
	healLeaseTTL := fs.Duration("heal-lease-ttl", envDuration(getenv, 0, "heal-lease-ttl"), "Lease TTL (default: --heal-cooldown or 15m)")
	equalEpochEsc := fs.Bool("equal-epoch-escalate", envBool(getenv, true, "equal-epoch-escalate"), "Under equal-epoch, refuse MONITOR unless FAILOVER was skipped for a stale live-replica ad")
	leaseHolder := fs.String("lease-holder", envStr(getenv, "", "lease-holder"), "Stable lease holder id (default hostname)")
	tlsOn := fs.Bool("tls", envBool(getenv, false, "tls"), "Use TLS for Redis and Sentinel")
	tlsSkip := fs.Bool("tls-skip-verify", envBool(getenv, false, "tls-skip-verify"), "Skip TLS certificate verify (lab / IP-only certs)")
	tlsCA := fs.String("tls-ca-file", envStr(getenv, "", "tls-ca-file"), "PEM file with trusted CA certificate(s)")
	tlsServer := fs.String("tls-server-name", envStr(getenv, "", "tls-server-name"), "SNI only when the dial target is an IP; hostname dials use the name in the address")
	tlsCert := fs.String("tls-cert", envStr(getenv, "", "tls-cert", "TLS_CERT_FILE"), "Client certificate PEM (mTLS)")
	tlsKey := fs.String("tls-key", envStr(getenv, "", "tls-key", "TLS_KEY_FILE"), "Client key PEM (mTLS)")
	fromPrefix := fs.String("sentinel-from-ordinal-prefix", envStr(getenv, "", "sentinel-from-ordinal-prefix"), "With POD_NAME: SENTINEL_ADDR = prefix + ordinal + suffix (scratch STS, no shell)")
	fromSuffix := fs.String("sentinel-from-ordinal-suffix", envStr(getenv, "", "sentinel-from-ordinal-suffix"), "See --sentinel-from-ordinal-prefix")

	fs.Var(&sentinelAddrs, "sentinel-addr", "required: this host's Sentinel, host:26379 (repeat or comma-separate). Env: SENTINEL_ADDR / RSR_SENTINEL_ADDR. TLS: DNS name on the cert, not 127.0.0.1")
	fs.Var(&redisAddrs, "redis-addrs", "required: every Redis/Valkey data node that can become master, port 6379; the whole cluster, not only this host (repeat or comma-separate). Env: REDIS_ADDRS / RSR_REDIS_ADDRS")

	if err := fs.Parse(args); err != nil {
		return reconcile.Config{}, err
	}

	if len(sentinelAddrs) == 0 {
		if err := sentinelAddrs.Set(envStr(getenv, "", "sentinel-addr")); err != nil {
			return reconcile.Config{}, err
		}
	}
	if len(sentinelAddrs) == 0 {
		if derived := sentinelAddrFromOrdinal(getenv("POD_NAME"), *fromPrefix, *fromSuffix); derived != "" {
			if err := sentinelAddrs.Set(derived); err != nil {
				return reconcile.Config{}, err
			}
		}
	}
	if len(redisAddrs) == 0 {
		if err := redisAddrs.Set(envStr(getenv, "", "redis-addrs")); err != nil {
			return reconcile.Config{}, err
		}
	}

	if len(sentinelAddrs) == 0 || len(redisAddrs) == 0 {
		return reconcile.Config{}, requiredAddrErr(configPath, len(sentinelAddrs) == 0, len(redisAddrs) == 0)
	}
	if *apply && !*localSentinel && !*allowGlobalApply {
		return reconcile.Config{}, fmt.Errorf("--apply with --local-sentinel=false would heal every listed Sentinel from this process; pass --allow-global-apply if you really mean that")
	}

	tlsCfg, err := redisconn.BuildTLS(redisconn.TLSSettings{
		Enabled:    *tlsOn,
		SkipVerify: *tlsSkip,
		CAFile:     *tlsCA,
		CertFile:   *tlsCert,
		KeyFile:    *tlsKey,
	})
	if err != nil {
		return reconcile.Config{}, err
	}

	return reconcile.Config{
		SentinelAddrs:            sentinelAddrs,
		MasterName:               *masterName,
		Interval:                 *interval,
		Apply:                    *apply,
		Once:                     *once,
		RedisPassword:            *redisPassword,
		SentinelPassword:         *sentinelPassword,
		RedisUsername:            *redisUsername,
		SentinelUsername:         *sentinelUsername,
		SentinelRedisUsername:    *sentinelRedisUsername,
		SentinelRedisPassword:    *sentinelRedisPassword,
		RedisAddrs:               redisAddrs,
		LocalSentinel:            *localSentinel,
		Quorum:                   *quorum,
		HealCooldown:             *healCooldown,
		AllowGlobalApply:         *allowGlobalApply,
		RequireLocalForApply:     !*allowGlobalApply,
		MinReachableRedis:        *minReachable,
		SkipOnFailoverInProgress: *skipFailover,
		IntervalJitter:           *jitter,
		MetricsAddr:              *metricsAddr,
		HealLease:                *healLease,
		HealLeaseTTL:             *healLeaseTTL,
		EqualEpochEscalate:       *equalEpochEsc,
		LeaseHolder:              *leaseHolder,
		TLS:                      tlsCfg,
		TLSCAFile:                *tlsCA,
		TLSServerName:            *tlsServer,
	}, nil
}

func writeFlagUsage(fs *flag.FlagSet, w io.Writer) {
	if w == nil {
		return
	}
	fmt.Fprintf(w, `Usage: reconciler [flags]

Sidecar next to one Sentinel. Flag, env, and --config KEY=VALUE are the
same knobs: --sentinel-addr = SENTINEL_ADDR = RSR_SENTINEL_ADDR.

Required:
  SENTINEL_ADDR   this host's Sentinel (host:26379)
  REDIS_ADDRS     every data node that can become master (port 6379)

Then auth/TLS if the cluster uses them. Leave APPLY=false until you have
watched ticks. Defaults: local Sentinel only, 30s interval, 15m cooldown,
heal lease on.

`)
	fs.PrintDefaults()
}

func requiredAddrErr(configPath string, missingSentinel, missingRedis bool) error {
	where := "flags, environment, or a --config KEY=VALUE file"
	if configPath != "" {
		where = configPath + ", environment, or flags"
	}
	var b strings.Builder
	b.WriteString("missing required settings (set them in " + where + "):\n")
	if missingSentinel {
		b.WriteString(`
  SENTINEL_ADDR  (--sentinel-addr / SENTINEL_ADDR / RSR_SENTINEL_ADDR)
      The Sentinel on this host, as host:26379.
      On TLS, use the DNS name from the certificate, not 127.0.0.1.
      Example: SENTINEL_ADDR=db-n1.example.com:26379
`)
	}
	if missingRedis {
		b.WriteString(`
  REDIS_ADDRS  (--redis-addrs / REDIS_ADDRS / RSR_REDIS_ADDRS)
      Every Redis/Valkey data node that can become master, port 6379.
      List the whole cluster, not only this host.
      Example: REDIS_ADDRS=db-n1.example.com:6379,db-n2.example.com:6379,db-n3.example.com:6379
`)
	}
	b.WriteString("\nSee also: reconciler -h\n")
	return errors.New(strings.TrimSuffix(b.String(), "\n"))
}

func sentinelAddrFromOrdinal(podName, prefix, suffix string) string {
	if prefix == "" || podName == "" {
		return ""
	}
	i := strings.LastIndex(podName, "-")
	if i < 0 || i+1 >= len(podName) {
		return ""
	}
	ord := podName[i+1:]
	for _, r := range ord {
		if r < '0' || r > '9' {
			return ""
		}
	}
	return prefix + ord + suffix
}

// envNames maps --foo-bar to FOO_BAR and RSR_FOO_BAR.
func envNames(flagName string, extra ...string) []string {
	bare := strings.ToUpper(strings.ReplaceAll(flagName, "-", "_"))
	out := []string{bare, "RSR_" + bare}
	out = append(out, extra...)
	return out
}

func envStr(getenv getenvFunc, def, flagName string, extra ...string) string {
	return envOr(getenv, def, envNames(flagName, extra...)...)
}

func envOr(getenv getenvFunc, def string, keys ...string) string {
	if v := firstEnv(getenv, keys...); v != "" {
		return v
	}
	return def
}

func firstEnv(getenv getenvFunc, keys ...string) string {
	for _, k := range keys {
		if v := strings.TrimSpace(getenv(k)); v != "" {
			return v
		}
	}
	return ""
}

func envBool(getenv getenvFunc, def bool, flagName string, extra ...string) bool {
	v := firstEnv(getenv, envNames(flagName, extra...)...)
	if v == "" {
		return def
	}
	switch strings.ToLower(v) {
	case "1", "true", "yes", "on":
		return true
	case "0", "false", "no", "off":
		return false
	default:
		return def
	}
}

func envApply(getenv getenvFunc) bool {
	if envBool(getenv, false, "apply") {
		return true
	}
	flag := strings.ToLower(firstEnv(getenv, "APPLY_FLAG"))
	return strings.Contains(flag, "apply")
}

func envDuration(getenv getenvFunc, def time.Duration, flagName string) time.Duration {
	v := firstEnv(getenv, envNames(flagName)...)
	if v == "" {
		return def
	}
	d, err := time.ParseDuration(v)
	if err != nil {
		return def
	}
	return d
}

func envInt(getenv getenvFunc, def int, flagName string) int {
	v := firstEnv(getenv, envNames(flagName)...)
	if v == "" {
		return def
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return def
	}
	return n
}

func envFloat(getenv getenvFunc, def float64, flagName string) float64 {
	v := firstEnv(getenv, envNames(flagName)...)
	if v == "" {
		return def
	}
	f, err := strconv.ParseFloat(v, 64)
	if err != nil {
		return def
	}
	return f
}
