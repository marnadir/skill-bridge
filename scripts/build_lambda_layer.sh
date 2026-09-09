#!/usr/bin/env bash
# Builds the shared python dependencies layer for the lambdas.
# Must run BEFORE terraform plan/apply (locally and in CI): the
# archive_file data source zips the directory produced here.
# Wheels are pulled for the lambda platform (manylinux x86_64,
# python 3.13), NOT for the machine running the script.
set -euo pipefail

TARGET="$(cd "$(dirname "$0")/.." && pwd)/infra/terraform/envs/dev/.terraform/tmp/layer/python"

rm -rf "$TARGET"
mkdir -p "$TARGET"

# --no-compile: .pyc files embed build-machine paths/mtimes and would
# make the layer hash non-deterministic across machines (endless
# layer republishing between CI and local plans)
python3 -m pip install --quiet --upgrade --no-compile \
  --target "$TARGET" \
  --platform manylinux2014_x86_64 \
  --implementation cp \
  --python-version 3.13 \
  --only-binary=:all: \
  "pydantic==2.12.*" "strands-agents==1.55.*"

echo "lambda layer built at $TARGET"
