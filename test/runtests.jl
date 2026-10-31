using ThermophysicalDB
using TestItemRunner

# Quiet by default: one line per file and the failures. THERMOPHYSICALDB_TEST_VERBOSE=true
# lists every test item; THERMOPHYSICALDB_TEST_FAILFAST=true stops at the first failure.
@run_package_tests verbose = (get(ENV, "THERMOPHYSICALDB_TEST_VERBOSE", "false") == "true") failfast =
    (get(ENV, "THERMOPHYSICALDB_TEST_FAILFAST", "false") == "true")
