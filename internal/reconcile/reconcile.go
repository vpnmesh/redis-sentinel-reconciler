package reconcile

import (
	"context"
	"crypto/tls"
	"fmt"
	"log/slog"
	"math/rand"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/vpnmesh/redis-sentinel-reconciler/internal/oracle"
	"github.com/vpnmesh/redis-sentinel-reconciler/internal/redisconn"
	"github.com/vpnmesh/redis-sentinel-reconciler/internal/sentinel"
)

// Config holds reconciler runtime options.
type Config struct {
	SentinelAddrs    []string
	MasterName       string
	Interval         time.Duration
	Apply            bool
	Once             bool
	RedisPassword    string
	SentinelPassword string
	RedisAddrs       []string
	LocalSentinel    bool
	Quorum           int

	// Safety (HAZARD countermeasures).
	RequireLocalForApply     bool
	AllowGlobalApply         bool
	HealCooldown             time.Duration
	MinReachableRedis        int
	SkipOnFailoverInProgress bool
	IntervalJitter           float64 // 0-1 fraction of Interval (default 0.2)
	MetricsAddr              string  // e.g. "127.0.0.1:9123"; empty disables

	// R9/R10 product readiness.
	HealLease          bool          // acquire Redis NX lease before apply heal
	HealLeaseTTL       time.Duration // default = HealCooldown or 15m
	EqualEpochEscalate bool          // if equal-epoch trap and FAILOVER unsafe -> refuse MONITOR
	LeaseHolder        string        // optional stable id (default hostname)

	RedisUsername    string
	SentinelUsername string
	TLS              *tls.Config
	TLSCAFile        string
	TLSServerName    string
}

// Reconciler runs the periodic control loop.
type Reconciler struct {
	cfg      Config
	log      *slog.Logger
	lastHeal time.Time
	metrics  *Metrics
}

// New returns a configured Reconciler.
func New(cfg Config, log *slog.Logger) *Reconciler {
	if log == nil {
		log = slog.Default()
	}
	if cfg.Quorum <= 0 {
		cfg.Quorum = 2
	}
	if cfg.IntervalJitter < 0 {
		cfg.IntervalJitter = 0
	}
	// H10: apply without local sidecar is refused unless explicitly allowed.
	if !cfg.AllowGlobalApply {
		cfg.RequireLocalForApply = true
	}
	return &Reconciler{cfg: cfg, log: log, metrics: newMetrics(cfg.MasterName, cfg.Apply)}
}

// Run executes ticks until ctx is cancelled (or once if cfg.Once).
func (r *Reconciler) Run(ctx context.Context) error {
	r.log.Info("reconciler started",
		"master_name", r.cfg.MasterName,
		"interval", r.cfg.Interval,
		"apply", r.cfg.Apply,
		"once", r.cfg.Once,
		"local_sentinel", r.cfg.LocalSentinel,
		"heal_cooldown", r.cfg.HealCooldown,
		"sentinels", r.cfg.SentinelAddrs,
		"tls", r.cfg.TLS != nil,
		"tls_skip_verify", r.cfg.TLS != nil && r.cfg.TLS.InsecureSkipVerify,
		"tls_ca_file", r.cfg.TLSCAFile,
		"tls_server_name", r.cfg.TLSServerName,
	)

	if r.cfg.MetricsAddr != "" {
		mux := http.NewServeMux()
		mux.Handle("/metrics", r.metrics.Handler())
		srv := &http.Server{Addr: r.cfg.MetricsAddr, Handler: mux}
		go func() {
			r.log.Info("metrics listening", "addr", r.cfg.MetricsAddr)
			if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
				r.log.Warn("metrics server", "err", err)
			}
		}()
		defer func() { _ = srv.Shutdown(context.Background()) }()
	}

	if err := r.tick(ctx); err != nil {
		r.log.Warn("tick error", "err", err)
	}
	if r.cfg.Once {
		r.log.Info("reconciler once complete")
		return nil
	}

	for {
		wait := r.nextInterval()
		timer := time.NewTimer(wait)
		select {
		case <-ctx.Done():
			timer.Stop()
			r.log.Info("reconciler stopped")
			return ctx.Err()
		case <-timer.C:
			if err := r.tick(ctx); err != nil {
				r.log.Warn("tick error", "err", err)
			}
		}
	}
}

