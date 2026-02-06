APP_NAME=tracker
WORKER_SRC=zig-out/bin/tt
WORKER_EMBED=internal/worker/assets/tt-worker

.PHONY: build build-worker sync-worker build-manager test clean

build: build-worker sync-worker build-manager

build-worker:
	zig build

sync-worker:
	@if [ -f "$(WORKER_SRC)" ]; then \
		cp "$(WORKER_SRC)" "$(WORKER_EMBED)"; \
		chmod +x "$(WORKER_EMBED)"; \
		echo "synced worker -> $(WORKER_EMBED)"; \
	else \
		echo "worker not found at $(WORKER_SRC)"; \
		exit 1; \
	fi

build-manager:
	go build -mod=mod -o $(APP_NAME) ./cmd/tt

test:
	go test -mod=mod ./...

clean:
	rm -f $(APP_NAME)
