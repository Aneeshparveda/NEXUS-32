FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install --no-install-recommends -y \
        binutils-riscv64-unknown-elf \
        ca-certificates \
        file \
        gcc-riscv64-unknown-elf \
        git \
        iverilog \
         make \
         python3 \
         tcl \
         verilator \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/nexus32
COPY . .

ENV RISCV_CC=riscv64-unknown-elf-gcc \
    RISCV_OBJCOPY=riscv64-unknown-elf-objcopy \
    PYTHONDONTWRITEBYTECODE=1

# This is the only network-dependent project step.  It checks out the exact
# PicoRV32 revision and builds all firmware images before the image is used
# offline by the default command below.
RUN make setup

CMD ["make", "test"]
