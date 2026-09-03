# Lab chaos helpers for redis-sentinel-reconciler (5 Redis + 5 Sentinel)

COMPOSE := docker compose -f lab/docker-compose.yml
MASTER_NAME ?= mymaster
CLUSTER_N ?= 5
# Vagrant data-plane: redis (apt) | valkey (bins from make vagrant-engine-bins)
ENGINE ?= redis
VG := cd lab/vagrant && CLUSTER_N=$(CLUSTER_N) ENGINE=$(ENGINE)

.PHONY: up down ps logs master e2e e2e-smoke e2e-matrix e2e-hazards e2e-stress e2e-readiness \
	chaos-kill-redis-master chaos-kill-sentinel chaos-kill-node1 chaos-start-node1 chaos-partition-hint \
	vagrant-bin vagrant-net vagrant-up vagrant-provision vagrant-smoke vagrant-halt vagrant-destroy \
	vagrant-snap vagrant-mode-c0 vagrant-mode-c1 vagrant-mode-c2 \
	vagrant-engine-bins vagrant-a09 vagrant-a01 dist

up:
	$(COMPOSE) up -d --build
	./lab/scripts/wait-ready.sh || true

down:
	$(COMPOSE) down -v

ps:
	$(COMPOSE) ps

logs:
	$(COMPOSE) logs -f --tail=100

master:
	@docker exec $$($(COMPOSE) ps -q sentinel-1) redis-cli -p 26379 SENTINEL get-master-addr-by-name $(MASTER_NAME)

e2e:
	E2E_SUITE=all ./lab/e2e/run_all.sh

e2e-smoke:
	E2E_SUITE=smoke ./lab/e2e/run_all.sh

e2e-matrix:
	E2E_SUITE=matrix ./lab/e2e/run_all.sh

e2e-hazards:
	./lab/e2e/hazards/run.sh

e2e-stress:
	./lab/e2e/stress/run.sh

e2e-readiness:
	./lab/e2e/readiness/run.sh

dist:
	./scripts/package-linux-amd64.sh

# --- Vagrant bare-metal-like lab (Docker provider + systemd) ---
# Plan: lab/vagrant/PLAN.md  ·  ENGINE=redis|valkey
vagrant-bin:
	./lab/vagrant/scripts/labctl.sh build-bin

vagrant-engine-bins:
	ENGINE=$(ENGINE) ./lab/vagrant/scripts/fetch-engine-bins.sh

vagrant-net:
	docker network inspect rsr-vagrant-lab >/dev/null 2>&1 || docker network create rsr-vagrant-lab

vagrant-up: vagrant-bin vagrant-net
	@if [ "$(ENGINE)" = "valkey" ]; then $(MAKE) vagrant-engine-bins ENGINE=valkey; fi
	$(VG) vagrant up --provider=docker || true
	CLUSTER_N=$(CLUSTER_N) MASTER_NAME=$(MASTER_NAME) ENGINE=$(ENGINE) \
		./lab/vagrant/scripts/provision-all.sh

vagrant-provision:
	CLUSTER_N=$(CLUSTER_N) MASTER_NAME=$(MASTER_NAME) ENGINE=$(ENGINE) \
		./lab/vagrant/scripts/provision-all.sh

vagrant-smoke:
	CLUSTER_N=$(CLUSTER_N) ENGINE=$(ENGINE) ./lab/vagrant/scripts/labctl.sh smoke

vagrant-restore:
	CLUSTER_N=$(CLUSTER_N) ./lab/vagrant/scripts/labctl.sh restore-steady

vagrant-snap:
	CLUSTER_N=$(CLUSTER_N) ./lab/vagrant/scripts/labctl.sh snap

vagrant-mode-c0:
	CLUSTER_N=$(CLUSTER_N) ./lab/vagrant/scripts/labctl.sh mode C0

vagrant-mode-c1:
	CLUSTER_N=$(CLUSTER_N) ./lab/vagrant/scripts/labctl.sh mode C1

vagrant-mode-c2:
	CLUSTER_N=$(CLUSTER_N) ./lab/vagrant/scripts/labctl.sh mode C2

vagrant-a09:
	CLUSTER_N=$(CLUSTER_N) ENGINE=$(ENGINE) ./lab/vagrant/e2e/A09_wrong_monitor.sh

vagrant-a01:
	CLUSTER_N=$(CLUSTER_N) ENGINE=$(ENGINE) ./lab/vagrant/e2e/A01_old_master_return.sh

vagrant-halt:
	$(VG) vagrant halt

vagrant-destroy:
	$(VG) vagrant destroy -f

chaos-kill-redis-master:
	@set -e; \
	addr=$$(docker exec $$($(COMPOSE) ps -q sentinel-1) redis-cli -p 26379 SENTINEL get-master-addr-by-name $(MASTER_NAME) | head -1 | tr -d '\r'); \
	echo "sentinel says master host=$$addr"; \
	svc=""; \
	for s in redis-1 redis-2 redis-3 redis-4 redis-5; do \
	  tip=$$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $$($(COMPOSE) ps -aq $$s)); \
	  if [ "$$tip" = "$$addr" ] || [ "$$s" = "$$addr" ]; then svc=$$s; break; fi; \
	done; \
	if [ -z "$$svc" ]; then echo "cannot map $$addr to compose service"; exit 1; fi; \
	echo "stopping $$svc"; \
	$(COMPOSE) stop $$svc; \
	echo "stopped; watch failover + writer/reconciler logs"

chaos-kill-sentinel:
	$(COMPOSE) stop sentinel-2
	@echo "stopped sentinel-2; quorum=3 remains with other sentinels"

chaos-kill-node1:
	$(COMPOSE) stop redis-1 sentinel-1
	@echo "stopped redis-1+sentinel-1"

chaos-start-node1:
	$(COMPOSE) start redis-1 sentinel-1
	@echo "started redis-1+sentinel-1"

chaos-partition-hint:
	@echo "Network name: redis-sentinel-lab"
	@echo "  docker network disconnect redis-sentinel-lab <container>"
	@echo "  docker network connect redis-sentinel-lab <container>"
