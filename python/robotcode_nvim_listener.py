"""Capture final test results without changing Robot's output/log/report paths."""

import json
import os

ROBOT_LISTENER_API_VERSION = 3


def _test_result(test):
    return {
        "name": test.name,
        "longname": test.longname,
        "status": test.status,
        "message": test.message or "",
        "elapsed_ms": test.elapsedtime,
    }


def _tests(suite):
    for test in suite.tests:
        yield _test_result(test)
    for child in suite.suites:
        yield from _tests(child)


def _write(tests):
    path = os.environ.get("NVIM_ROBOTCODE_RESULT_FILE")
    if path:
        temporary = path + ".tmp"
        with open(temporary, "w", encoding="utf-8") as stream:
            json.dump({"tests": tests}, stream, ensure_ascii=False)
        os.replace(temporary, path)


def end_test(data, result):
    _write([_test_result(result)])


def end_suite(data, result):
    # A parent suite teardown can change a previously passing test to FAIL.
    # Rewrite from the final suite result instead of keeping end_test's status.
    _write(list(_tests(result)))
