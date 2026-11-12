using ThermophysicalDB
using TestItemRunner

# Quiet by default: one line per file and the failures. THERMOPHYSICALDB_TEST_VERBOSE=true
# lists every test item; THERMOPHYSICALDB_TEST_FAILFAST=true stops at the first failure.
#
# THERMOPHYSICALDB_TEST_SUITE chooses what runs (the continuous integration sets it; it is "full"
# when it is not set, which is what a developer runs):
#   full         everything.
#   no-quality   everything but the checks of Aqua and JET (tag `:quality`), which do not depend
#                on the operating system and are run on Linux only.
#   platform     only the files that depend on the operating system (paths, files, downloads,
#                the cache, the spreadsheets), for the runners that cost the most.
const SUITE = get(ENV, "THERMOPHYSICALDB_TEST_SUITE", "full")
const PLATFORM_FILES =
    r"^test-(store|remote-.+|parse|precompile|template|user-database|export|thermoml|compounds)\.jl$"

function in_suite(item)
    SUITE == "full" && return true
    SUITE == "no-quality" && return :quality ∉ item.tags
    SUITE == "platform" && return occursin(PLATFORM_FILES, basename(item.filename))
    return error(
        "THERMOPHYSICALDB_TEST_SUITE is \"$SUITE\"; it must be full, no-quality or platform",
    )
end

@run_package_tests filter = in_suite verbose =
    (get(ENV, "THERMOPHYSICALDB_TEST_VERBOSE", "false") == "true") failfast =
    (get(ENV, "THERMOPHYSICALDB_TEST_FAILFAST", "false") == "true")