func (r *Reconciler) nextInterval() time.Duration {
	base := r.cfg.Interval
	if base <= 0 {
		base = 5 * time.Second
	}
	j := r.cfg.IntervalJitter
	if j <= 0 {
		return base
	}
	// Uniform jitter in [0, j*base].
	delta := time.Duration(float64(base) * j * rand.Float64())
	return base + delta
}

func (r *Reconciler) tick(ctx context.Context) error {
	r.metrics.Inc("ticks")
	r.metrics.ResetTickGauges()
	clients := make([]*sentinel.Client, 0, len(r.cfg.SentinelAddrs))
	defer func() {
		for _, c := range clients {
			_ = c.Close()
		}
	}()

	for _, addr := range r.cfg.SentinelAddrs {
		clients = append(clients, sentinel.New(r.sentinelDial(addr)))
	}
	if len(clients) == 0 {
		return fmt.Errorf("no sentinel addresses configured")
	}

	type sentinelView struct {
		addr string
		host string
		port int
		err  error
	}
	views := make([]sentinelView, len(clients))
	for i, c := range clients {
		host, port, err := c.GetMasterAddrByName(ctx, r.cfg.MasterName)
		views[i] = sentinelView{addr: c.Addr(), host: host, port: port, err: err}
		if err != nil {
			r.log.Warn("sentinel get-master-addr failed", "sentinel", c.Addr(), "err", err)
		}
	}

	redisAddrs := make(map[string]struct{})
	for _, a := range r.cfg.RedisAddrs {
		redisAddrs[a] = struct{}{}
	}
	for _, v := range views {
		if v.err != nil || v.host == "" {
			continue
		}
		redisAddrs[net.JoinHostPort(v.host, strconv.Itoa(v.port))] = struct{}{}
	}
	for _, c := range clients {
		if master, err := c.Master(ctx, r.cfg.MasterName); err != nil {
			r.log.Debug("sentinel master info failed", "sentinel", c.Addr(), "err", err)
		} else if addr := sentinel.RedisAddrFromInfo(master); addr != "" {
			redisAddrs[addr] = struct{}{}
		}
		if replicas, err := c.Replicas(ctx, r.cfg.MasterName); err != nil {
			r.log.Debug("sentinel replicas failed", "sentinel", c.Addr(), "err", err)
		} else {
			for _, rep := range replicas {
				if addr := sentinel.RedisAddrFromInfo(rep); addr != "" {
					redisAddrs[addr] = struct{}{}
				}
			}
		}
	}

	if len(redisAddrs) == 0 {
		r.log.Error("ALERT", "reason", "no_redis_nodes_discovered")
		r.metrics.Inc("alert_no_redis")
		return nil
	}

	// Oracle = data-plane. When static seeds are configured, classify writable
	// only from seeds (Sentinel ads may be blackholes / lies - H8).
	seedSet := make(map[string]struct{}, len(r.cfg.RedisAddrs))
	for _, a := range r.cfg.RedisAddrs {
		seedSet[a] = struct{}{}
	}
	hasSeeds := len(seedSet) > 0

	nodes := make([]oracle.NodeResult, 0, len(redisAddrs))
	oracleNodes := make([]oracle.NodeResult, 0, len(redisAddrs))
	for addr := range redisAddrs {
		isSeed := false
		if hasSeeds {
			for seed := range seedSet {
				if sameRedisEndpoint(addr, seed) || strings.EqualFold(addr, seed) {
					isSeed = true
					break
				}
			}
		}
		var n oracle.NodeResult
		if hasSeeds && !isSeed {
			// Untrusted Sentinel-discovered addr (often fake) - short dial.
			d := r.redisDial()
			d.Timeout = 400 * time.Millisecond
			n = oracle.ProbeDial(ctx, addr, d)
		} else {
			n = oracle.ProbeDial(ctx, addr, r.redisDial())
		}
		if n.Err != nil {
			r.log.Warn("redis probe failed", "addr", addr, "err", n.Err, "seed", isSeed || !hasSeeds)
		} else {
			r.log.Debug("redis probe", "addr", addr, "role", n.Role, "writable", n.Writable, "seed", isSeed || !hasSeeds)
		}
		nodes = append(nodes, n)
		if !hasSeeds || isSeed {
			oracleNodes = append(oracleNodes, n)
		}
	}
	if len(oracleNodes) == 0 {
		oracleNodes = nodes
	}

	writable, count := oracle.ClassifyWritable(oracleNodes)
	r.metrics.SetWritableMasters(count)
	switch {
	case count == 0:
		for _, n := range oracleNodes {
			r.log.Warn("oracle candidate",
				"addr", n.Addr, "role", n.Role, "writable", n.Writable, "err", fmt.Sprint(n.Err))
		}
		r.log.Error("ALERT", "reason", "no_writable_master", "probed", len(oracleNodes), "discovered", len(nodes))
		r.metrics.Inc("alert_no_writable")
		return nil
	case count >= 2:
		r.log.Error("ALERT", "reason", "dual_master", "writable_count", count)
		r.metrics.Inc("alert_dual_master")
		return nil
	}

	masterKey := writable.Addr
	r.log.Info("oracle writable master", "master", masterKey)

	localIdx := 0
	if !r.cfg.LocalSentinel && len(clients) > 1 {
		localIdx = -1
	}

	// R9: equal-epoch trap detect (observe even in dry-run).
	var epochRep EqualEpochReport
	if len(clients) > 0 {
		epochRep = detectEqualEpochTrap(ctx, clients, r.sentinelDial(""), r.cfg.MasterName)
		r.log.Info("equal_epoch_sample",
			"trap", epochRep.Trap,
			"sample_size", epochRep.SampleSize,
			"ads", epochRep.Ads,
			"epochs", epochRep.Epochs,
		)
		if epochRep.Trap {
			r.log.Error("ALERT", "reason", "equal_epoch_trap",
				"sample_size", epochRep.SampleSize,
				"ads", epochRep.Ads,
				"epochs", epochRep.Epochs,
			)
			r.metrics.Inc("alert_equal_epoch_trap")
		}
	}

	checkDiverge := func(idx int) {
		if idx < 0 || idx >= len(views) {
			return
		}
		v := views[idx]
		if v.err != nil {
			r.log.Warn("DIVERGE check skipped", "sentinel", v.addr, "reason", "get-master-addr failed")
			return
		}
		advertised := fmt.Sprintf("%s:%d", v.host, v.port)
		if sameRedisEndpoint(advertised, masterKey) {
			r.log.Info("noop", "sentinel", v.addr, "advertised", advertised, "oracle", masterKey)
			r.metrics.Inc("noop")
			return
		}

		r.log.Warn("DIVERGE",
			"sentinel", v.addr,
			"advertised", advertised,
			"oracle", masterKey,
			"equal_epoch_trap", epochRep.Trap,
		)
		r.metrics.Inc("diverge")
		r.metrics.NoteDiverged()

		if !r.cfg.Apply {
			r.log.Info("dry-run would_heal", "actions", "SENTINEL FAILOVER|REMOVE+MONITOR", "sentinel", v.addr, "master_name", r.cfg.MasterName)
			r.metrics.Inc("would_heal")
			r.metrics.NoteWouldHeal()
			return
		}

		info, _ := clients[idx].Master(ctx, r.cfg.MasterName)
		flags := ""
		if info != nil {
			flags = info["flags"]
		}
		if !r.preflightApply(flags, nodes) {
			return
		}

		// R10: distributed heal lease on oracle.
		if r.cfg.HealLease {
			ttl := r.cfg.HealLeaseTTL
			if ttl <= 0 {
				ttl = r.cfg.HealCooldown
			}
			ok, err := acquireHealLease(ctx, masterKey, r.cfg.MasterName, r.cfg.LeaseHolder, ttl, r.redisDial())
			if err != nil {
				r.refuseApply("heal_lease_error", "err", err.Error(), "oracle", masterKey)
				return
			}
			if !ok {
				r.refuseApply("heal_lease_held", "oracle", masterKey)
				return
			}
			r.log.Info("heal lease acquired", "oracle", masterKey, "ttl", ttl.String())
			r.metrics.Inc("heal_lease_acquired")
		}

		r.healAPI(ctx, clients[idx], advertised, masterKey, nodes, flags, epochRep.Trap)
	}

	if localIdx >= 0 {
		checkDiverge(localIdx)
	} else {
		for i := range views {
			checkDiverge(i)
		}
	}

	return nil
}

