#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p results/rtl
TARGET_LANES="${1:-all}"

run_soc_suite() {
  local lanes="$1"
  echo "============================================================"
  echo "--- Testing NEXUS-32 Bus and SoC with LANES=${lanes} ---"
  echo "============================================================"

  echo "1. tb_nexus32_accel_bus (LANES=${lanes})"
  iverilog -g2012 -Wall -s tb_nexus32_accel_bus \
    -P tb_nexus32_accel_bus.LANES="${lanes}" \
    -o "results/rtl/tb_nexus32_accel_bus_l${lanes}.vvp" \
    rtl/fir_q16_mac.sv rtl/fir_q16_postprocess.sv rtl/fir_seq_engine.sv \
    rtl/fir_parallel_engine.sv rtl/fir_pipelined_engine.sv rtl/fir_arch_selector.sv \
    rtl/fir_tap_bram.sv rtl/fir_seq_accel.sv rtl/nexus32_accel_bus.sv \
    tests/rtl/tb_nexus32_accel_bus.sv
  vvp "results/rtl/tb_nexus32_accel_bus_l${lanes}.vvp"

  echo "2. tb_nexus32_accel_bus_stall (LANES=${lanes})"
  iverilog -g2012 -Wall -s tb_nexus32_accel_bus_stall \
    -P tb_nexus32_accel_bus_stall.LANES="${lanes}" \
    -o "results/rtl/tb_nexus32_accel_bus_stall_l${lanes}.vvp" \
    rtl/fir_q16_mac.sv rtl/fir_q16_postprocess.sv rtl/fir_seq_engine.sv \
    rtl/fir_parallel_engine.sv rtl/fir_pipelined_engine.sv rtl/fir_arch_selector.sv \
    rtl/fir_tap_bram.sv rtl/fir_seq_accel.sv rtl/nexus32_accel_bus.sv \
    tests/rtl/tb_nexus32_accel_bus_stall.sv
  vvp "results/rtl/tb_nexus32_accel_bus_stall_l${lanes}.vvp"

  echo "3. tb_nexus32_soc (LANES=${lanes})"
  iverilog -g2012 -Wall -s tb_nexus32_soc \
    -P tb_nexus32_soc.LANES="${lanes}" \
    -o "results/rtl/tb_nexus32_soc_l${lanes}.vvp" \
    vendor/picorv32/picorv32.v \
    rtl/fir_q16_mac.sv rtl/fir_q16_postprocess.sv rtl/fir_seq_engine.sv \
    rtl/fir_parallel_engine.sv rtl/fir_pipelined_engine.sv rtl/fir_arch_selector.sv \
    rtl/fir_tap_bram.sv rtl/fir_seq_accel.sv rtl/nexus32_accel_bus.sv \
    rtl/nexus32_soc.sv tests/rtl/tb_nexus32_soc.sv
  vvp "results/rtl/tb_nexus32_soc_l${lanes}.vvp"

  echo "4. tb_nexus32_soc_multiarch (LANES=${lanes})"
  iverilog -g2012 -Wall -s tb_nexus32_soc_multiarch \
    -P tb_nexus32_soc_multiarch.LANES="${lanes}" \
    -o "results/rtl/tb_nexus32_soc_multiarch_l${lanes}.vvp" \
    vendor/picorv32/picorv32.v \
    rtl/fir_q16_mac.sv rtl/fir_q16_postprocess.sv rtl/fir_seq_engine.sv \
    rtl/fir_parallel_engine.sv rtl/fir_pipelined_engine.sv rtl/fir_arch_selector.sv \
    rtl/fir_tap_bram.sv rtl/fir_seq_accel.sv rtl/nexus32_accel_bus.sv \
    rtl/nexus32_soc.sv tests/rtl/tb_nexus32_soc_multiarch.sv
  vvp "results/rtl/tb_nexus32_soc_multiarch_l${lanes}.vvp"

  echo "5. tb_nexus32_soc_reset_recovery (LANES=${lanes})"
  iverilog -g2012 -Wall -s tb_nexus32_soc_reset_recovery \
    -P tb_nexus32_soc_reset_recovery.LANES="${lanes}" \
    -o "results/rtl/tb_nexus32_soc_reset_recovery_l${lanes}.vvp" \
    vendor/picorv32/picorv32.v \
    rtl/fir_q16_mac.sv rtl/fir_q16_postprocess.sv rtl/fir_seq_engine.sv \
    rtl/fir_parallel_engine.sv rtl/fir_pipelined_engine.sv rtl/fir_arch_selector.sv \
    rtl/fir_tap_bram.sv rtl/fir_seq_accel.sv rtl/nexus32_accel_bus.sv \
    rtl/nexus32_soc.sv tests/rtl/tb_nexus32_soc_reset_recovery.sv
  vvp "results/rtl/tb_nexus32_soc_reset_recovery_l${lanes}.vvp"

  echo "6. tb_nexus32_invalid_fetch (LANES=${lanes})"
  iverilog -g2012 -Wall -s tb_nexus32_invalid_fetch \
    -P tb_nexus32_invalid_fetch.LANES="${lanes}" \
    -o "results/rtl/tb_nexus32_invalid_fetch_l${lanes}.vvp" \
    vendor/picorv32/picorv32.v \
    rtl/fir_q16_mac.sv rtl/fir_q16_postprocess.sv rtl/fir_seq_engine.sv \
    rtl/fir_parallel_engine.sv rtl/fir_pipelined_engine.sv rtl/fir_arch_selector.sv \
    rtl/fir_tap_bram.sv rtl/fir_seq_accel.sv rtl/nexus32_accel_bus.sv \
    rtl/nexus32_soc.sv tests/rtl/tb_nexus32_invalid_fetch.sv
  vvp "results/rtl/tb_nexus32_invalid_fetch_l${lanes}.vvp"

  echo "7. tb_nexus32_soc_invalid_tap (LANES=${lanes})"
  iverilog -g2012 -Wall -s tb_nexus32_soc_invalid_tap \
    -P tb_nexus32_soc_invalid_tap.LANES="${lanes}" \
    -o "results/rtl/tb_nexus32_soc_invalid_tap_l${lanes}.vvp" \
    vendor/picorv32/picorv32.v \
    rtl/fir_q16_mac.sv rtl/fir_q16_postprocess.sv rtl/fir_seq_engine.sv \
    rtl/fir_parallel_engine.sv rtl/fir_pipelined_engine.sv rtl/fir_arch_selector.sv \
    rtl/fir_tap_bram.sv rtl/fir_seq_accel.sv rtl/nexus32_accel_bus.sv \
    rtl/nexus32_soc.sv tests/rtl/tb_nexus32_soc_invalid_tap.sv
  vvp "results/rtl/tb_nexus32_soc_invalid_tap_l${lanes}.vvp"

  echo "8. tb_nexus32_soc_invalid_arch (LANES=${lanes})"
  iverilog -g2012 -Wall -s tb_nexus32_soc_invalid_arch \
    -P tb_nexus32_soc_invalid_arch.LANES="${lanes}" \
    -o "results/rtl/tb_nexus32_soc_invalid_arch_l${lanes}.vvp" \
    vendor/picorv32/picorv32.v \
    rtl/fir_q16_mac.sv rtl/fir_q16_postprocess.sv rtl/fir_seq_engine.sv \
    rtl/fir_parallel_engine.sv rtl/fir_pipelined_engine.sv rtl/fir_arch_selector.sv \
    rtl/fir_tap_bram.sv rtl/fir_seq_accel.sv rtl/nexus32_accel_bus.sv \
    rtl/nexus32_soc.sv tests/rtl/tb_nexus32_soc_invalid_arch.sv
  vvp "results/rtl/tb_nexus32_soc_invalid_arch_l${lanes}.vvp"

  # The timeout stimulus runs once at the representative maximum-lane build;
  # the preflight error stimuli above sweep all supported lane configurations.
  if [[ "${lanes}" == "32" ]]; then
    echo "9. tb_nexus32_soc_timeout (LANES=${lanes})"
    iverilog -g2012 -Wall -s tb_nexus32_soc_timeout \
      -P tb_nexus32_soc_timeout.LANES="${lanes}" \
      -o "results/rtl/tb_nexus32_soc_timeout_l${lanes}.vvp" \
      vendor/picorv32/picorv32.v \
      rtl/fir_q16_mac.sv rtl/fir_q16_postprocess.sv rtl/fir_seq_engine.sv \
      rtl/fir_parallel_engine.sv rtl/fir_pipelined_engine.sv rtl/fir_arch_selector.sv \
      rtl/fir_tap_bram.sv rtl/fir_seq_accel.sv rtl/nexus32_accel_bus.sv \
      rtl/nexus32_soc.sv tests/rtl/tb_nexus32_soc_timeout.sv
    vvp "results/rtl/tb_nexus32_soc_timeout_l${lanes}.vvp"
  fi
}

# Ensure firmware binaries are up to date
bash scripts/build_smoke_firmware.sh
bash scripts/build_multiarch_firmware.sh
bash scripts/build_invalid_fetch_firmware.sh
bash scripts/build_invalid_tap_firmware.sh
bash scripts/build_invalid_arch_firmware.sh
bash scripts/build_timeout_firmware.sh

if [[ "${TARGET_LANES}" == "all" ]]; then
  for l in 4 8 16 32; do
    run_soc_suite "$l"
  done
else
  run_soc_suite "${TARGET_LANES}"
fi

echo "============================================================"
echo "ALL NEXUS-32 BUS AND SOC SMOKE TESTS PASSED"
echo "============================================================"
