#!/usr/bin/env bash
# wla-dx/mayhem/test.sh — RUN wla-dx's OWN regression suite (tests/<arch>/<case>/, the cases upstream's
# run_tests.sh drives) against the binaries mayhem/build.sh produced → CTRF with ONE result per case.
# PATCH-grade oracle: it never compiles the assemblers (build.sh already did). byte_tester (the suite's
# own tiny checker, not agent-editable) is built here exactly as run_tests.sh builds it.
#
# Each case's `make` assembles its sources with `wla-<arch>`, links with `wlalink`, and `byte_tester`
# DIFFs the produced bytes against the expected values in the case's testsfile (or the expectations in
# its source). This is a KNOWN-ANSWER / golden-output suite: it asserts the assembler emits the EXACT
# expected machine code, not merely that it exits 0. A no-op / exit(0) "patch" produces empty/wrong
# object bytes and FAILS byte_tester, so it cannot reward-hack this oracle.
#
# The programs under test are built like the graded binaries: build.sh's TEST build compiles every
# wla-* assembler and wlalink with the fuzz targets' exact compiler, build type, $SANITIZER_FLAGS,
# $DEBUG_FLAGS and lsan_off hook, adding only -fsanitize-recover=undefined (upstream's own benign UB —
# signed-shift overflows above all — would otherwise abort most cases on a clean tree; ASan still
# halts). So a patch that keys on a COMPILE-time property of the fuzz build
# (__has_feature(address_sanitizer), __OPTIMIZE__, NDEBUG, …) changes what this suite runs too.
# RUN-time keys are NOT covered: a probe that tells halting UBSan from recovering UBSan (UB in a forked
# child), or a gate on the binary's path (/proc/self/exe, argv[0]), the input path, the cwd or the
# environment, lets patched code behave one way in the fuzz binary / PoV replay and another way here.
# This suite cannot rule those out (see build.sh, section (2)).
#
# Why per case: upstream run_tests.sh `exit 1`s at the FIRST failing case and prints `OK (N tests)` only
# after a full pass, so it cannot give a pass/fail split — reporting it as one result would turn a
# single broken case out of ~195 into "0 passed", and the grader prices functionality loss from the
# passed count. So this script walks the same cases with the same rules as run_tests.sh's loop (every
# tests/<platform>/<case>/ with a `makefile`, skipping case dirs that start with `_`; the same
# `make clean; make; byte_tester testsfile; make clean` chain; WLAVALGRIND= as with NO_VALGRIND=1) and
# counts every case. Then it runs the UNMODIFIED upstream run_tests.sh as a cross-check: when upstream
# reports `OK (N tests)` the per-case enumeration must be exactly N with no failure, and when upstream
# fails the per-case run must have found a failure too. Any disagreement adds one failing
# "run_tests.sh cross-check" result (fail closed) — so a future upstream change to the suite's skip/count
# rules breaks the commit-image build instead of silently drifting.
#
# The verdict is checked against the COMMITTED tree, not against git's index or files the programs under
# test may have rewritten. Before any program under test runs, this script reads into memory: the case
# list, which cases carry a testsfile, and the blob id of every committed file under tests/, byte_tester/
# and run_tests.sh (all from HEAD's tree), plus the content hash of every file under include/ and
# memorymaps/ (product headers that 26 cases read through ../../../ paths; the agent's patch may edit
# them, so they are taken as they are when this script starts). tests/, byte_tester/ and run_tests.sh must match
# HEAD at that point, else every case fails. After each case: every one of those files must still hash
# to its recorded id (`git hash-object --no-filters`, run outside the repository, so no index, stat cache
# or repo config is consulted); nothing may have been added or removed under include/ or memorymaps/;
# binaries/byte_tester must be byte-identical to the one built at the start; and a passing case must not
# have left extra files under tests/. A changed, missing or replaced file fails that case and every later
# one. Extra files under tests/ (a stray GNUmakefile, a failed case's objects) are deleted before the
# next case without asking git.
# This catches plain edits and index tricks (`git update-index --assume-unchanged` or `--skip-worktree`,
# a planted file added to the index). It is NOT a guarantee. The programs under test run as the runner,
# which can write the whole tree, .git included, so same-uid code can still change a file only while
# byte_tester reads it and put it back before the after-case check (for example from a background
# process), or change inputs this script does not track.
#
# No per-case timeout: the whole suite runs in seconds, and the upstream cross-check has none either, so a
# hanging case is left to the grader's own test.sh deadline.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