// healAPI: API-only (no conf rewrite / no process restart).
func (r *Reconciler) healAPI(ctx context.Context, c *sentinel.Client, advertised, masterKey string, nodes []oracle.NodeResult, flags string, equalEpochTrap bool) {
	r.lastHeal = time.Now() // count attempts toward cooldown (H5)
	r.metrics.Inc("heal_attempt")

	oracleIP, oraclePort, err := endpointIPPort(masterKey)
	if err != nil {
		r.log.Error("heal aborted", "reason", "oracle_addr_unresolvable", "oracle", masterKey, "err", err)
		r.metrics.Inc("heal_fail")
		return
	}

	safe, why := failoverPromoteSafe(advertised, masterKey, flags, nodes)
	r.log.Info("apply heal plan",
		"sentinel", c.Addr(),
		"failover_safe", safe,
		"reason", why,
		"advertised", advertised,
		"oracle", masterKey,
		"flags", flags,
		"equal_epoch_trap", equalEpochTrap,
	)

	if safe {
		r.log.Info("apply heal starting", "action", "SENTINEL FAILOVER", "sentinel", c.Addr())
		if err := c.Failover(ctx, r.cfg.MasterName); err != nil {
			r.log.Warn("FAILOVER failed, trying REMOVE+MONITOR", "err", err)
		} else {
			time.Sleep(2 * time.Second)
			if r.verifyHeal(ctx, c, masterKey) {
				r.log.Info("heal succeeded", "action", "SENTINEL FAILOVER", "sentinel", c.Addr(), "master", masterKey)
				r.metrics.Inc("heal_ok")
				return
			}
			r.log.Warn("FAILOVER verify mismatch, trying REMOVE+MONITOR")
		}
	} else {
		r.log.Info("skip FAILOVER (promote guard)", "reason", why)
		// R9: equal-epoch without safe FAILOVER -> escalate (do not MONITOR-thrash).
		if equalEpochTrap && r.cfg.EqualEpochEscalate {
			r.log.Error("ALERT", "reason", "equal_epoch_escalate",
				"hint", "FAILOVER unsafe; MONITOR will not bump epoch - conf+restart Owner GO or wait stock",
				"failover_skip_reason", why,
			)
			r.metrics.Inc("alert_equal_epoch_escalate")
			r.refuseApply("equal_epoch_escalate", "failover_skip_reason", why)
			return
		}
	}

	r.log.Info("apply heal starting", "action", "SENTINEL REMOVE+MONITOR", "sentinel", c.Addr(), "ip", oracleIP, "port", oraclePort)
	_ = c.Remove(ctx, r.cfg.MasterName)
	if err := c.Monitor(ctx, r.cfg.MasterName, oracleIP, oraclePort, r.cfg.Quorum); err != nil {
		r.log.Error("heal failed", "action", "MONITOR", "err", err, "conf_fallback_needed", true)
		r.metrics.Inc("heal_fail")
		return
	}
	// H7: re-bind auth after MONITOR (Sentinel drops auth-* on REMOVE).
	for _, kv := range sentinelAuthAfterMonitor(r.cfg.RedisUsername, r.cfg.RedisPassword) {
		if err := c.Set(ctx, r.cfg.MasterName, kv[0], kv[1]); err != nil {
			r.log.Warn("SENTINEL SET failed", "option", kv[0], "err", err)
		} else {
			r.log.Info("re-bound sentinel " + kv[0] + " after MONITOR")
		}
	}
	time.Sleep(1 * time.Second)
	if r.verifyHeal(ctx, c, masterKey) {
		r.log.Info("heal succeeded", "action", "SENTINEL REMOVE+MONITOR", "sentinel", c.Addr(), "master", masterKey)
		r.metrics.Inc("heal_ok")
		return
	}

	r.log.Info("apply heal starting", "action", "SENTINEL RESET", "sentinel", c.Addr())
	_ = c.Reset(ctx, r.cfg.MasterName)
	time.Sleep(2 * time.Second)
	if r.verifyHeal(ctx, c, masterKey) {
		r.log.Info("heal succeeded", "action", "SENTINEL RESET", "sentinel", c.Addr(), "master", masterKey)
		r.metrics.Inc("heal_ok")
		return
	}

	r.log.Error("heal failed", "sentinel", c.Addr(), "oracle", masterKey, "conf_fallback_needed", true)
	r.metrics.Inc("heal_fail")
}

