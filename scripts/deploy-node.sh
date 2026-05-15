#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./automation-common.sh
source "${SCRIPT_DIR}/automation-common.sh"

parse_args "$@"
load_env
prepare_compose

note "Running preflight before deploy"
run_preflight

note "Deploying ${ROLE}"
compose_role up -d --build

note "Current container state"
compose_role ps

note "Deployment completed"

