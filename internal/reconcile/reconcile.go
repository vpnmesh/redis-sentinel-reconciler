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

	RequireLocalForApply     bool
	AllowGlobalApply         bool
	HealCooldown             time.Duration
	MinReachableRedis        int
	SkipOnFailoverInProgress bool
	IntervalJitter           float64 // 0-1 fraction of Interval (default 0.2)
	MetricsAddr              string  // e.g. "127.0.0.1:9123"; empty disables

	HealLease          bool          // Redis SET NX lease before apply
	HealLeaseTTL       time.Duration // default = HealCooldown or 15m
	EqualEpochEscalate bool          // refuse MONITOR under equal-epoch unless ads are a live replica
	LeaseHolder        string        // optional stable id (default hostname)

	RedisUsername    string
	SentinelUsername string
	// SentinelRedisUsername / SentinelRedisPassword are SENTINEL SET auth-user /
	// auth-pass after MONITOR (Sentinel to Redis). Empty = probe Redis user/password.
	SentinelRedisUsername string
	SentinelRedisPassword string
	TLS                   *tls.Config
	TLSCAFile             string
	TLSServerName         string
}

// Reconciler runs the periodic control loop.
type Reconciler struct {
	cfg      Config
	log      *slog.Logger
	lastHeal time.Time
	metrics  *Metrics
	// writeProbe, if set, replaces the post-heal Redis write check (tests).
	writeProbe func(ctx context.Context, masterKey string) error
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

	// Writable classification uses REDIS_ADDRS only. Sentinel ads can be stale
	// or point at an unreachable IP.
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
	// MONITOR host comes from --redis-addrs, not from whichever probe address
	// map iteration classified first and not from LookupIP.
	monitorAddr := preferredSeedAddr(writable, nodes, r.cfg.RedisAddrs)
	if monitorAddr == "" {
		monitorAddr = masterKey
	}
	r.log.Info("oracle writable master", "master", masterKey, "monitor", monitorAddr)

	localIdx := 0
	if !r.cfg.LocalSentinel && len(clients) > 1 {
		localIdx = -1
	}

	// Equal-epoch trap (observe even in dry-run).
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
		advertised := masterAddr(v.host, v.port)
		kind := classifyDiverge(advertised, masterKey, monitorAddr, writable, nodes)
		if kind == divergeNoop {
			r.log.Info("noop", "sentinel", v.addr, "advertised", advertised, "oracle", masterKey, "monitor", monitorAddr)
			r.metrics.Inc("noop")
			return
		}
		reason := "master"
		actions := "SENTINEL FAILOVER|REMOVE+MONITOR"
		if kind == divergeForm {
			reason = reasonAddressForm
			actions = "SENTINEL REMOVE+MONITOR"
		}

		r.log.Warn("DIVERGE",
			"sentinel", v.addr,
			"advertised", advertised,
			"oracle", masterKey,
			"monitor", monitorAddr,
			"reason", reason,
			"equal_epoch_trap", epochRep.Trap,
		)
		r.metrics.Inc("diverge")
		r.metrics.NoteDiverged()

		if !r.cfg.Apply {
			r.log.Info("dry-run would_heal", "actions", actions, "reason", reason, "sentinel", v.addr, "master_name", r.cfg.MasterName, "monitor", monitorAddr)
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

		// Distributed heal lease on the writable Redis.
		if r.cfg.HealLease {
			ttl := r.cfg.HealLeaseTTL
			if ttl <= 0 {
				ttl = r.cfg.HealCooldown
			}
			// Dial the seed address, not whichever probe the map yielded first.
			// The pod IP fails TLS when the cert has only the DNS SAN.
			leaseAddr := healDialAddr(monitorAddr, masterKey)
			ok, err := acquireHealLease(ctx, leaseAddr, r.cfg.MasterName, r.cfg.LeaseHolder, ttl, r.redisDial())
			if err != nil {
				r.refuseApply("heal_lease_error", "err", err.Error(), "oracle", masterKey, "monitor", leaseAddr)
				return
			}
			if !ok {
				r.refuseApply("heal_lease_held", "oracle", masterKey, "monitor", leaseAddr)
				return
			}
			r.log.Info("heal lease acquired", "oracle", masterKey, "monitor", leaseAddr, "ttl", ttl.String())
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
func (r *Reconciler) healAPI(ctx context.Context, c sentinelHealClient, advertised, masterKey string, nodes []oracle.NodeResult, flags string, equalEpochTrap bool) {
	_, writableCount := oracle.ClassifyWritable(nodes)
	src := nodeByAddr(nodes, masterKey)
	if src == nil {
		src = &oracle.NodeResult{Addr: masterKey, Role: "master", Writable: true}
	}
	monitorAddr := preferredSeedAddr(src, nodes, r.cfg.RedisAddrs)
	if monitorAddr == "" {
		monitorAddr = masterKey
	}

	// Dual-master before any MONITOR, including an address-form rewrite.
	// IP and FQDN of one run_id are one master; two run_ids are not.
	if writableCount >= 2 {
		r.log.Info("apply heal plan",
			"sentinel", c.Addr(),
			"action", string(actionRefuse),
			"reason", reasonDualMaster,
			"advertised", advertised,
			"oracle", masterKey,
			"monitor", monitorAddr,
			"writable_count", writableCount,
		)
		r.refuseApply(reasonDualMaster)
		return
	}
	if writableCount <= 0 {
		r.refuseApply(reasonNoWritable)
		return
	}

	// Same node, seed is a hostname, Sentinel has the pod IP: rewrite the
	// string only. FAILOVER would demote the writable we already have.
	if addressFormMismatch(advertised, monitorAddr, src, nodes) {
		r.healAddressForm(ctx, c, advertised, masterKey, monitorAddr)
		return
	}

	safe, why := failoverPromoteSafe(advertised, masterKey, flags, nodes)
	plan := planApplyHeal(writableCount, safe, why, equalEpochTrap, r.cfg.EqualEpochEscalate)
	r.log.Info("apply heal plan",
		"sentinel", c.Addr(),
		"action", string(plan.Action),
		"failover_safe", safe,
		"reason", plan.Reason,
		"failover_skip_reason", why,
		"advertised", advertised,
		"oracle", masterKey,
		"monitor", monitorAddr,
		"flags", flags,
		"equal_epoch_trap", equalEpochTrap,
		"writable_count", writableCount,
	)

	if plan.Action == actionRefuse {
		if plan.Reason == reasonEqualEpochEscalate {
			r.log.Error("ALERT", "reason", "equal_epoch_escalate",
				"hint", "FAILOVER unsafe for a reason that is not a stale live-replica ad; MONITOR refused",
				"failover_skip_reason", why,
			)
			r.metrics.Inc("alert_equal_epoch_escalate")
		}
		r.refuseApply(plan.Reason, "failover_skip_reason", why)
		return
	}

	if _, _, err := monitorHostPort(monitorAddr); err != nil {
		r.log.Error("heal aborted", "reason", "oracle_addr_unparseable", "oracle", monitorAddr, "err", err)
		r.metrics.Inc("heal_fail")
		return
	}

	r.lastHeal = time.Now() // count attempts toward cooldown
	r.metrics.Inc("heal_attempt")

	if plan.Action == actionFailover {
		r.log.Info("apply heal starting", "action", "SENTINEL FAILOVER", "sentinel", c.Addr())
		if err := c.Failover(ctx, r.cfg.MasterName); err != nil {
			r.log.Warn("FAILOVER failed, trying REMOVE+MONITOR", "err", err)
		} else {
			r.pause(2 * time.Second)
			if r.verifyHeal(ctx, c, masterKey, monitorAddr) {
				r.log.Info("heal succeeded", "action", "SENTINEL FAILOVER", "sentinel", c.Addr(), "master", monitorAddr)
				r.metrics.Inc("heal_ok")
				return
			}
			r.log.Warn("FAILOVER verify mismatch, trying REMOVE+MONITOR")
		}
	} else {
		r.log.Info("skip FAILOVER (promote guard)", "reason", why)
	}

	restored, err := r.applyRemoveMonitor(ctx, c, advertised, monitorAddr)
	if err != nil {
		r.logMonitorFailed(err, restored, monitorAddr)
		return
	}
	r.pause(1 * time.Second)
	if r.verifyHeal(ctx, c, masterKey, monitorAddr) {
		r.log.Info("heal succeeded", "action", "SENTINEL REMOVE+MONITOR", "sentinel", c.Addr(), "master", monitorAddr)
		r.metrics.Inc("heal_ok")
		return
	}

	// A hostname seed is only fixed when Sentinel echoes that hostname.
	// RESET would let peers teach the pod IP back.
	if plan.Reason == reasonLiveNonOracle || hostnameForm(monitorAddr) {
		reason := plan.Reason
		hint := ""
		if hostnameForm(monitorAddr) {
			reason = "hostname_not_advertised"
			hint = "get-master-addr-by-name must return the seed hostname; set resolve-hostnames yes and announce-hostnames yes"
		}
		r.log.Error("heal failed", "sentinel", c.Addr(), "oracle", masterKey, "monitor", monitorAddr, "reason", reason, "hint", hint, "conf_fallback_needed", true)
		r.metrics.Inc("heal_fail")
		return
	}

	r.log.Info("apply heal starting", "action", "SENTINEL RESET", "sentinel", c.Addr())
	_ = c.Reset(ctx, r.cfg.MasterName)
	r.pause(2 * time.Second)
	if r.verifyHeal(ctx, c, masterKey, monitorAddr) {
		r.log.Info("heal succeeded", "action", "SENTINEL RESET", "sentinel", c.Addr(), "master", monitorAddr)
		r.metrics.Inc("heal_ok")
		return
	}

	r.log.Error("heal failed", "sentinel", c.Addr(), "oracle", masterKey, "monitor", monitorAddr, "conf_fallback_needed", true)
	r.metrics.Inc("heal_fail")
}

// healAddressForm rewrites Sentinel's pointer from a pod IP to the seed
// hostname for the same Redis. It does not FAILOVER and does not RESET.
func (r *Reconciler) healAddressForm(ctx context.Context, c sentinelHealClient, advertised, masterKey, monitorAddr string) {
	r.log.Info("apply heal plan",
		"sentinel", c.Addr(),
		"action", string(actionMonitor),
		"reason", reasonAddressForm,
		"failover_safe", false,
		"advertised", advertised,
		"oracle", masterKey,
		"monitor", monitorAddr,
	)
	r.log.Info("skip FAILOVER (address form mismatch)", "advertised", advertised, "monitor", monitorAddr)
	if _, _, err := monitorHostPort(monitorAddr); err != nil {
		r.log.Error("heal aborted", "reason", "oracle_addr_unparseable", "oracle", monitorAddr, "err", err)
		r.metrics.Inc("heal_fail")
		return
	}
	r.lastHeal = time.Now()
	r.metrics.Inc("heal_attempt")
	restored, err := r.applyRemoveMonitor(ctx, c, advertised, monitorAddr)
	if err != nil {
		r.logMonitorFailed(err, restored, monitorAddr)
		return
	}
	r.pause(1 * time.Second)
	if r.verifyHeal(ctx, c, masterKey, monitorAddr) {
		r.log.Info("heal succeeded", "action", "SENTINEL REMOVE+MONITOR", "sentinel", c.Addr(), "master", monitorAddr, "reason", reasonAddressForm)
		r.metrics.Inc("heal_ok")
		return
	}
	r.log.Error("heal failed",
		"sentinel", c.Addr(),
		"oracle", masterKey,
		"monitor", monitorAddr,
		"reason", "hostname_not_advertised",
		"hint", "get-master-addr-by-name must return the seed hostname; set resolve-hostnames yes and announce-hostnames yes",
		"conf_fallback_needed", true,
	)
	r.metrics.Inc("heal_fail")
}

func (r *Reconciler) logMonitorFailed(err error, restored bool, monitorAddr string) {
	hint := ""
	if hostnameForm(monitorAddr) {
		hint = "sentinel requires resolve-hostnames yes to MONITOR a hostname"
	}
	r.log.Error("heal failed", "action", "MONITOR", "err", err, "restored_previous", restored, "conf_fallback_needed", !restored, "monitor", monitorAddr, "hint", hint)
	r.metrics.Inc("heal_fail")
}

// applyRemoveMonitor is REMOVE + MONITOR of monitorAddr (no LookupIP).
// If Sentinel rejects a hostname, the previous advertisement is written
// back when REMOVE already dropped it, so a working IP entry is not left
// removed and is not replaced by a different address.
func (r *Reconciler) applyRemoveMonitor(ctx context.Context, c sentinelHealClient, previous, monitorAddr string) (restored bool, err error) {
	host, port, err := monitorHostPort(monitorAddr)
	if err != nil {
		return false, err
	}
	r.log.Info("apply heal starting", "action", "SENTINEL REMOVE+MONITOR", "sentinel", c.Addr(), "host", host, "port", port)
	removeErr := c.Remove(ctx, r.cfg.MasterName)
	if removeErr != nil {
		r.log.Warn("SENTINEL REMOVE failed", "err", removeErr)
	}
	if err := c.Monitor(ctx, r.cfg.MasterName, host, port, r.cfg.Quorum); err != nil {
		removed := removeErr == nil
		tryRestore := removed && hostnameForm(monitorAddr) && !addrEqual(previous, monitorAddr)
		if tryRestore {
			restored = r.restoreMonitor(ctx, c, previous)
		}
		// Hostname MONITOR was rejected and the previous entry is not back.
		// Holding heal-cooldown here leaves Sentinel with no MONITOR entry
		// for the whole cooldown. An IP-seed MONITOR failure still waits.
		if tryRestore && !restored {
			r.lastHeal = time.Time{}
		}
		return restored, err
	}
	r.rebindSentinelAuth(ctx, c)
	return false, nil
}

func (r *Reconciler) restoreMonitor(ctx context.Context, c sentinelHealClient, previous string) bool {
	host, port, err := monitorHostPort(previous)
	if err != nil {
		r.log.Error("cannot restore previous sentinel address", "advertised", previous, "err", err)
		return false
	}
	if err := c.Monitor(ctx, r.cfg.MasterName, host, port, r.cfg.Quorum); err != nil {
		r.log.Error("restore MONITOR failed", "addr", previous, "err", err)
		return false
	}
	r.rebindSentinelAuth(ctx, c)
	r.log.Warn("restored previous sentinel address after hostname MONITOR reject", "addr", previous)
	return true
}

func (r *Reconciler) rebindSentinelAuth(ctx context.Context, c sentinelHealClient) {
	authUser, authPass := sentinelMasterAuth(r.cfg.RedisUsername, r.cfg.RedisPassword, r.cfg.SentinelRedisUsername, r.cfg.SentinelRedisPassword)
	for _, kv := range sentinelAuthAfterMonitor(authUser, authPass) {
		if err := c.Set(ctx, r.cfg.MasterName, kv[0], kv[1]); err != nil {
			r.log.Warn("SENTINEL SET failed", "option", kv[0], "err", err)
		} else {
			r.log.Info("re-bound sentinel " + kv[0] + " after MONITOR")
		}
	}
}

func (r *Reconciler) verifyHeal(ctx context.Context, c sentinelHealClient, dialAddr, wantAds string) bool {
	if !r.verifyAdvertised(ctx, c, wantAds) {
		return false
	}
	// Ads matching is not enough; the Redis must still accept writes.
	// Probe the address we required Sentinel to publish. dialAddr follows
	// probe-map order and may be the pod IP, which fails a DNS-SAN handshake
	// and reports a correct hostname MONITOR as heal_fail.
	probe := healDialAddr(wantAds, dialAddr)
	if err := r.probeOracleWritable(ctx, probe); err != nil {
		r.log.Warn("heal verify write-probe failed", "err", err, "addr", probe)
		return false
	}
	return true
}

func (r *Reconciler) verifyAdvertised(ctx context.Context, c sentinelHealClient, want string) bool {
	host, port, err := c.GetMasterAddrByName(ctx, r.cfg.MasterName)
	if err != nil {
		r.log.Warn("heal verify get-master-addr failed", "err", err)
		return false
	}
	after := masterAddr(host, port)
	hostname := hostnameForm(want)
	var ok bool
	if hostname {
		// Pod IP of the same master is not success. TLS certs have DNS SANs.
		ok = addrEqual(after, want)
	} else {
		ok = sameRedisEndpoint(after, want)
	}
	if !ok {
		r.log.Warn("heal verify mismatch", "got", after, "expected", want, "hostname_form", hostname)
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

func (r *Reconciler) pause(d time.Duration) {
	if r.writeProbe != nil {
		return
	}
	time.Sleep(d)
}

func (r *Reconciler) probeOracleWritable(ctx context.Context, masterKey string) error {
	if r.writeProbe != nil {
		return r.writeProbe(ctx, masterKey)
	}
	return reprobeOracleWritable(ctx, masterKey, r.redisDial())
}

// failoverPromoteSafe reports whether SENTINEL FAILOVER is likely to promote
// the writable Redis rather than some other replica.
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
		return false, reasonLiveNonOracle
	}
	if advReachableMaster && !sameRedisEndpoint(advertised, masterKey) {
		return false, reasonLiveWritableNotOracle
	}
	if advDown || !advReachableMaster {
		// Unique writable is still in REDIS_ADDRS. SENTINEL FAILOVER elects a
		// replica from Sentinel's view of the (dead/fake) advertised master.
		// That replica is not the oracle: dual. Heal ads with MONITOR.
		return false, reasonAdvertisedUnreachable
	}
	return false, "failover_may_promote_non_oracle"
}

// endpointIPPort splits host:port for SENTINEL MONITOR.
// A hostname is returned unchanged. LookupIP here used to publish the pod
// IP, and TLS clients whose certs have DNS SANs only then failed the handshake.
func endpointIPPort(addr string) (host string, port int, err error) {
	return monitorHostPort(addr)
}

func monitorHostPort(addr string) (host string, port int, err error) {
	host, portStr, err := net.SplitHostPort(addr)
	if err != nil {
		return "", 0, err
	}
	port, err = strconv.Atoi(portStr)
	if err != nil {
		return "", 0, err
	}
	if host == "" || port <= 0 {
		return "", 0, fmt.Errorf("invalid redis addr %q", addr)
	}
	return host, port, nil
}

type divergeKind int

const (
	divergeNoop divergeKind = iota
	divergeForm
	divergeMaster
)

// classifyDiverge decides whether Sentinel's advertisement needs a heal.
// Same resolved endpoint is a noop when the seed is an IP. When the seed is
// a hostname, an advertised IP for that same node is an address-form mismatch.
func classifyDiverge(advertised, masterKey, monitorAddr string, writable *oracle.NodeResult, nodes []oracle.NodeResult) divergeKind {
	if monitorAddr == "" {
		monitorAddr = masterKey
	}
	if addrEqual(advertised, monitorAddr) {
		return divergeNoop
	}
	if addressFormMismatch(advertised, monitorAddr, writable, nodes) {
		return divergeForm
	}
	// A probed run_id that differs is another Redis. Do not let DNS turn
	// that into a noop or an address-form rewrite.
	if differentProbedNode(advertised, writable, nodes) {
		return divergeMaster
	}
	if sameRedisEndpoint(advertised, masterKey) || sameRedisEndpoint(advertised, monitorAddr) {
		return divergeNoop
	}
	return divergeMaster
}

// addressFormMismatch is true when Sentinel advertises an IP (or any other
// string) for the same Redis whose --redis-addrs seed is a hostname.
func addressFormMismatch(advertised, monitorAddr string, writable *oracle.NodeResult, nodes []oracle.NodeResult) bool {
	if !hostnameForm(monitorAddr) || addrEqual(advertised, monitorAddr) {
		return false
	}
	// That hostname was probed as a different Redis. DNS must not rewrite
	// this master onto the other name.
	if differentProbedNode(monitorAddr, writable, nodes) {
		return false
	}
	return sameOracleNode(advertised, writable, nodes)
}

// preferredSeedAddr is the address SENTINEL MONITOR must write for writable.
// A hostname in seeds (--redis-addrs order) wins over an IP for that node.
// The result is never a LookupIP of the seed. Probe-map order cannot change it.
func preferredSeedAddr(writable *oracle.NodeResult, nodes []oracle.NodeResult, seeds []string) string {
	if writable == nil {
		return ""
	}
	ipSeed := ""
	var unresolved []string
	for _, seed := range seeds {
		host, _, err := net.SplitHostPort(seed)
		if err != nil {
			continue
		}
		host = strings.TrimRight(host, ".")
		if host == "" {
			continue
		}
		if literalNodeMatch(seed, writable, nodes) {
			if net.ParseIP(host) == nil {
				return seed
			}
			if ipSeed == "" {
				ipSeed = seed
			}
			continue
		}
		unresolved = append(unresolved, seed)
	}
	for _, seed := range unresolved {
		if !resolvedNodeMatch(seed, writable, nodes) {
			continue
		}
		host, _, err := net.SplitHostPort(seed)
		if err != nil {
			continue
		}
		host = strings.TrimRight(host, ".")
		if host == "" {
			continue
		}
		if net.ParseIP(host) == nil {
			return seed
		}
		if ipSeed == "" {
			ipSeed = seed
		}
	}
	if ipSeed != "" {
		return ipSeed
	}
	return writable.Addr
}

func literalNodeMatch(addr string, writable *oracle.NodeResult, nodes []oracle.NodeResult) bool {
	if writable == nil || addr == "" {
		return false
	}
	if addrEqual(addr, writable.Addr) {
		return true
	}
	if writable.RunID == "" {
		return false
	}
	for i := range nodes {
		n := &nodes[i]
		if n.Err != nil || n.RunID != writable.RunID {
			continue
		}
		if addrEqual(addr, n.Addr) {
			return true
		}
	}
	return false
}

func resolvedNodeMatch(addr string, writable *oracle.NodeResult, nodes []oracle.NodeResult) bool {
	if writable == nil || addr == "" || differentProbedNode(addr, writable, nodes) {
		return false
	}
	if sameNodeAddr(addr, writable.Addr) {
		return true
	}
	if writable.RunID == "" {
		return false
	}
	for i := range nodes {
		n := &nodes[i]
		if n.Err != nil || n.RunID != writable.RunID {
			continue
		}
		if sameNodeAddr(addr, n.Addr) {
			return true
		}
	}
	return false
}

// sameNodeAddr reports whether two host:port strings are the same endpoint
// for seed selection and address-form detection.
// sameRedisEndpoint (first A record only) stays the identity check for
// dual-master and failoverPromoteSafe. A hostname with both A and AAAA must
// still match an IPv6 advertisement here, or preferredSeedAddr falls back to
// whichever probe address map iteration classified first.
func sameNodeAddr(a, b string) bool {
	if addrEqual(a, b) || sameRedisEndpoint(a, b) {
		return true
	}
	return ipOverlap(a, b)
}

func sameOracleNode(advertised string, writable *oracle.NodeResult, nodes []oracle.NodeResult) bool {
	if differentProbedNode(advertised, writable, nodes) {
		return false
	}
	return literalNodeMatch(advertised, writable, nodes) || resolvedNodeMatch(advertised, writable, nodes)
}

// differentProbedNode is true when addr was probed with a run_id other than
// writable's. run_id identifies the Redis; DNS must not merge two of them.
func differentProbedNode(addr string, writable *oracle.NodeResult, nodes []oracle.NodeResult) bool {
	if writable == nil || writable.RunID == "" || addr == "" {
		return false
	}
	for i := range nodes {
		n := &nodes[i]
		if n.Err != nil || n.RunID == "" || !addrEqual(addr, n.Addr) {
			continue
		}
		return n.RunID != writable.RunID
	}
	return false
}

func nodeByAddr(nodes []oracle.NodeResult, addr string) *oracle.NodeResult {
	for i := range nodes {
		if addrEqual(nodes[i].Addr, addr) {
			return &nodes[i]
		}
	}
	return nil
}

func hostnameForm(addr string) bool {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		// "2001:db8::1:6379" is a missing-bracket IPv6, not a hostname.
		return false
	}
	host = strings.TrimRight(host, ".")
	return host != "" && net.ParseIP(host) == nil
}

func addrEqual(a, b string) bool {
	if a == "" || b == "" {
		return false
	}
	ah, ap, errA := net.SplitHostPort(a)
	bh, bp, errB := net.SplitHostPort(b)
	if errA != nil || errB != nil {
		return hostsEqual(a, b)
	}
	pa, ea := strconv.Atoi(ap)
	pb, eb := strconv.Atoi(bp)
	if ea != nil || eb != nil || pa != pb {
		return false
	}
	return hostsEqual(ah, bh)
}

func hostsEqual(a, b string) bool {
	a = strings.TrimRight(a, ".")
	b = strings.TrimRight(b, ".")
	if a == "" || b == "" {
		return false
	}
	if strings.EqualFold(a, b) {
		return true
	}
	ipa, ipb := net.ParseIP(a), net.ParseIP(b)
	return ipa != nil && ipb != nil && ipa.Equal(ipb)
}

// masterAddr is host:port with brackets around IPv6. fmt.Sprintf("%s:%d")
// makes SplitHostPort fail, and hostnameForm then treats the pod IP as a name.
func masterAddr(host string, port int) string {
	return net.JoinHostPort(host, strconv.Itoa(port))
}

// healDialAddr is the address to dial for the lease and the post-heal write
// probe. monitorAddr is the --redis-addrs seed; masterKey is whichever probe
// map iteration classified first.
func healDialAddr(monitorAddr, masterKey string) string {
	if monitorAddr != "" {
		return monitorAddr
	}
	return masterKey
}

// netLookupIP is LookupIP for seed and address-form matching. Tests replace
// it to simulate A+AAAA. sameRedisEndpoint keeps calling net.LookupIP so
// dual-master and failoverPromoteSafe stay on the first A record.
var netLookupIP = net.LookupIP

func ipOverlap(a, b string) bool {
	ah, ap, errA := net.SplitHostPort(a)
	bh, bp, errB := net.SplitHostPort(b)
	if errA != nil || errB != nil {
		return false
	}
	pa, ea := strconv.Atoi(ap)
	pb, eb := strconv.Atoi(bp)
	if ea != nil || eb != nil || pa != pb || pa <= 0 {
		return false
	}
	for _, ia := range hostIPs(ah) {
		for _, ib := range hostIPs(bh) {
			if ia.Equal(ib) {
				return true
			}
		}
	}
	return false
}

func hostIPs(host string) []net.IP {
	host = strings.TrimRight(host, ".")
	if ip := net.ParseIP(host); ip != nil {
		return []net.IP{ip}
	}
	ips, err := netLookupIP(host)
	if err != nil || len(ips) == 0 {
		return nil
	}
	return ips
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
