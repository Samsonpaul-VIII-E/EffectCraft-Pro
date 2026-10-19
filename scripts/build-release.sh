#!/usr/bin/env bash

# Fail on command errors, undefined variables, and pipeline failures.
set -euo pipefail

# Predictable word splitting and glob behavior.
IFS=$'\n\t'

# Resolve the repository root independently of the caller's working directory.
ROOT_DIR="$(
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &&
  pwd -P
)"

cd "$ROOT_DIR"

# These values can be supplied by the GitHub Actions workflow.
BUILD_OUTPUT_DIR="${BUILD_OUTPUT_DIR:-build}"
BILLIXI_ARTIFACT_PATH="${BILLIXI_ARTIFACT_PATH:-dist/my-product.zip}"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

# Resolve absolute and repository-relative paths without requiring the
# target file or directory to exist yet. The release build runs on Ubuntu.
resolve_path() {
  local requested_path="$1"

  if [[ "$requested_path" == /* ]]; then
    realpath -m -- "$requested_path"
  else
    realpath -m -- "$ROOT_DIR/$requested_path"
  fi
}

BUILD_OUTPUT_ABS="$(resolve_path "$BUILD_OUTPUT_DIR")"
ARTIFACT_ABS="$(resolve_path "$BILLIXI_ARTIFACT_PATH")"

# ------------------------------------------------------------
# 1. Validate paths before deleting or writing any files.
# ------------------------------------------------------------

# Both paths must remain inside the checkout. This guards against a
# misconfigured path deleting or packaging data outside the repository.
case "$BUILD_OUTPUT_ABS" in
  "$ROOT_DIR"/*) ;;
  *) die "BUILD_OUTPUT_DIR must resolve inside the repository: $BUILD_OUTPUT_ABS" ;;
esac

case "$ARTIFACT_ABS" in
  "$ROOT_DIR"/*) ;;
  *) die "BILLIXI_ARTIFACT_PATH must resolve inside the repository: $ARTIFACT_ABS" ;;
esac

# Never allow the output directory itself to be treated as the build target.
[[ "$BUILD_OUTPUT_ABS" != "$ROOT_DIR" ]] ||
  die "BUILD_OUTPUT_DIR cannot be the repository root."

[[ "$ARTIFACT_ABS" == *.zip ]] ||
  die "BILLIXI_ARTIFACT_PATH must end in .zip."

# Prevent the archive from being written inside the directory that is
# about to be packaged; otherwise, the archive could contain itself.
if [[ "$ARTIFACT_ABS" == "$BUILD_OUTPUT_ABS" ||
      "$ARTIFACT_ABS" == "$BUILD_OUTPUT_ABS/"* ||
      "$BUILD_OUTPUT_ABS" == "$ARTIFACT_ABS/"* ]]; then
  die "The archive path and build output directory must not overlap."
fi

# Refuse a symlink at the final output-directory path rather than
# accidentally removing a linked target during cleanup.
[[ ! -L "$BUILD_OUTPUT_ABS" ]] ||
  die "BUILD_OUTPUT_DIR must not be a symbolic link."

# ------------------------------------------------------------
# 2. Project-specific build function.
#
# Replace this function with the commands required by your project.
# Keep commands explicit instead of evaluating a shell command string.
#
# This example assumes:
#   - package.json and package-lock.json exist
#   - npm ci installs pinned dependencies
#   - npm run build writes the finished output to build/
#
# Examples for other projects:
#   - Rust: cargo build --release, then copy the desired outputs to build/
#   - Go: go build ..., then place the release binaries in build/
#   - Python: build a wheel or bundle and stage it in build/
#
# If your compiler emits to another directory, also update
# BUILD_OUTPUT_DIR in the workflow.
# ------------------------------------------------------------

build_project() {
  echo "Installing locked dependencies and compiling the project..."

  npm ci
  npm run build
}

# ------------------------------------------------------------
# 3. Clean the designated output directory before compilation.
#
# This prevents stale files from a previous build from being included
# in the release archive. The path has already been constrained above.
# ------------------------------------------------------------

rm -rf -- "$BUILD_OUTPUT_ABS"
mkdir -p -- "$BUILD_OUTPUT_ABS"

# Prepare the destination directory for the ZIP archive.
mkdir -p -- "$(dirname -- "$ARTIFACT_ABS")"

# ------------------------------------------------------------
# 4. Compile the project.
# ------------------------------------------------------------

build_project

# ------------------------------------------------------------
# 5. Validate the build output before packaging.
# ------------------------------------------------------------

[[ -d "$BUILD_OUTPUT_ABS" ]] ||
  die "The build command did not create $BUILD_OUTPUT_ABS."

first_entry="$(
  find "$BUILD_OUTPUT_ABS" -mindepth 1 -print -quit
)"

[[ -n "$first_entry" ]] ||
  die "Build output is empty; refusing to create an empty release."

command -v zip >/dev/null 2>&1 ||
  die "The zip utility is required but was not found."

# ------------------------------------------------------------
# 6. Create the release ZIP.
#
# A temporary archive is created beside the final artifact. Only after
# ZIP creation and integrity testing succeed is it moved into place.
# ------------------------------------------------------------

tmp_dir=""

cleanup() {
  if [[ -n "$tmp_dir" && -d "$tmp_dir" ]]; then
    rm -rf -- "$tmp_dir"
  fi
}

trap cleanup EXIT

tmp_dir="$(
  mktemp -d -- "$(dirname -- "$ARTIFACT_ABS")/.release-tmp.XXXXXX"
)"

tmp_archive="$tmp_dir/$(basename -- "$ARTIFACT_ABS")"

echo "Packaging $BUILD_OUTPUT_ABS into a ZIP archive..."

# Run from inside the build directory so archive entries use relative
# paths and don't contain the absolute path of the GitHub runner.
(
  cd -- "$BUILD_OUTPUT_ABS"
  zip -qr -T "$tmp_archive" .
)

[[ -s "$tmp_archive" ]] ||
  die "ZIP creation failed or produced an empty archive."

# Atomic replacement prevents consumers from seeing a partly written ZIP.
mv -f -- "$tmp_archive" "$ARTIFACT_ABS"

[[ -s "$ARTIFACT_ABS" ]] ||
  die "Final archive is missing or empty."

echo "Release archive created: $ARTIFACT_ABS"

# Print the checksum for local diagnostics. The publication job recomputes
# the digest independently after the artifact has crossed the job boundary.
sha256sum -- "$ARTIFACT_ABS"
