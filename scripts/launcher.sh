#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
launcher="$root/skills/package-agent-network-doks-green/green"
grep -q 'io.github.getcolors.agent-network-doks.workflow/workflow' "$launcher"
grep -q 'def \^:private agent-network-doks-sha' "$launcher"
[[ -L "$root/green/green" ]] && [[ $(readlink "$root/green/green") == ../skills/package-agent-network-doks-green/green ]]
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cp "$launcher" "$tmp/green"; chmod +x "$tmp/green"
sed "s#WORKDIR#.colors#" "$root/test/fixtures/colors.yml" > "$tmp/colors.yml"
(cd "$tmp" && AGENT_NETWORK_DOKS_LIB_ROOT="$root" ./green build >/dev/null)
[[ -f "$tmp/.colors/agent-network-doks-fixture/agent-network-doks-infrastructure/main.tf" ]]
[[ -f "$tmp/.colors/agent-network-doks-fixture/agent-network-doks-infrastructure/registry.tf" ]]
[[ -f "$tmp/.colors/agent-network-doks-fixture/agent-network-doks-deploy/converge.sh" ]]
[[ -f "$tmp/.colors/agent-network-doks-fixture/agent-network-doks-deploy/manifests/networkpolicies.yaml" ]]
# The launcher walks up for colors.yml, so any subdirectory works.
mkdir -p "$tmp/nested/path"
(cd "$tmp/nested/path" && AGENT_NETWORK_DOKS_LIB_ROOT="$root" ../../green build >/dev/null)
# The profile guard is the whole reason COLORS_PAR_PROFILE is refused: an
# overlay would point one deployment at another's state.
out=$(cd "$tmp" && AGENT_NETWORK_DOKS_LIB_ROOT="$root" COLORS_PAR_PROFILE=wrong ./green build 2>&1 || true)
grep -q COLORS_PAR_PROFILE <<<"$out"
[[ ! -d "$tmp/.colors/wrong" ]]
# While unpinned, a standalone copy refuses with an actionable message.
if grep -q '(def \^:private agent-network-doks-sha nil)' "$launcher"; then
  mkdir -p "$tmp/bare"; cp "$launcher" "$tmp/bare/green"; chmod +x "$tmp/bare/green"
  sed "s#WORKDIR#.colors#" "$root/test/fixtures/colors.yml" > "$tmp/bare/colors.yml"
  out=$( (cd "$tmp/bare" && ./green build 2>&1) || true )
  grep -q 'AGENT_NETWORK_DOKS_LIB_ROOT' <<<"$out"
fi
echo 'launcher: all checks passed'