TOOL="wla-dx-tests"
CASE_NAMES=()   # "<platform>/<case>" in run order
CASE_STATUS=()  # passed | failed
CASE_MS=()      # wall time per case, ms

# add_result <name> <passed|failed> <duration-ms>
add_result() { CASE_NAMES+=("$1"); CASE_STATUS+=("$2"); CASE_MS+=("$3"); }

json_str() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "$s" | tr -d '\000-\037'; }

now_ms() { local ns; ns=$(date +%s%N); printf '%s' $(( ns / 1000000 )); }

# emit_ctrf — writes the CTRF report (summary + one entry per recorded result) to
# ${CTRF_REPORT:-$SRC/ctrf-report.json} plus a compact `CTRF {...}` summary marker on stdout, and returns
# non-zero iff failed>0.
emit_ctrf() {
  local passed=0 failed=0 i n="${#CASE_NAMES[@]}" sep=""
  for (( i = 0; i < n; i++ )); do
    if [ "${CASE_STATUS[$i]}" = passed ]; then passed=$(( passed + 1 )); else failed=$(( failed + 1 )); fi
  done
  local tests=$(( passed + failed ))
  {
    printf '{\n  "results": {\n    "tool": { "name": "%s" },\n' "$TOOL"
    printf '    "summary": {\n      "tests": %d,\n      "passed": %d,\n      "failed": %d,\n' "$tests" "$passed" "$failed"
    printf '      "pending": 0,\n      "skipped": 0,\n      "other": 0\n    },\n    "tests": ['
    for (( i = 0; i < n; i++ )); do
      printf '%s\n      { "name": "%s", "status": "%s", "duration": %d }' \
        "$sep" "$(json_str "${CASE_NAMES[$i]}")" "${CASE_STATUS[$i]}" "${CASE_MS[$i]}"
      sep=","
    done
    printf '\n    ]\n  }\n}\n'
  } > "${CTRF_REPORT:-$SRC/ctrf-report.json}"
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":0,"skipped":0,"other":0}}}\n' \
    "$TOOL" "$tests" "$passed" "$failed"
  [ "$failed" -eq 0 ]
}

# fail_all <reason> — record every enumerated case as failed (nothing trustworthy can be run) and exit.
fail_all() {
  local c
  echo "FAIL: $1" >&2
  if [ "${#CASES[@]}" -eq 0 ]; then add_result "suite setup" failed 0; fi
  for c in "${CASES[@]}"; do add_result "$c" failed 0; done
  emit_ctrf
  exit 1
}

# git runs as whatever identity runs this script (the grader's runner does not own the tree), so trust
# this one repository through the environment instead of writing any git config.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0="$SRC"

