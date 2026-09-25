#!/bin/bash
# check-tests-ran.sh — refuse a "green" test run that executed no tests.
#
# Usage:  ./.github/check-tests-ran.sh <test-log>
#         ./.github/check-tests-ran.sh --selftest
#
# WHY THIS EXISTS — task #750. MEASURED 2026-09-12 in this repository: a bare
# `swift test` printed "error: Build failed" after a codesign rejection and the
# session read the run as green, with ZERO tests executed. A green signal over
# zero executed tests is the strongest form of absence-indistinguishable-from-
# success, because it is the instrument everything else is checked with.
#
# RE-MEASURED 2026-09-25 (task #750) against the vendor's source. SwiftPM's
# swiftbuild path (Sources/SwiftBuildSupport/SwiftBuildSystem.swift,
# startSWBuildOperation) does `case .failed: emit(error: "Build failed");
# throw Diagnostics.fatalError`, and `swift test` exits 1 on that throw under
# Xcode 27.2, the Command Line Tools, swiftbuild and --build-system native
# alike. The exit code is honest when it is READ. The failure mode is that a
# pipeline (`swift test 2>&1 | tee log`) without `set -o pipefail` reports the
# exit status of `tee`, and a session that reads "$?" after that reads 0. So
# this guard does not trust the exit code at all: it reads the log and requires
# positive proof that tests ran.
#
# It accepts either summary the toolchain prints and requires at least one:
#   swift-testing:  "Test run with N tests in M suites passed after 1.2 seconds."
#   XCTest:         "Executed N tests, with F failures (U unexpected) in 1.2 (1.3) seconds"
# and refuses on: a build failure marker, "No matching test cases were run",
# a failed summary, a zero count, or no summary at all.
#
# RUN --selftest BEFORE TRUSTING IT. A check that has only ever passed is not
# a check; the selftest plants each refusal case and requires it to refuse.
set -u

refuse() { echo "::error::$1"; exit 1; }

check() {
  local log="$1"
  [ -s "$log" ] || refuse "test log '$log' is missing or empty — nothing proves a test ran"

  if grep -qE '^error: (Build failed|fatalError)' "$log"; then
    refuse "the test log records a BUILD FAILURE; no test result in it can be trusted"
  fi
  if grep -q 'No matching test cases were run' "$log"; then
    refuse "SwiftPM reports no matching test cases were run"
  fi

  local st_total=0 st_failed=0 n
  # swift-testing: one summary per test product. Sum them.
  while read -r n; do st_total=$((st_total + n)); done < <(
    grep -oE 'Test run with [0-9]+ tests? in [0-9]+ suites? (passed|failed)' "$log" \
      | sed -E 's/Test run with ([0-9]+) .*/\1/')
  st_failed=$(grep -cE 'Test run with [0-9]+ tests? in [0-9]+ suites? failed' "$log" || true)

  # XCTest: per-suite lines then an "All tests" total. Take the largest.
  local xc_total=0 xc_failures=0
  while read -r n; do [ "$n" -gt "$xc_total" ] && xc_total=$n; done < <(
    grep -oE 'Executed [0-9]+ tests?, with [0-9]+ failures?' "$log" \
      | sed -E 's/Executed ([0-9]+) .*/\1/')
  while read -r n; do [ "$n" -gt "$xc_failures" ] && xc_failures=$n; done < <(
    grep -oE 'Executed [0-9]+ tests?, with [0-9]+ failures?' "$log" \
      | sed -E 's/.*with ([0-9]+) .*/\1/')

  local total=$((st_total + xc_total))
  if ! grep -qE 'Test run with [0-9]+ tests?|Executed [0-9]+ tests?' "$log"; then
    refuse "no test summary line in the log — the run never reached the test phase"
  fi
  [ "$st_failed" = "0" ] || refuse "a swift-testing run reports failed"
  [ "$xc_failures" = "0" ] || refuse "XCTest reports $xc_failures failures"
  [ "$total" -gt 0 ] || refuse "Executed 0 tests — a run that executes no tests is not green"
  echo "tests ran: $total (swift-testing $st_total, XCTest $xc_total)"
}

selftest() {
  local dir; dir=$(mktemp -d); local fails=0
  expect() { # expect <pass|fail> <name> <content>
    local want="$1" name="$2"; printf '%b' "$3" > "$dir/$name.log"
    if "$0" "$dir/$name.log" > "$dir/$name.out" 2>&1; then got=pass; else got=fail; fi
    if [ "$got" = "$want" ]; then echo "  ok   $name -> $got"
    else echo "  BAD  $name -> $got (wanted $want)"; cat "$dir/$name.out"; fails=$((fails+1)); fi
  }
  echo "check-tests-ran selftest:"
  expect fail build-failed        'Compiling WalkKit\nerror: Build failed\nerror: fatalError\n'
  expect fail build-failed-late   'Test run with 16 tests in 0 suites passed after 0.1 seconds.\nerror: Build failed\n'
  expect fail st-zero             'Build complete!\nTest run with 0 tests in 0 suites passed after 0.001 seconds.\n'
  expect fail xc-zero             'Test Suite All tests passed\n\t Executed 0 tests, with 0 failures (0 unexpected) in 0.001 (0.002) seconds\n'
  expect fail no-summary          'Build complete! (5.33 sec)\nTesting Library Version: 2401\n'
  expect fail empty               ''
  expect fail no-matching         'Build complete!\nerror: No matching test cases were run\n'
  expect fail st-failed           'Test run with 3 tests in 1 suite failed after 0.2 seconds with 1 issue.\n'
  expect fail xc-failures         'Executed 12 tests, with 2 failures (0 unexpected) in 1.0 (1.1) seconds\n'
  expect pass st-passed           'Build complete!\nTest run with 16 tests in 0 suites passed after 0.001 seconds.\n'
  expect pass xc-passed           'Test Suite WalkKitTests passed\n\t Executed 5 tests, with 0 failures (0 unexpected) in 0.1 (0.1) seconds\nTest Suite All tests passed\n\t Executed 12 tests, with 0 failures (0 unexpected) in 1.0 (1.1) seconds\n'
  expect pass both                'Executed 4 tests, with 0 failures (0 unexpected) in 0.1 (0.1) seconds\nTest run with 16 tests in 0 suites passed after 0.001 seconds.\n'
  rm -rf "$dir"
  [ "$fails" = "0" ] || { echo "::error::selftest: $fails case(s) did not behave"; exit 1; }
  echo "selftest: every refusal refuses, every pass passes"
}

case "${1:-}" in
  --selftest) selftest ;;
  "") echo "usage: $0 <test-log> | --selftest" >&2; exit 2 ;;
  *) check "$1" ;;
esac
