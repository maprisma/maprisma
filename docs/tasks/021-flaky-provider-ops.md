# 021 The provider ops parity test fails at random

Author: Claude · Reviewer: Antigravity · Branch: task/021-flaky-provider-ops

`tests/test_dart_provider_ops_parity.py` failed in about half the complete runs on 2026-11-01, on main too, and passed alone on 2026-11-02 morning.

## Cause (likely, not proven)
The guard before a model unload asks `generating`: are models loaded on any running local LLM, and is the GPU busy. It scans every process of the PC by name and reads the PC's GPU from sysfs. With Uwe's real llama.cpp running and the GPU busy at that moment, the core asked second refused with "in use" while the first had passed: one side `error`, the other `result`, and a `GET /models` only on one side. The failures came while llama.cpp was running; the passing runs came with it stopped.

## Fix
`MAPRISMA_SCAN_GPU` names the folder of GPU cards, in both cores; when set and no card is there, there is no GPU and nothing is busy. The parity test sets it to an empty folder. Without the variable nothing changes.

## Open
Proof needs a run with a real local LLM busy on the GPU, which this branch did not start on Uwe's PC. The process scan still sees every local LLM of the PC; with the GPU out of the question that no longer decides the result.