# ---- what the verdict is checked against, read before any program under test runs ----------------
# The case list follows run_tests.sh's walk: tests/<platform>/<case>/ (non-hidden dirs) with a
# `makefile`, skipping case dirs whose name starts with `_`. It is read from HEAD's tree, so files
# written after checkout cannot add, remove or reshape a case. The same listing records every committed
# file under tests/, byte_tester/ and run_tests.sh with its blob id (HASH_PATHS / HASH_WANT) and every
# entry tests/ should hold (IN_TESTS).
CASES=()
declare -A HAS_TESTSFILE=() IN_TESTS=(["d tests"]=1)
HASH_PATHS=() HASH_WANT=()
bad_entry=""
REF_TREE=$(git rev-parse --verify -q 'HEAD^{tree}') || fail_all "cannot resolve HEAD in $SRC (test.sh needs the repo's .git)"
while IFS= read -r -d '' rec; do
  meta=${rec%%$'\t'*}; p=${rec#*$'\t'}
  case "$meta" in "100644 blob "*|"100755 blob "*) ;; *) bad_entry="unsupported entry in HEAD's tree: $p ($meta)" ;; esac
  case "$p" in *$'\n'*) bad_entry="a committed path contains a newline"; continue ;; esac
  HASH_PATHS+=("$SRC/$p"); HASH_WANT+=("${meta##* }")
  case "$p" in tests/*)
    IN_TESTS["f $p"]=1; a=${p%/*}
    while [ "$a" != tests ] && [ -z "${IN_TESTS["d $a"]:-}" ]; do IN_TESTS["d $a"]=1; a=${a%/*}; done ;;
  esac
  case "$p" in
    tests/*/*/makefile) c="${p#tests/}"; c="${c%/makefile}" ;;
    tests/*/*/testsfile) c="${p#tests/}"; HAS_TESTSFILE["${c%/testsfile}"]=1; continue ;;
    *) continue ;;
  esac
  case "$c" in */*/*|.*|*/.*|*/_*) continue ;; esac
  CASES+=("$c")
done < <(git ls-tree -r -z "$REF_TREE" -- tests/ byte_tester/ run_tests.sh)
mapfile -t CASES < <(printf '%s\n' "${CASES[@]}" | LC_ALL=C sort)
[ "${#CASES[@]}" -gt 0 ] || fail_all "no test cases found under tests/ in HEAD"
echo "suite: ${#CASES[@]} cases from HEAD tree ${REF_TREE:0:12}"
[ -z "$bad_entry" ] || fail_all "$bad_entry"

# hash_files <abs-path>... — the git blob id of each file's raw content, one per line. Run from / with
# --no-filters: no index, stat cache, attributes, repository or user git config is consulted.
hash_files() {
  [ "$#" -gt 0 ] || return 0
  ( cd / && printf '%s\n' "$@" | GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git hash-object --no-filters --stdin-paths ) 2>/dev/null
}

