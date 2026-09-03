package main

import (
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

	fs := flag.NewFlagSet("reconciler", flag.ContinueOnError)
	if errOut != nil {
		fs.SetOutput(errOut)
	}

	var sentinelAddrs, redisAddrs multiFlag
	masterName := fs.String("master-name", envOr(getenv, "mymaster", "RSR_MASTER_NAME", "MASTER_NAME"), "Sentinel master name")
	interval := fs.Duration("interval", envDuration(getenv, 5*time.Second, "RSR_INTERVAL", "INTERVAL"), "Reconcile interval")
	apply := fs.Bool("apply", envApply(getenv), "Apply heals (default dry-run)")
	once := fs.Bool("once", envBool(getenv, false, "RSR_ONCE"), "Run a single reconcile tick then exit")
	redisPassword := fs.String("redis-password", envOr(getenv, "", "RSR_REDIS_PASSWORD", "REDIS_PASSWORD"), "Redis ACL/password")
	sentinelPassword := fs.String("sentinel-password", envOr(getenv, "", "RSR_SENTINEL_PASSWORD", "SENTINEL_PASSWORD"), "Sentinel ACL/password")
	redisUsername := fs.String("redis-username", envOr(getenv, "", "RSR_REDIS_USERNAME", "REDIS_USERNAME"), "Redis ACL username (default user if empty)")
	sentinelUsername := fs.String("sentinel-username", envOr(getenv, "", "RSR_SENTINEL_USERNAME", "SENTINEL_USERNAME"), "Sentinel ACL username")
	localSentinel := fs.Bool("local-sentinel", envBool(getenv, false, "RSR_LOCAL_SENTINEL", "LOCAL_SENTINEL"), "Only check/heal first --sentinel-addr (required with --apply)")
	quorum := fs.Int("quorum", envInt(getenv, 2, "RSR_QUORUM", "QUORUM"), "Quorum for SENTINEL MONITOR fallback")
	healCooldown := fs.Duration("heal-cooldown", envDuration(getenv, 15*time.Minute, "RSR_HEAL_COOLDOWN", "HEAL_COOLDOWN"), "Min time between heal attempts (0 disables)")
	allowGlobalApply := fs.Bool("allow-global-apply", envBool(getenv, false, "RSR_ALLOW_GLOBAL_APPLY"), "Allow --apply without --local-sentinel (dangerous)")
	minReachable := fs.Int("min-reachable-redis", envInt(getenv, 0, "RSR_MIN_REACHABLE_REDIS"), "Refuse apply if fewer static redis seeds reachable (0=auto)")
	skipFailover := fs.Bool("skip-on-failover-in-progress", envBool(getenv, true, "RSR_SKIP_ON_FAILOVER_IN_PROGRESS"), "Refuse apply while Sentinel failover_in_progress")
	jitter := fs.Float64("interval-jitter", envFloat(getenv, 0.2, "RSR_INTERVAL_JITTER"), "Extra random fraction of --interval")
	metricsAddr := fs.String("metrics-addr", envOr(getenv, "", "RSR_METRICS_ADDR", "METRICS_ADDR"), "If set, serve Prometheus text metrics (e.g. :9090)")
	healLease := fs.Bool("heal-lease", envBool(getenv, true, "RSR_HEAL_LEASE", "HEAL_LEASE"), "Acquire Redis NX heal lease on oracle before apply")
	healLeaseTTL := fs.Duration("heal-lease-ttl", envDuration(getenv, 0, "RSR_HEAL_LEASE_TTL"), "Lease TTL (default: --heal-cooldown or 15m)")
	equalEpochEsc := fs.Bool("equal-epoch-escalate", envBool(getenv, true, "RSR_EQUAL_EPOCH_ESCALATE", "EQUAL_EPOCH_ESCALATE"), "On equal-epoch trap without safe FAILOVER, refuse MONITOR")
	leaseHolder := fs.String("lease-holder", envOr(getenv, "", "RSR_LEASE_HOLDER"), "Stable lease holder id (default hostname)")
	tlsOn := fs.Bool("tls", envBool(getenv, false, "RSR_TLS"), "Use TLS for Redis and Sentinel")
	tlsSkip := fs.Bool("tls-skip-verify", envBool(getenv, false, "RSR_TLS_SKIP_VERIFY", "TLS_SKIP_VERIFY"), "Skip TLS certificate verify (lab / IP-only certs)")
	tlsCA := fs.String("tls-ca-file", envOr(getenv, "", "RSR_TLS_CA_FILE", "TLS_CA_FILE"), "PEM file with trusted CA certificate(s)")
	tlsServer := fs.String("tls-server-name", envOr(getenv, "", "RSR_TLS_SERVER_NAME", "TLS_SERVER_NAME"), "SNI / cert hostname (needed when dialing 127.0.0.1)")
	tlsCert := fs.String("tls-cert", envOr(getenv, "", "RSR_TLS_CERT", "TLS_CERT_FILE"), "Client certificate PEM (mTLS)")
	tlsKey := fs.String("tls-key", envOr(getenv, "", "RSR_TLS_KEY", "TLS_KEY_FILE"), "Client key PEM (mTLS)")

	fs.Var(&sentinelAddrs, "sentinel-addr", "Sentinel host:port (repeatable or comma-separated)")
	fs.Var(&redisAddrs, "redis-addrs", "Static Redis seed host:port (repeatable or comma-separated)")

	if err := fs.Parse(args); err != nil {
		return reconcile.Config{}, err
	}

	if len(sentinelAddrs) == 0 {
		if err := sentinelAddrs.Set(envOr(getenv, "", "RSR_SENTINEL_ADDR", "SENTINEL_ADDR")); err != nil {
			return reconcile.Config{}, err
		}
	}
	if len(redisAddrs) == 0 {
		if err := redisAddrs.Set(envOr(getenv, "", "RSR_REDIS_ADDRS", "REDIS_ADDRS")); err != nil {
			return reconcile.Config{}, err
		}
	}

	if len(sentinelAddrs) == 0 {
		return reconcile.Config{}, fmt.Errorf("at least one --sentinel-addr (or RSR_SENTINEL_ADDR) is required")
	}
	if *apply && !*localSentinel && !*allowGlobalApply {
		return reconcile.Config{}, fmt.Errorf("--apply requires --local-sentinel (or --allow-global-apply)")
	}

	tlsCfg, err := redisconn.BuildTLS(redisconn.TLSSettings{
		Enabled:    *tlsOn,
		SkipVerify: *tlsSkip,
		CAFile:     *tlsCA,
		ServerName: *tlsServer,
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

func envBool(getenv getenvFunc, def bool, keys ...string) bool {
	v := firstEnv(getenv, keys...)
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
	if envBool(getenv, false, "RSR_APPLY", "APPLY") {
		return true
	}
	flag := strings.ToLower(firstEnv(getenv, "APPLY_FLAG"))
	return strings.Contains(flag, "apply")
}

func envDuration(getenv getenvFunc, def time.Duration, keys ...string) time.Duration {
	v := firstEnv(getenv, keys...)
	if v == "" {
		return def
	}
	d, err := time.ParseDuration(v)
	if err != nil {
		return def
	}
	return d
}

func envInt(getenv getenvFunc, def int, keys ...string) int {
	v := firstEnv(getenv, keys...)
	if v == "" {
		return def
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return def
	}
	return n
}

func envFloat(getenv getenvFunc, def float64, keys ...string) float64 {
	v := firstEnv(getenv, keys...)
	if v == "" {
		return def
	}
	f, err := strconv.ParseFloat(v, 64)
	if err != nil {
		return def
	}
	return f
}
