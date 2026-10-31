# The notice that travels with everything derived from the NIST/TRC ThermoML Archive.
#
# Every export format, the documentation and the message of the first download read the
# text from here, so the wording and the citation of the dataset exist in one place only.

const ARCHIVE_NAME = "NIST/TRC ThermoML Archive"
const ARCHIVE_URL = "https://trc.nist.gov/ThermoML/"
# The DOI, the version and the citation of the dataset come from CITATION.cff (references.jl).
const ARCHIVE_DOI = cff_doi(ARCHIVE_REFERENCE)
const ARCHIVE_VERSION = string(ARCHIVE_REFERENCE["version"])
const ISSUES_URL = "https://github.com/Eduardo-BDMAlves/ThermophysicalDB.jl/issues"
const NOTICE_URL = "https://github.com/Eduardo-BDMAlves/ThermophysicalDB.jl/blob/main/NOTICE.md"

# Full citation of the dataset, as requested by its publisher.
const ARCHIVE_CITATION = cff_citation_text(ARCHIVE_REFERENCE)

const NOTICE_MODIFIED =
    "modified data: reformatted by ThermophysicalDB.jl and possibly " *
    "converted to other units"
const NOTICE_NOT_ENDORSED =
    "not evaluated or endorsed by NIST/TRC; ThermophysicalDB.jl is " * "independent of them"
const NOTICE_CREDIT = "credit the original article of each point (by its DOI) and the archive"

# Where the data come from. Exports add the version of the archive in use after these.
const ORIGIN_HEAD = (
    "data origin" => ARCHIVE_NAME,
    "archive url" => ARCHIVE_URL,
    "dataset doi" => ARCHIVE_DOI,
)

# What the reader must be told about the data, in this order.
const NOTICE_TAIL = (
    "dataset citation" => ARCHIVE_CITATION,
    "notice" => string(NOTICE_MODIFIED, "; ", NOTICE_NOT_ENDORSED),
    "credit" => NOTICE_CREDIT,
    "terms" => NOTICE_URL,
)

"""
    notice_entries() -> Vector{Pair{String,String}}

The notice as `field => text` pairs: the origin of the data, the citation of the dataset
and the conditions of use. Every file that holds data from the ThermoML Archive carries
these entries.
"""
notice_entries() = Pair{String,String}[ORIGIN_HEAD..., NOTICE_TAIL...]

# One line, `field: text; field: text`, for the comment of a table.
function notice_line(entries = notice_entries())
    return join((string(k, ": ", v) for (k, v) in entries), "; ")
end

# One line per field, `field: text`, for a block of comments.
notice_lines(entries = notice_entries()) = String[string(k, ": ", v) for (k, v) in entries]

notice_text() = join(notice_lines(), "\n")

"""
    first_download_message() -> String

The short notice logged once, when the archive is downloaded for the first time.
"""
function first_download_message()
    return string(
        "Data from the ",
        ARCHIVE_NAME,
        " (dataset version ",
        ARCHIVE_VERSION,
        ", doi:",
        ARCHIVE_DOI,
        "). Files exported by this package contain ",
        NOTICE_MODIFIED,
        ", ",
        NOTICE_NOT_ENDORSED,
        ". Please ",
        NOTICE_CREDIT,
        ". Terms: ",
        NOTICE_URL,
    )
end

# Whether any point of `view` comes from the ThermoML Archive.
function from_archive(view::DataView)::Bool
    ds = view.dataset
    source = get(ds.sources.index, "thermoml", NO_ID)
    source == NO_ID && return false
    m, ex, rf = ds.measurements, ds.experiments, ds.references
    for r in view.rows
        ref = ex.reference[m.experiment[r]]
        ref != NO_ID && rf.source[ref] == source && return true
    end
    return false
end
