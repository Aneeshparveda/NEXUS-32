# NEXUS-32 documentation index

This directory contains the project contract, implementation notes, evidence
receipts, and current-status boundaries. The contract is normative where noted;
the remaining documents are explanatory or evidentiary and must not override it.

| Document | Normative role |
|---|---|
| [`README.md`](README.md) | Documentation index for the project's contract, implementation notes, evidence receipts, and status boundaries. |
| [`ACCELERATOR_CONTRACT_V1.md`](ACCELERATOR_CONTRACT_V1.md) | Normative accelerator behavior, CSR semantics, memory protection, timing definitions, and evidence levels. |
| [`ACCEL_ARCH_INTEGRATION.md`](ACCEL_ARCH_INTEGRATION.md) | Integration milestone notes for the runtime architecture selector and serialized shell; explanatory, not a replacement for the contract. |
| [`ARCH_SELECTOR.md`](ARCH_SELECTOR.md) | Selector interface, architecture encodings, and selector-level verification notes; explanatory implementation guidance. |
| [`PARALLEL_ENGINE.md`](PARALLEL_ENGINE.md) | Parallel-engine implementation and validation notes; explanatory and subject to the contract. |
| [`PICORV32_PIN.md`](PICORV32_PIN.md) | PicoRV32 provisioning, pinned-source provenance, and CPU integration boundary. |
| [`PIPELINED_ENGINE.md`](PIPELINED_ENGINE.md) | Pipelined-engine behavior, ready/valid notes, and validation boundaries; explanatory and subject to the contract. |
| [`STATUS.md`](STATUS.md) | Current evidence, release status, and explicit simulation-versus-hardware boundaries. |
| [`THREE_WAY_DIFFERENTIAL.md`](THREE_WAY_DIFFERENTIAL.md) | Three-engine differential regression procedure and expected simulation evidence. |
| [`VERIFICATION_CLOSURE.md`](VERIFICATION_CLOSURE.md) | Durable simulation closure receipt, reproduction commands, matrices, and provenance boundaries. |
