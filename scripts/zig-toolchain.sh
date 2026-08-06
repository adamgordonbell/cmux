#!/usr/bin/env bash
# Shared zig toolchain resolution, sourced by the scripts that shell out to zig
# (build-ghostty-cli-helper.sh, ensure-ghosttykit.sh).
#
# Two problems this exists to absorb, both from the host toolchain moving on
# while Ghostty's build.zig stayed pinned:
#
#   1. Homebrew ships a zig newer than ZIG_REQUIRED (0.16.0 vs 0.15.2), and
#      build.zig rejects it at comptime. A bare `zig` off PATH is therefore not
#      safe to use — it has to be version-checked, with a pinned local install
#      as a fallback.
#   2. zig 0.15.2 cannot link against the macOS 26 SDK at all; even a
#      hello-world comes back with every libc symbol undefined. The failure
#      lands in zig's own build runner, before any flag a caller passes can
#      apply, which rules out both `--sysroot` (applies to the user's build
#      only) and SDKROOT (not honored for sysroot selection by this version).
#      zig finds the SDK by shelling out to `xcrun --show-sdk-path`, so
#      redirecting that one probe is the only intervention early enough.
#
# Overrides: CMUX_ZIG pins the binary, CMUX_ZIG_SDKROOT pins the SDK.

ZIG_REQUIRED="${ZIG_REQUIRED:-0.15.2}"

zig_toolchain_version_ok() {
  [[ "$("$1" version 2>/dev/null || true)" == "$ZIG_REQUIRED" ]]
}

# Prints a zig binary matching ZIG_REQUIRED, or returns 1.
zig_toolchain_find() {
  if [[ -n "${CMUX_ZIG:-}" ]]; then
    if [[ -x "$CMUX_ZIG" ]] && zig_toolchain_version_ok "$CMUX_ZIG"; then
      echo "$CMUX_ZIG"
      return 0
    fi
    echo "error: CMUX_ZIG must be zig ${ZIG_REQUIRED}: $CMUX_ZIG" >&2
    return 1
  fi

  local candidate
  for candidate in \
    "/opt/homebrew/bin/zig" \
    "$(command -v zig 2>/dev/null || true)" \
    "/usr/local/bin/zig" \
    "$HOME/.local/share/zig-${ZIG_REQUIRED}/zig"
  do
    [[ -n "$candidate" && -x "$candidate" ]] || continue
    zig_toolchain_version_ok "$candidate" || continue
    echo "$candidate"
    return 0
  done
  return 1
}

# Prints the SDK zig should be pointed at, or returns 1 when the default is
# already usable. Only engages for SDK 26+, so this is inert on older hosts.
zig_toolchain_sdk() {
  if [[ -n "${CMUX_ZIG_SDKROOT:-}" ]]; then
    echo "$CMUX_ZIG_SDKROOT"
    return 0
  fi

  local default_major
  default_major="$(/usr/bin/xcrun --show-sdk-version 2>/dev/null | cut -d. -f1)"
  if [[ -n "$default_major" && "$default_major" -lt 26 ]]; then
    return 1
  fi

  local candidate
  while IFS= read -r candidate; do
    [[ -d "$candidate" ]] || continue
    echo "$candidate"
    return 0
  done < <(
    ls -d \
      /Library/Developer/CommandLineTools/SDKs/MacOSX15*.sdk \
      /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX15*.sdk \
      2>/dev/null | sort -rV
  )
  return 1
}

# Prints a temp dir holding an `xcrun` that answers SDK probes with $1 and
# passes everything else through. Caller owns the directory and removes it.
zig_toolchain_make_shim() {
  local sdk="$1" shim_dir
  shim_dir="$(mktemp -d "${TMPDIR:-/tmp}/cmux-zig-xcrun-shim.XXXXXX")"
  cat > "$shim_dir/xcrun" <<SHIM
#!/bin/bash
# Managed by scripts/zig-toolchain.sh — see the note there.
for arg in "\$@"; do
  case "\$arg" in
    --show-sdk-path) echo "$sdk"; exit 0 ;;
    --show-sdk-version) echo "$(basename "$sdk" .sdk | sed 's/^MacOSX//')"; exit 0 ;;
  esac
done
exec /usr/bin/xcrun "\$@"
SHIM
  chmod +x "$shim_dir/xcrun"
  echo "$shim_dir"
}