func (r *Reconciler) verifyHeal(ctx context.Context, c *sentinel.Client, masterKey string) bool {
	if !r.verifyAdvertised(ctx, c, masterKey) {
		return false
	}
	// H8: advertised OK is not enough - oracle must still accept writes.
	if err := reprobeOracleWritable(ctx, masterKey, r.redisDial()); err != nil {
		r.log.Warn("heal verify write-probe failed", "err", err)
		return false
	}
	return true
}

func (r *Reconciler) verifyAdvertised(ctx context.Context, c *sentinel.Client, masterKey string) bool {
	host, port, err := c.GetMasterAddrByName(ctx, r.cfg.MasterName)
	if err != nil {
		r.log.Warn("heal verify get-master-addr failed", "err", err)
		return false
	}
	after := fmt.Sprintf("%s:%d", host, port)
	ok := sameRedisEndpoint(after, masterKey)
	if !ok {
		r.log.Warn("heal verify mismatch", "got", after, "expected", masterKey)
	}
	return ok
}

// sentinelAuthAfterMonitor is SENTINEL SET auth-user / auth-pass after REMOVE+MONITOR.
// ACL clusters need both; password-only clusters still get auth-pass.
func sentinelAuthAfterMonitor(username, password string) [][2]string {
	var out [][2]string
	if username != "" {
		out = append(out, [2]string{"auth-user", username})
	}
	if password != "" {
		out = append(out, [2]string{"auth-pass", password})
	}
	return out
}

