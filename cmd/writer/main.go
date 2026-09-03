package main

import (
	"context"
	"flag"
	"log/slog"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/redis/go-redis/v9"
	"github.com/vpnmesh/redis-sentinel-reconciler/internal/sentinel"
)

func main() {
	var (
		sentinelAddrs = multiFlag{}
		masterName    = flag.String("master-name", "mymaster", "Sentinel master name")
		interval      = flag.Duration("interval", time.Second, "Write interval")
		redisPassword = flag.String("redis-password", "", "Redis ACL/password")
		sentPassword  = flag.String("sentinel-password", "", "Sentinel ACL/password")
	)
	flag.Var(&sentinelAddrs, "sentinel-addrs", "Sentinel host:port (repeatable or comma-separated)")
	flag.Parse()

	if len(sentinelAddrs) == 0 {
		slog.Error("at least one --sentinel-addrs is required")
		os.Exit(2)
	}

	log := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	sent := sentinel.NewClient(sentinelAddrs[0], *sentPassword)
	defer sent.Close()

	ticker := time.NewTicker(*interval)
	defer ticker.Stop()

	writeOnce := func() {
		host, port, err := sent.GetMasterAddrByName(ctx, *masterName)
		if err != nil {
			log.Error("get master failed", "err", err)
			return
		}
		addr := formatAddr(host, port)
		rdb := redis.NewClient(&redis.Options{
			Addr:         addr,
			Password:     *redisPassword,
			DialTimeout:  3 * time.Second,
			ReadTimeout:  3 * time.Second,
			WriteTimeout: 3 * time.Second,
		})
		defer rdb.Close()

		now := time.Now().UTC().Format(time.RFC3339Nano)
		if err := rdb.Set(ctx, "lab:writer:ts", now, 30*time.Second).Err(); err != nil {
			log.Error("SET failed", "master", addr, "err", err)
			return
		}
		log.Info("SET ok", "master", addr, "value", now)
	}

	writeOnce()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			writeOnce()
		}
	}
}

func formatAddr(host string, port int) string {
	return host + ":" + itoa(port)
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b [16]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	return string(b[i:])
}

type multiFlag []string

func (m *multiFlag) String() string { return strings.Join(*m, ",") }

func (m *multiFlag) Set(value string) error {
	for _, part := range strings.Split(value, ",") {
		part = strings.TrimSpace(part)
		if part != "" {
			*m = append(*m, part)
		}
	}
	return nil
}
