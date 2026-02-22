#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail() {
  echo "[FAIL] $1" >&2
  exit 1
}

pass() {
  echo "[PASS] $1"
}

submodule_sha="$(git submodule status melonDS | awk '{print $1}' | sed 's/^[-+]//')"
expected_sha="b86390e4428bf38ce4c1ce0e9ca446d6d25955e8"
[[ "$submodule_sha" == "$expected_sha" ]] || fail "melonDS submodule is not at v1.1 tag commit"
pass "melonDS submodule pinned to 1.1 (${submodule_sha:0:8})"

rg -n 'MELONDS_VERSION=\\"1.1\\"' MelonDSDeltaCore.podspec >/dev/null || fail "podspec MELONDS_VERSION define not set to 1.1"
pass "podspec MELONDS_VERSION define is 1.1"

rg -n 'public var version: String\? \{ "1.1" \}' MelonDSDeltaCore/MelonDS.swift >/dev/null || fail "Swift core version is not 1.1"
pass "Swift core version is 1.1"

rg -n 'namespace melonDS::Platform' MelonDSDeltaCore/Bridge/MelonDSEmulatorBridge.mm >/dev/null || fail "Bridge Platform namespace not migrated"
pass "Bridge namespace is melonDS::Platform"

for sym in 'SignalStop\(' 'OpenFile\(const std::string& path, FileMode mode\)' 'Semaphore_TryWait\(' 'GetMSCount\(' 'MP_SendPacket\(u8\* data, int len, u64 timestamp, void\* userdata\)' 'Net_SendPacket\(u8\* data, int len, void\* userdata\)' 'Mic_Start\(void\* userdata\)' ; do
  rg -n "$sym" MelonDSDeltaCore/Bridge/MelonDSEmulatorBridge.mm >/dev/null || fail "Missing required symbol: $sym"
done
pass "Bridge implements key 1.1 Platform callback signatures"
