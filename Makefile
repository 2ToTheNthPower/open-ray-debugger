NVIM ?= nvim
PYTHON ?= python3
DEPS := .deps

# Use the checkout from `make deps` when present.
NVIM_DAP_PATH ?= $(if $(wildcard $(DEPS)/nvim-dap),$(CURDIR)/$(DEPS)/nvim-dap,)
STYLUA ?= $(if $(wildcard $(DEPS)/bin/stylua),$(DEPS)/bin/stylua,stylua)

.PHONY: deps test test-integration test-ray lint format

# Fetch the test-only dependencies into .deps/ (git-ignored):
# nvim-dap for the integration tests. Python packages are up to you:
#   pip install debugpy                 # make test-integration
#   pip install "ray[default]" debugpy  # make test-ray
deps:
	mkdir -p $(DEPS)
	test -d $(DEPS)/nvim-dap || git clone --depth=1 https://github.com/mfussenegger/nvim-dap.git $(DEPS)/nvim-dap

# Unit + protocol tests (nvim-dap integration tests run when nvim-dap is found).
test:
	NVIM_DAP_PATH=$(NVIM_DAP_PATH) $(NVIM) --clean -l tests/run.lua

# Adds the real debugpy end-to-end tests (requires `pip install debugpy`).
test-integration:
	RAY_DEBUGGER_DEBUGPY=1 RAY_DEBUGGER_PYTHON=$(PYTHON) NVIM_DAP_PATH=$(NVIM_DAP_PATH) \
		$(NVIM) --clean -l tests/run.lua

# End-to-end scenarios against a real Ray cluster (breakpoint, actor,
# post-mortem, Ray Job with working_dir).
# Requires `pip install "ray[default]" debugpy` and a nvim-dap checkout.
test-ray:
	NVIM=$(NVIM) PYTHON=$(PYTHON) NVIM_DAP_PATH=$(NVIM_DAP_PATH) \
		bash tests/integration/real_ray_cluster.sh

lint:
	$(STYLUA) --check lua plugin tests

format:
	$(STYLUA) lua plugin tests
