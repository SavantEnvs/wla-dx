#!/usr/bin/env bash
# wla-dx/mayhem/build.sh — build the WLA-DX multi-arch assembler + linker suite, sanitized: the two
# file-input fuzz targets, and the binaries wla-dx's own functional test (mayhem/test.sh) runs.
#
# WLA-DX is a multi-architecture macro assembler (wla-z80, wla-6502, wla-65816, wla-gb, …) + a linker
# (wlalink), built with CMake. Each wla-<arch> binary PARSES an attacker-controlled assembly source
# file and assembles it to an object file — the whole front end (scanner, preprocessor, parser, macro
# expansion, phase_1..phase_4, instruction encoding) runs on the input. That's the natural fuzz surface:
# a FILE-INPUT (CLI) target `wla-<arch> -o <out.o> <asm-file>`, no libFuzzer harness. The old integration
# fuzzed `wla-z80` on a `.s` file; we preserve that target name (wla-z80) and add wla-6502.
#
# Two CMake builds, both instrumented exactly like the fuzz targets:
#   (1) FUZZ build  -> /mayhem/wla-z80, /mayhem/wla-6502  (the Mayhem targets: $SANITIZER_FLAGS + $DEBUG_FLAGS,
#                      RelWithDebInfo, the lsan_off hook)
#   (2) TEST build  -> build-tests/binaries/  (every wla-<arch> + wlalink, for mayhem/test.sh): the SAME
#                      compiler, build type, $SANITIZER_FLAGS, $DEBUG_FLAGS and lsan_off hook, plus ONLY
#                      -fsanitize-recover=undefined. At COMPILE time the two builds look identical to a
#                      source file (same macros, __has_feature results and opt level), so a patch cannot
#                      key on how it is compiled. At RUN time a patch can still tell them apart (see (2)
#                      below); that gap is not closed here.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs from the ENV, overridable. SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills
# when the var is UNSET, so an explicit EMPTY value (--build-arg SANITIZER_FLAGS=) is honored and builds
# with NO sanitizers (the assembler's natural crash). WLA-DX links libm (CMakeLists adds `m` on UNIX), so
# the empty-sanitizer build links cleanly with no extra flags.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC MAYHEM_JOBS

cd "$SRC"

# WLA-DX's CMakeLists compiles with `-pedantic-errors -Wall -Wextra -ansi` (warnings only, NOT -Werror
# unless STRICT_ANSI_WARNINGS=ON, which defaults OFF). Adding the sanitizer flags via CMAKE_C_FLAGS does
# not introduce new warnings, so -Werror is not a concern. We append our flags to CMAKE_C_FLAGS and the
# EXE linker flags so BOTH the compile and the link of the instrumented project carry the sanitizer.
# Build type RelWithDebInfo (the project default); $SANITIZER_FLAGS carries -g.

# The two Mayhem fuzz targets (preserve the old wla-z80; add wla-6502 — a second common architecture).
TARGETS=(wla-z80 wla-6502)

# ---------------------------------------------------------------------------
# LeakSanitizer OFF (both builds): wla-* are short-lived assemblers that allocate global/parse buffers
# and, on many error paths, exit without freeing (they rely on process exit to reclaim memory). LSan
# (which runs at exit, as part of ASan) would report benign "leaks" on a large fraction of inputs,
# flooding the fuzzer with spurious crashes and stopping it exploring real memory-safety defects. We
# disable ONLY leak detection (keeping ASan's heap/stack/global overflow + use-after-free and ALL of
# UBSan, still halting) with the fleet-standard BUILD-TIME switch: mayhem/lsan_off.c defines the
# __lsan_is_turned_off() hook, is compiled with $SANITIZER_FLAGS and is linked into every executable of
# both builds (CMAKE_EXE_LINKER_FLAGS), so it holds however the binary is launched. No runtime sanitizer
# option is set anywhere. (Inert when SANITIZER_FLAGS is empty: no LSan runtime.)
# ---------------------------------------------------------------------------
LSAN_OFF_OBJ="$SRC/build-lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.c" -o "$LSAN_OFF_OBJ"

