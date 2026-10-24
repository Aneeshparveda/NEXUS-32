SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

# Prefer a complete toolchain pair rather than mixing target prefixes.  The
# environment may override either variable for an explicitly installed tool.
RISC_V_PREFIX := $(shell \
	if command -v riscv64-elf-gcc >/dev/null 2>&1 && \
	   command -v riscv64-elf-objcopy >/dev/null 2>&1; then \
		printf '%s' riscv64-elf; \
	elif command -v riscv64-unknown-elf-gcc >/dev/null 2>&1 && \
	     command -v riscv64-unknown-elf-objcopy >/dev/null 2>&1; then \
		printf '%s' riscv64-unknown-elf; \
	fi)

RISCV_CC ?= $(if $(RISC_V_PREFIX),$(RISC_V_PREFIX)-gcc,)
RISCV_OBJCOPY ?= $(if $(RISC_V_PREFIX),$(RISC_V_PREFIX)-objcopy,)
export RISCV_CC RISCV_OBJCOPY

PICORV32_PIN := ef203c2b0a3fb793280f5114941416c425c5b461
PICORV32_SOURCE := vendor/picorv32/picorv32.v
PICORV32_REVISION := vendor/picorv32/REVISION.txt
SMOKE_FIRMWARE := firmware/nexus32_smoke.hex
VERILATOR_LOG := results/verification-closure/verilator-lint.log

.PHONY: setup test test-fault test-all check-tool-selection check-vendor check-prerequisites \
	python-tests toolchain rtl differential status-property soc soc-latency basys3 vivado-flow-stub provenance-test verilator \
	verification-closure

# The full regression is intentionally offline: it never runs make setup.
# Run that target once on a connected machine to provision the pinned source
# and firmware images required by the SoC checks.
test: status-property check-prerequisites python-tests toolchain rtl differential soc soc-latency basys3 vivado-flow-stub provenance-test verilator verification-closure

test-fault: check-vendor
	@mkdir -p results/rtl
	@iverilog -g2012 -Wall -s tb_nexus32_soc_fault_data \
		-o results/rtl/tb_nexus32_soc_fault_data.vvp \
		$(PICORV32_SOURCE) \
		rtl/fir_q16_mac.sv \
		rtl/fir_q16_postprocess.sv \
		rtl/fir_seq_engine.sv \
		rtl/fir_parallel_engine.sv \
		rtl/fir_pipelined_engine.sv \
		rtl/fir_arch_selector.sv \
		rtl/fir_tap_bram.sv \
		rtl/fir_seq_accel.sv \
		rtl/nexus32_accel_bus.sv \
		rtl/nexus32_soc.sv \
		tests/rtl/tb_nexus32_soc_fault_data.sv
	@vvp results/rtl/tb_nexus32_soc_fault_data.vvp

test-all: test test-fault

check-tool-selection:
	@if [[ -z "$(RISCV_CC)" || -z "$(RISCV_OBJCOPY)" ]]; then \
		printf '%s\n' 'ERROR: no complete supported RISC-V toolchain found.' >&2; \
		printf '%s\n' '       Install riscv64-elf-gcc/objcopy or riscv64-unknown-elf-gcc/objcopy,' >&2; \
		printf '%s\n' '       or set RISCV_CC and RISCV_OBJCOPY to executable names or paths.' >&2; \
		exit 1; \
	fi
	@if ! command -v "$(RISCV_CC)" >/dev/null 2>&1; then \
		printf 'ERROR: selected RISCV_CC is not executable on PATH: %s\n' "$(RISCV_CC)" >&2; \
		exit 1; \
	fi
	@if ! command -v "$(RISCV_OBJCOPY)" >/dev/null 2>&1; then \
		printf 'ERROR: selected RISCV_OBJCOPY is not executable on PATH: %s\n' "$(RISCV_OBJCOPY)" >&2; \
		exit 1; \
	fi
	@printf 'Selected RISC-V tools: RISCV_CC=%s RISCV_OBJCOPY=%s\n' "$(RISCV_CC)" "$(RISCV_OBJCOPY)"

check-prerequisites: check-vendor check-tool-selection

check-vendor:
	@if [[ ! -f "$(PICORV32_SOURCE)" ]]; then \
		printf 'ERROR: pinned PicoRV32 source is absent: %s\n' "$(PICORV32_SOURCE)" >&2; \
		printf '%s\n' '       Run "make setup" on a networked machine to provision the pinned checkout.' >&2; \
		exit 1; \
	fi
	@if [[ ! -f "$(PICORV32_REVISION)" ]] || ! grep -Fq 'Pinned commit: $(PICORV32_PIN)' "$(PICORV32_REVISION)"; then \
		printf 'ERROR: pinned PicoRV32 revision record is absent or does not match %s: %s\n' \
			"$(PICORV32_PIN)" "$(PICORV32_REVISION)" >&2; \
		printf '%s\n' '       Refusing to run the offline gate with an unverified vendor source.' >&2; \
		exit 1; \
	fi
	@if [[ ! -f "$(SMOKE_FIRMWARE)" ]]; then \
		printf 'ERROR: prepared smoke firmware is absent: %s\n' "$(SMOKE_FIRMWARE)" >&2; \
		printf '%s\n' '       Run "make setup" on a networked machine before running "make test".' >&2; \
		exit 1; \
	fi
	@printf '%s\n' 'Offline prerequisites: pinned PicoRV32 source and smoke firmware are present.'

# Setup is deliberately separate from test because vendoring clones the pinned
# upstream revision and therefore requires network access on a fresh checkout.
setup: check-tool-selection
	@printf '%s\n' 'Provisioning pinned PicoRV32 and preparing firmware images...'
	@bash scripts/vendor_picorv32.sh
	@bash scripts/build_smoke_firmware.sh
	@bash scripts/build_multiarch_firmware.sh
	@bash scripts/build_invalid_fetch_firmware.sh
	@printf '%s\n' 'Setup complete.'

python-tests:
	@python3 -m unittest discover -s tests -v

toolchain:
	@bash scripts/check_toolchain.sh

rtl:
	@bash scripts/run_rtl_smoke.sh

differential:
	@bash scripts/run_differential_smoke.sh all

status-property:
	@bash scripts/run_status_property.sh

soc:
	@bash scripts/run_soc_smoke.sh all

soc-latency:
	@bash scripts/run_soc_latency.sh

basys3:
	@python3 scripts/check_basys3_constraints.py

vivado-flow-stub:
	@bash scripts/test_basys3_flow_stub.sh

provenance-test:
	@tclsh scripts/test_core_characterization_provenance.tcl

verilator:
	@mkdir -p results/verification-closure
	@verilator --lint-only --Wall --Wno-fatal --top-module top_basys3 \
		vendor/picorv32/picorv32.v \
		rtl/fir_q16_mac.sv rtl/fir_q16_postprocess.sv rtl/fir_seq_engine.sv \
		rtl/fir_parallel_engine.sv rtl/fir_pipelined_engine.sv rtl/fir_arch_selector.sv \
		rtl/fir_tap_bram.sv rtl/fir_seq_accel.sv rtl/nexus32_accel_bus.sv \
		rtl/nexus32_soc.sv rtl/top_basys3.sv \
		2>&1 | tee "$(VERILATOR_LOG)"

verification-closure:
	@bash scripts/run_verification_closure.sh
