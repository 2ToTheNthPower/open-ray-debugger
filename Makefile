NVIM ?= nvim
NVIM_DAP_PATH ?=
PYTHON ?= python3

.PHONY: test test-integration lint

# Unit + protocol tests. Set NVIM_DAP_PATH to a nvim-dap checkout to enable
# the nvim-dap integration tests:
#   make test NVIM_DAP_PATH=/path/to/nvim-dap
test:
	NVIM_DAP_PATH=$(NVIM_DAP_PATH) $(NVIM) --clean -l tests/run.lua

# Adds the real debugpy end-to-end test (requires `pip install debugpy`).
test-integration:
	RAY_DEBUGGER_DEBUGPY=1 RAY_DEBUGGER_PYTHON=$(PYTHON) NVIM_DAP_PATH=$(NVIM_DAP_PATH) \
		$(NVIM) --clean -l tests/run.lua

# End-to-end test against a real Ray cluster.
# Requires `pip install "ray[default]" debugpy` and a nvim-dap checkout.
test-ray:
	NVIM=$(NVIM) PYTHON=$(PYTHON) NVIM_DAP_PATH=$(NVIM_DAP_PATH) \
		bash tests/integration/real_ray_cluster.sh

lint:
	stylua --check lua plugin tests