// failoverPromoteSafe: only FAILOVER when it is likely to land on oracle M (H4).
func failoverPromoteSafe(advertised, masterKey, flags string, nodes []oracle.NodeResult) (bool, string) {
	advDown := strings.Contains(flags, "s_down") || strings.Contains(flags, "o_down") || strings.Contains(flags, "disconnected")
	advReachableMaster := false
	advertisedLiveNonOracle := false
	oracleIsReplicaOrMaster := false
	for i := range nodes {
		n := &nodes[i]
		if n.Err != nil {
			continue
		}
		if sameRedisEndpoint(n.Addr, masterKey) && (n.Role == "master" || n.Role == "slave") {
			oracleIsReplicaOrMaster = true
		}
		if !sameRedisEndpoint(n.Addr, advertised) {
			continue
		}
		if n.Role == "master" && n.Writable {
			advReachableMaster = true
		}
		if n.Role == "slave" && !sameRedisEndpoint(advertised, masterKey) {
			advertisedLiveNonOracle = true
		}
	}
	if !oracleIsReplicaOrMaster {
		return false, "oracle_not_in_topology"
	}
	if advertisedLiveNonOracle {
		return false, "advertised_is_live_non_oracle"
	}
	if advReachableMaster && !sameRedisEndpoint(advertised, masterKey) {
		return false, "advertised_is_live_writable_not_oracle"
	}
	if advDown || !advReachableMaster {
		return true, "advertised_down_or_unreachable_failover_ok"
	}
	return false, "failover_may_promote_non_oracle"
}

func endpointIPPort(addr string) (ip string, port int, err error) {
	host, portStr, err := net.SplitHostPort(addr)
	if err != nil {
		return "", 0, err
	}
	port, err = strconv.Atoi(portStr)
	if err != nil {
		return "", 0, err
	}
	if parsed := net.ParseIP(host); parsed != nil {
		return host, port, nil
	}
	ips, err := net.LookupIP(host)
	if err != nil || len(ips) == 0 {
		return "", 0, fmt.Errorf("lookup %s: %w", host, err)
	}
	for _, cand := range ips {
		if v := cand.To4(); v != nil {
			return v.String(), port, nil
		}
	}
	return ips[0].String(), port, nil
}

func sameRedisEndpoint(a, b string) bool {
	if strings.EqualFold(a, b) {
		return true
	}
	return resolveKey(a) != "" && resolveKey(a) == resolveKey(b)
}

func resolveKey(addr string) string {
	host, port, err := net.SplitHostPort(addr)
	if err != nil {
		return strings.ToLower(addr)
	}
	ips, err := net.LookupIP(host)
	if err != nil || len(ips) == 0 {
		return strings.ToLower(addr)
	}
	var ip4 net.IP
	for _, ip := range ips {
		if v := ip.To4(); v != nil {
			ip4 = v
			break
		}
	}
	if ip4 == nil {
		ip4 = ips[0]
	}
	return net.JoinHostPort(ip4.String(), port)
}

func (r *Reconciler) redisDial() redisconn.Dial {
	return redisconn.Dial{
		Username:      r.cfg.RedisUsername,
		Password:      r.cfg.RedisPassword,
		TLS:           r.cfg.TLS,
		TLSServerName: r.cfg.TLSServerName,
	}
}

func (r *Reconciler) sentinelDial(addr string) sentinel.Dial {
	return sentinel.Dial{
		Addr:          addr,
		Username:      r.cfg.SentinelUsername,
		Password:      r.cfg.SentinelPassword,
		TLS:           r.cfg.TLS,
		TLSServerName: r.cfg.TLSServerName,
	}
}