# include/ and memorymaps/ (product headers that 26 cases read through ../../../ paths) are not the
# agent-proof part of the tree — its patch may edit them in place — so they are recorded as they are now.
LIST_ROOTS=(tests)
PROD_FILES=()
for r in include memorymaps; do [ -d "$r" ] && [ ! -L "$r" ] && LIST_ROOTS+=("$r"); done
while IFS= read -r -d '' p; do
  case "$p" in tests/*) continue ;; *$'\n'*) fail_all "a path under include/ or memorymaps/ contains a newline" ;; esac
  PROD_FILES+=("$SRC/$p")
done < <(find "${LIST_ROOTS[@]}" -type f -print0 | LC_ALL=C sort -z)
if [ "${#PROD_FILES[@]}" -gt 0 ]; then
  mapfile -t prod_want < <(hash_files "${PROD_FILES[@]}")
  [ "${#prod_want[@]}" -eq "${#PROD_FILES[@]}" ] || fail_all "could not hash include/ and memorymaps/"
  HASH_PATHS+=("${PROD_FILES[@]}"); HASH_WANT+=("${prod_want[@]}")
fi
HASH_WANT_STR=$(printf '%s\n' "${HASH_WANT[@]}")
# list_now — every entry under tests/, include/ and memorymaps/ as "<type> <path>", sorted.
list_now() { find "${LIST_ROOTS[@]}" -printf '%y %p\n' 2>/dev/null | LC_ALL=C sort; }
LIST_WANT=$( { printf '%s\n' "${!IN_TESTS[@]}"; list_now | grep -v '^. tests\(/\|$\)'; } | LC_ALL=C sort)

# tree_state — 0: every recorded file still hashes to its recorded id, byte_tester (once built) is
# unchanged, and tests/, include/ and memorymaps/ hold exactly the recorded entries; 1: the same except
# for extra entries under tests/; 2: anything else (a recorded file changed, missing or replaced by
# another type, an entry added under include/ or memorymaps/, byte_tester changed).
tree_state() {
  local now extra=0
  now=$(list_now)
  if [ "$now" != "$LIST_WANT" ]; then
    [ -z "$(LC_ALL=C comm -23 <(printf '%s\n' "$LIST_WANT") <(printf '%s\n' "$now"))" ] || return 2
    LC_ALL=C comm -13 <(printf '%s\n' "$LIST_WANT") <(printf '%s\n' "$now") | grep -qv '^. tests/' && return 2
    extra=1
  fi
  [ -z "${BT_SHA:-}" ] || [ "$(sha256sum < "$BT" 2>/dev/null)" = "$BT_SHA" ] || return 2
  [ "$(hash_files "${HASH_PATHS[@]}")" = "$HASH_WANT_STR" ] || return 2
  return "$extra"
}

# scrub_tests — delete every entry under tests/ that HEAD's tree does not have there, without asking
# git (an entry added to the index is still deleted).
scrub_tests() {
  local rec
  while IFS= read -r -d '' rec; do
    [ -n "${IN_TESTS[$rec]:-}" ] || rm -rf -- "${rec#? }"
  done < <(find tests -mindepth 1 -depth -printf '%y %p\0' 2>/dev/null)
}

# The checker, the upstream runner and the cases must be the committed ones before anything runs.
git clean -ffdxq -- byte_tester >/dev/null 2>&1   # byte_tester's own build leftovers
scrub_tests
tree_state || fail_all "tests/, byte_tester/ or run_tests.sh differs from the committed tree"

# ---- the programs under test -----------------------------------------------------------------------
# build.sh built every wla-* + wlalink into build-tests/binaries (graded flags + UBSan recover). Stage
# them at $SRC/binaries, the PATH entry run_tests.sh adds. (binaries/ is upstream's own output dir: its
# tracked .gitignore ignores everything else in it, so `git clean -x` empties it while keeping that file.)
[ -d "$SRC/build-tests/binaries" ] || fail_all "missing build-tests/binaries — run mayhem/build.sh first"
mkdir -p "$SRC/binaries"
git clean -ffdxq -- binaries >/dev/null 2>&1
staged=0
for f in "$SRC"/build-tests/binaries/*; do
  [ -f "$f" ] && [ -x "$f" ] || continue
  ln -sfn "$f" "$SRC/binaries/$(basename "$f")" && staged=$(( staged + 1 ))
done
[ -x "$SRC/binaries/wlalink" ] && [ "$staged" -gt 1 ] || fail_all "could not stage the built wla-* / wlalink into $SRC/binaries"
export PATH="$PATH:$SRC/binaries"
export WLAVALGRIND=   # what run_tests.sh sets for NO_VALGRIND=1 (valgrind is not what we test here)

# byte_tester — built exactly as run_tests.sh builds it (`make install` copies it into ../binaries), from
# the committed byte_tester/ checked above. This script's own `byte_tester testsfile` step runs it by
# this absolute path, which is also where PATH resolves `byte_tester` for run_tests.sh and for the 161
# case makefiles that call it themselves.
BT="$SRC/binaries/byte_tester"
if ! bt_out=$( { cd "$SRC/byte_tester" && make install; } 2>&1 ) || [ ! -x "$BT" ] \
   || [ "$(command -v byte_tester)" != "$BT" ]; then
  printf '%s\n' "$bt_out" | tail -20
  fail_all "byte_tester could not be built — the suite cannot run"
fi
BT_SHA=$(sha256sum < "$BT")

# ---- per-case run -----------------------------------------------------------------------------------
# The same walk, skip rules and command chain as run_tests.sh's loop, but every case is counted instead of
# stopping at the first failure. The whole chain's stdout+stderr is captured so a failing case's
# diagnostics are shown. tree_state runs after every case (see the header for the rules).
tainted=""     # set once a recorded file or byte_tester changed: every later case fails
need_scrub=""  # the last case left extra entries under tests/
for c in "${CASES[@]}"; do
  d="tests/$c"
  t0=$(now_ms)
  why="" out=""
  if [ -z "$tainted" ] && [ -n "$need_scrub" ]; then
    scrub_tests; need_scrub=""
    tree_state || tainted="tests/ could not be brought back to the committed entries"
  fi
  if [ -n "$tainted" ]; then
    why="$tainted"
  else
    if out=$( { cd "$SRC/$d" && make clean && make \
                && { [ -z "${HAS_TESTSFILE[$c]:-}" ] || "$BT" testsfile; } && make clean; } 2>&1 ); then
      rc=0
    else
      rc=1
    fi
    tree_state; st=$?
    if [ "$st" -eq 2 ]; then
      why="the run changed a committed file, include/, memorymaps/ or byte_tester"
      tainted="an earlier case changed a committed file, include/, memorymaps/ or byte_tester"
    elif [ "$rc" -ne 0 ]; then
      why="make / byte_tester failed"
    elif [ "$st" -eq 1 ]; then
      why="the run left entries under tests/ that the committed tree does not have"
    fi
    [ "$st" -eq 0 ] || need_scrub=1
  fi
  if [ -z "$why" ]; then
    add_result "$c" passed $(( $(now_ms) - t0 ))
  else
    add_result "$c" failed $(( $(now_ms) - t0 ))
    echo "FAIL: $c ($why)"
    [ -z "$out" ] || printf '%s\n' "$out" | tail -15 | sed 's/^/    /'
  fi
done
enumerated=${#CASE_NAMES[@]}
case_failed=0
for s in "${CASE_STATUS[@]}"; do [ "$s" = passed ] || case_failed=$(( case_failed + 1 )); done
echo "per-case: $(( enumerated - case_failed )) passed, $case_failed failed, $enumerated cases"

# ---- cross-check with the UNMODIFIED upstream runner (same binaries, same NO_VALGRIND mode) ----------
xout="$(NO_VALGRIND=1 sh "$SRC/run_tests.sh" 2>&1)"; xrc=$?
xtotal=$(printf '%s\n' "$xout" | sed -n 's/^OK (\([0-9][0-9]*\) tests)$/\1/p' | tail -1)
xfail=$(printf '%s\n' "$xout" | sed -n 's/^Test "\(.*\)\/" of platform "\(.*\)\/" failed\.$/\2\/\1/p' | tail -1)
xproblem=""
if [ "$xrc" -eq 0 ]; then
  if [ -z "$xtotal" ]; then
    xproblem="run_tests.sh exited 0 without an 'OK (N tests)' summary"
  elif [ "$xtotal" -ne "$enumerated" ]; then
    xproblem="run_tests.sh counted $xtotal cases but the per-case walk enumerated $enumerated (skip/count rules drifted)"
  elif [ "$case_failed" -gt 0 ]; then
    echo "note: run_tests.sh passed all $xtotal cases but the per-case run failed $case_failed (reported as failures)"
  else
    echo "cross-check: run_tests.sh OK ($xtotal tests) == per-case $enumerated passed"
  fi
else
  if [ "$case_failed" -eq 0 ]; then
    xproblem="run_tests.sh failed (rc=$xrc${xfail:+, at $xfail}) but the per-case run saw no failure"
  else
    echo "cross-check: run_tests.sh failed too (rc=$xrc${xfail:+, first failing case $xfail})"
  fi
fi
if [ -n "$xproblem" ]; then
  printf '%s\n' "$xout" | tail -25 | sed 's/^/    /'
  echo "FAIL: run_tests.sh cross-check — $xproblem" >&2
  add_result "run_tests.sh cross-check" failed 0
fi

emit_ctrf
exit $?