# cmake_build <dir> <c-flags> [targets...] — configure + build the project in <dir> with <c-flags> on every
# compile and link (RelWithDebInfo, the project default); no targets = the whole project.
cmake_build() {
  local dir="$1" flags="$2"; shift 2
  rm -rf "$dir"
  cmake -S "$SRC" -B "$dir" \
    -DCMAKE_C_COMPILER="$CC" \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DCMAKE_C_FLAGS="$flags" \
    -DCMAKE_EXE_LINKER_FLAGS="$flags $LSAN_OFF_OBJ" >/dev/null
  if [ "$#" -gt 0 ]; then cmake --build "$dir" -j"$MAYHEM_JOBS" --target "$@"
  else cmake --build "$dir" -j"$MAYHEM_JOBS"; fi
}

# ---------------------------------------------------------------------------
# (1) FUZZ build — the PROJECT itself compiled WITH $SANITIZER_FLAGS so the fuzzed code is instrumented
#     (ASan+UBSan, halting, by default). Each wla-<arch> is a file-input Mayhem target at /mayhem/wla-<arch>.
# ---------------------------------------------------------------------------
cmake_build "$SRC/build-fuzz" "$SANITIZER_FLAGS $DEBUG_FLAGS" "${TARGETS[@]}"
for t in "${TARGETS[@]}"; do
  cp -f "$SRC/build-fuzz/binaries/$t" "/mayhem/$t"
done

# ---------------------------------------------------------------------------
# (2) TEST build — the WHOLE suite (every wla-* assembler + wlalink), because wla-dx's own regression
#     suite (tests/, run case by case by mayhem/test.sh and cross-checked against upstream run_tests.sh)
#     exercises all architectures and the linker, validating the assembled bytes with byte_tester (a
#     known-answer / golden-output oracle — a no-op patch produces wrong bytes and FAILS it).
#
#     Same flags as (1) plus ONE switch: -fsanitize-recover=undefined (UBSan reports and continues; ASan
#     is untouched and still halts). Upstream's own code trips UBSan on ordinary, valid sources — signed
#     left shifts that overflow `int` (wlalink reads 32-bit object fields as `c[0] << 24 | ...`; the
#     assemblers' hex/binary literal parsers shift an int accumulator), a signed add overflow in the
#     binary-literal parser and a negative double -> unsigned cast in wlalink — so the halting build fails
#     most cases on an unmodified tree (165 of 195 at upstream 1b3fdca0).
#     Recovering instead of aborting changes nothing a source file can observe at compile time
#     (`clang -dM -E` output is identical: same macros, __has_feature results and opt level), so the
#     oracle runs the code the graded binaries were compiled from. The FUZZ build (1) keeps every check
#     halting: those overflows stay findings there.
#
#     NOT closed: a patch can still tell the two builds apart at RUN time and behave differently in each.
#     Two examples: trigger UB in a forked child (the child dies in the halting fuzz build and carries on
#     here), or look at /proc/self/exe (these binaries live under build-tests/). Running the suite on the
#     graded halting binaries instead would not work: they abort 5 valid 6502 cases on upstream's own UB
#     (the hex/binary literal shifts at parse.c:1009-1013 and parse.c:1062), so a clean tree would fail
#     its own suite. This needs a screen outside the layer (rlenv side).
# ---------------------------------------------------------------------------
TEST_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS"
[ -z "$SANITIZER_FLAGS" ] || TEST_FLAGS="$TEST_FLAGS -fsanitize-recover=undefined"
cmake_build "$SRC/build-tests" "$TEST_FLAGS"

echo "build.sh: built the sanitized fuzz targets (/mayhem/wla-*) and the test suite (build-tests/binaries/):"
for t in "${TARGETS[@]}"; do ls -l "/mayhem/$t"; done
ls "$SRC/build-tests/binaries/"
