APP_NAME=tracker
WORKER_SRC=zig-out/bin/tt
WORKER_EMBED=internal/worker/assets/tt-worker
BIN_DIR ?= $(HOME)/.local/bin
INSTALL_PATH ?= $(BIN_DIR)/$(APP_NAME)

.PHONY: build build-worker sync-worker build-manager install test test-go test-zig test-fast clean

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

install: build
	@mkdir -p "$(BIN_DIR)"
	@cp "$(APP_NAME)" "$(INSTALL_PATH)"
	@chmod +x "$(INSTALL_PATH)"
	@echo "installed $(APP_NAME) -> $(INSTALL_PATH)"

test: test-zig test-go

test-zig:
	zig build test --summary all

test-go:
	GOFLAGS=-mod=mod go test -race -shuffle=on -count=1 ./...

test-fast:
	zig build test
	go test -mod=mod ./...

clean:
	rm -f $(APP_NAME)
