package reconcile

import (
	"context"
	"strconv"
	"strings"

	"github.com/vpnmesh/redis-sentinel-reconciler/internal/sentinel"
)

// EqualEpochReport is the R9 detect outcome across reachable Sentinels.
type EqualEpochReport struct {
	Trap       bool
	Epochs     []int64
	Ads        []string
	SampleSize int
}

// detectEqualEpochTrap samples get-master-addr + config-epoch from configured
// clients and, if only one client, from peers learned via SENTINEL sentinels.
func detectEqualEpochTrap(ctx context.Context, clients []*sentinel.Client, peer sentinel.Dial, masterName string) EqualEpochReport {
	rep := EqualEpochReport{}
	type sample struct {
		ad    string
		epoch int64
	}
	var samples []sample
	seen := map[string]struct{}{}

	add := func(c *sentinel.Client) {
		if c == nil {
			return
		}
		key := strings.ToLower(c.Addr())
		if _, ok := seen[key]; ok {
			return
		}
		seen[key] = struct{}{}
		host, port, err := c.GetMasterAddrByName(ctx, masterName)
		if err != nil || host == "" {
			return
		}
		ad := host + ":" + strconv.Itoa(port)
		epoch := int64(-1)
		if info, err := c.Master(ctx, masterName); err == nil {
			if e, ok := info["config-epoch"]; ok {
				if n, err := strconv.ParseInt(e, 10, 64); err == nil {
					epoch = n
				}
			}
		}
		samples = append(samples, sample{ad: ad, epoch: epoch})
	}

	for _, c := range clients {
		add(c)
	}
	// Discover peers when we only dialed one Sentinel (typical --local-sentinel).
	if len(clients) > 0 {
		if peers, err := clients[0].Sentinels(ctx, masterName); err == nil {
			for _, p := range peers {
				ip := p["ip"]
				port := p["port"]
				if ip == "" || port == "" {
					continue
				}
				addr := ip + ":" + port
				peer.Addr = addr
				c := sentinel.New(peer)
				add(c)
				_ = c.Close()
			}
		}
	}

	rep.SampleSize = len(samples)
	ads := map[string]struct{}{}
	epochs := map[int64]struct{}{}
	for _, s := range samples {
		rep.Ads = append(rep.Ads, s.ad)
		ads[strings.ToLower(s.ad)] = struct{}{}
		if s.epoch >= 0 {
			rep.Epochs = append(rep.Epochs, s.epoch)
			epochs[s.epoch] = struct{}{}
		}
	}
	// Disagreeing ads + no conflicting epochs (0 or 1 unique known epoch) => trap.
	// Do not require >=2 successfully parsed epochs (peer Master() can fail while ads differ).
	if len(ads) >= 2 && len(epochs) <= 1 {
		rep.Trap = true
	}
	return rep
}
