# The audit log: a plain text record of the permanent changes that the package makes to the data
# on disk (the ThermoML archive that is installed, the databases of the user that are saved, the
# compounds that are saved). It records what changed and when, not who did it.
#
# It cannot be made impossible to edit (the package is open source and the file is the user's), but
# an edit from outside can be found: every line carries the SHA-256 of the previous hash and its own
# text, so changing, removing or inserting a line breaks every hash after it, and a checkpoint
# (`audit_checkpoint`) written down somewhere else proves that the whole file was not rewritten.
#
# The file `audit.log` is next to what it describes (the archive directory, the folder of a user
# database, the folder of the compounds), with `audit.toml` that keeps the identifier (UUID) of the
# log, so that a log that was swapped for another one is noticed. Format, one line per event, fields
# separated by a tab, the first line being the header:
#
#   #tdb-audit  <version>  <uuid>  <created>  <hash>
#   <seq>  <time>  <event>  <object>  <detail>  <sha256 of the file>  <before>  <after>  <hash>
#
# `before` and `after` are counts, `references:experiments:points` for a database and the number of
# rows for the compounds, `-` when there is nothing to count. The hash of a line is the SHA-256 of
# the hash of the line before, a newline and the text of the line without its hash; the header
# starts the chain from an empty hash.

const AUDIT_LOG = "audit.log"
const AUDIT_ID = "audit.toml"
const AUDIT_FORMAT = "tdb-audit"
const AUDIT_VERSION = 1
const AUDIT_EVENT_FIELDS = 9

audit_log_path(dir::AbstractString) = joinpath(dir, AUDIT_LOG)
audit_id_path(dir::AbstractString) = joinpath(dir, AUDIT_ID)

audit_hash(previous::AbstractString, body::AbstractString) =
    bytes2hex(SHA.sha256(string(previous, '\n', body)))

# A field cannot hold a tab or a line break, or it would break the line apart.
audit_clean(x) = isempty(string(x)) ? "-" : replace(string(x), r"[\t\r\n]" => " ")

audit_counts(ds) =
    string(length(ds.references), ':', length(ds.experiments), ':', length(ds.measurements))

# ----------------------------------------------------------------------------------
# Writing
# ----------------------------------------------------------------------------------

# The last line of a file, read from its end (a line is a few hundred bytes).
function last_audit_line(path::AbstractString)
    open(path, "r") do io
        size = filesize(path)
        seek(io, max(0, size - 4096))
        lines = split(read(io, String), '\n'; keepempty = false)
        return isempty(lines) ? nothing : String(last(lines))
    end
end

# What the next line needs from the last one: its sequence number, hash and `after` counts.
function audit_tail(path::AbstractString)
    line = last_audit_line(path)
    line === nothing && return nothing
    fields = split(line, '\t')
    hash = String(last(fields))
    if length(fields) == AUDIT_EVENT_FIELDS
        return (seq = parse(Int, fields[1]), hash = hash, counts = String(fields[8]))
    end
    return (seq = 0, hash = hash, counts = "-")
end

# The identifier of the log that is kept in `audit.toml`; a new one when there is none.
function audit_uuid(dir::AbstractString)
    path = audit_id_path(dir)
    if isfile(path)
        id = get(TOML.parsefile(path), "uuid", nothing)
        id isa AbstractString && return String(id)
    end
    id = string(UUIDs.uuid4())
    open(
        io -> TOML.print(io, Dict("format" => AUDIT_FORMAT, "uuid" => id)),
        path * ".tmp",
        "w",
    )
    mv(path * ".tmp", path; force = true)
    return id
end

tab_join(fields) = sprint(io -> join(io, fields, '\t'))

function audit_line(previous::AbstractString, fields)
    body = tab_join(fields)
    return string(body, '\t', audit_hash(previous, body))
end

function create_audit_log(path::AbstractString, dir::AbstractString)
    header = ("#" * AUDIT_FORMAT, string(AUDIT_VERSION), audit_uuid(dir), utc_timestamp())
    line = audit_line("", header)
    write(path, line, '\n')
    return (seq = 0, hash = String(last(split(line, '\t'))), counts = "-")
end

# Adds one event line after `tail` and returns the new tail. A change that counts nothing keeps
# the counts that the log already had, so the next `before` is still known.
function append_audit_line!(
    path::AbstractString,
    tail,
    event,
    object,
    detail,
    sha256,
    counts,
)
    after = counts == "-" ? tail.counts : counts
    fields = (
        string(tail.seq + 1),
        utc_timestamp(),
        audit_clean(event),
        audit_clean(object),
        audit_clean(detail),
        audit_clean(sha256),
        audit_clean(tail.counts),
        audit_clean(after),
    )
    line = audit_line(tail.hash, fields)
    open(io -> write(io, line, '\n'), path, "a")
    return (seq = tail.seq + 1, hash = String(last(split(line, '\t'))), counts = after)
end

"""
    audit_record!(dir, event, object; detail = "", sha256 = "", counts = "-")

Add a line to the audit log in `dir`, creating the log (and its identifier) if there is none. The
log is locked while it is written so that two sessions do not fork the chain. A log that is gone
while its identifier is still there (it was removed from outside the package) is started again
with the same identifier and the event `log_recreated`. A failure is a warning, never an error:
the change that is being recorded has been made already.
"""
function audit_record!(
    dir::AbstractString,
    event::AbstractString,
    object::AbstractString;
    detail::AbstractString = "",
    sha256::AbstractString = "",
    counts::AbstractString = "-",
    once::Bool = false,
    warn::Bool = true,
)
    try
        mkpath(dir)
        path = audit_log_path(dir)
        FileWatching.Pidfile.mkpidlock(path * ".lock") do
            once && same_as_last_event(path, event, object, detail) && return nothing
            tail = isfile(path) ? audit_tail(path) : nothing
            if tail === nothing
                recreated = isfile(audit_id_path(dir))
                tail = create_audit_log(path, dir)
                recreated && (
                    tail = append_audit_line!(
                        path,
                        tail,
                        "log_recreated",
                        "-",
                        "",
                        "",
                        "-",
                    )
                )
            end
            append_audit_line!(path, tail, event, object, detail, sha256, counts)
        end
    catch err
        err isa InterruptException && rethrow()
        warn && @warn "The audit log could not be written" dir event reason =
            sprint(showerror, err)
    end
    return nothing
end

# With `once = true` a line that repeats the last one (a damaged database found again in every
# session) is not written again.
function same_as_last_event(path, event, object, detail)
    isfile(path) || return false
    line = last_audit_line(path)
    line === nothing && return false
    fields = split(line, '\t')
    length(fields) == AUDIT_EVENT_FIELDS || return false
    return fields[3] == audit_clean(event) &&
           fields[4] == audit_clean(object) &&
           fields[5] == audit_clean(detail)
end

# The error, as one line for the log: its type and the first line of its message.
function error_detail(err)
    text = first(split(sprint(showerror, err), '\n'))
    text = length(text) > 300 ? first(text, 300) * "…" : text
    return string(nameof(typeof(err)), ": ", text)
end

"""
    audited(f, dir, operation, object)

Run `f()` between two lines of the audit log in `dir`: `<operation>_started` before it, so that
an operation that was cut short (the process killed, the computer switched off) shows as a start
with no end, and `<operation>_failed` with the error if `f` throws, which is then thrown again.
`f` records the success itself (`audit_record!` with the digest and the counts of what it wrote).
"""
function audited(f, dir::AbstractString, operation::AbstractString, object::AbstractString)
    audit_record!(dir, operation * "_started", object)
    try
        return f()
    catch err
        audit_record!(dir, operation * "_failed", object; detail = error_detail(err))
        rethrow()
    end
end

# Checks the digest of a downloaded or local archive; a file that does not match is recorded as
# rejected (with the digest that was expected and the one that was found) before the error.
function verify_logged(dir::AbstractString, object::AbstractString, path, expected)
    try
        return verify_sha256(path, expected)
    catch err
        err isa ChecksumMismatchError && audit_record!(
            dir,
            "archive_rejected",
            object;
            detail = "expected=" * err.expected,
            sha256 = err.actual,
        )
        rethrow()
    end
end

# The digest of a file for the log; a file that cannot be read is not a reason to lose the line.
function logged_sha256(path::AbstractString)
    try
        return file_sha256(path)
    catch err
        err isa InterruptException && rethrow()
        return "-"
    end
end

# ----------------------------------------------------------------------------------
# Reading and checking
# ----------------------------------------------------------------------------------

# Walks a log, checking the chain; calls `on_event(fields)` for each event line. The answer is
# (ok, uuid, lines, head, line, problem, hashes) with `line` the first line that does not match.
function walk_audit_log(path::AbstractString, on_event)
    uuid, head, count, problem, bad = "", "", 0, "", 0
    hashes = String[]
    number = 0
    io = open(path)    # closed on every way out: an open file cannot be removed on Windows
    try
        for text in eachline(io)
            number += 1
            fields = split(text, '\t')
            found = String(last(fields))
            body = tab_join(fields[1:(end-1)])
            if number == 1
                if length(fields) != 5 || fields[1] != "#" * AUDIT_FORMAT
                    return (false, "", 0, "", 1, "the header is missing or damaged", hashes)
                end
                uuid = String(fields[3])
                expected = audit_hash("", body)
            else
                expected = audit_hash(head, body)
                if length(fields) != AUDIT_EVENT_FIELDS
                    problem, bad = "the line does not have the fields of an event", number
                elseif tryparse(Int, fields[1]) != number - 1
                    problem, bad = "the sequence number is not $(number - 1)", number
                end
            end
            if isempty(problem) && found != expected
                problem, bad =
                    "the hash does not match: the line or one before it was changed", number
            end
            isempty(problem) || return (false, uuid, count, head, bad, problem, hashes)
            head = found
            number > 1 && (count += 1; push!(hashes, head); on_event(fields))
        end
    finally
        close(io)
    end
    number == 0 && return (false, "", 0, "", 0, "the file is empty", hashes)
    return (true, uuid, count, head, 0, "", hashes)
end

# The identifier that `audit.toml` keeps, or `nothing`.
function recorded_uuid(dir::AbstractString)
    path = audit_id_path(dir)
    isfile(path) || return nothing
    id = get(TOML.parsefile(path), "uuid", nothing)
    return id isa AbstractString ? String(id) : nothing
end

function verify_audit_dir(dir::AbstractString, checkpoint)
    path = audit_log_path(dir)
    expected_id = recorded_uuid(dir)
    if !isfile(path)
        expected_id === nothing && return (true, "", 0, "", 0, "")
        return (
            false,
            expected_id,
            0,
            "",
            0,
            "the log is missing; its identifier is still recorded",
        )
    end
    ok, uuid, lines, head, line, problem, hashes = walk_audit_log(path, _ -> nothing)
    if ok && expected_id !== nothing && expected_id != uuid
        ok, line, problem =
            false, 1, "the log is not the one that was recorded ($expected_id)"
    end
    if ok && checkpoint !== nothing
        n, want = checkpoint_fields(checkpoint)
        if n > lines || hashes[n] != want
            ok, line = false, n + 1
            problem = "the checkpoint at line $n does not match: the log was rewritten"
        end
    end
    return (ok, uuid, lines, head, line, problem)
end

function checkpoint_fields(checkpoint)
    haskey(checkpoint, :lines) && haskey(checkpoint, :head) || throw(
        ArgumentError(
            "a checkpoint is the result of audit_checkpoint, or (lines = n, head = \"…\")",
        ),
    )
    n = Int(checkpoint.lines)
    n >= 1 || throw(ArgumentError("a checkpoint is made of at least one line"))
    return n, lowercase(String(checkpoint.head))
end

# The logs that can be asked about: (scope, directory) for the archive, the compounds and each
# database of the user that is saved. Only the ones that have a log or an identifier are listed.
function audit_scopes(db, database)
    scopes =
        Tuple{String,String}[("thermoml", thermoml_dir()), ("compounds", compounds_dir())]
    if db !== nothing
        for m in db.members
            (m.kind === :thermoml || !m.persistent || isempty(m.path)) && continue
            push!(scopes, (m.name, dirname(m.path)))
        end
    end
    keep = filter(
        s -> isfile(audit_log_path(last(s))) || isfile(audit_id_path(last(s))),
        scopes,
    )
    database === nothing && return keep
    chosen = filter(s -> first(s) == String(database), keep)
    isempty(chosen) && throw(
        ArgumentError(
            "there is no audit log for \"$database\"; the scopes with one are " *
            join(repr.(first.(keep)), ", "),
        ),
    )
    return chosen
end

"""
    verify_audit_log([db]; database = nothing, checkpoint = nothing)

Check the audit logs: the chain of hashes of every line, the sequence of the numbers, and that the
log is the one that was recorded with the data. The answer has one row for each log, as the
columns `scope`, `ok`, `lines` (events), `uuid`, `head` (the hash of the last line), `line` (the
first line that does not match, or 0) and `problem`. `database` names one log (`"thermoml"`,
`"compounds"` or the name of a database of yours); without it all of them are checked.

`checkpoint = audit_checkpoint(db; database = "name")` (or `(lines = 12, head = "…")`) checks
also that the line `lines` still has the hash that was written down, which proves that the log was
not rewritten from the start; it needs `database`.
"""
function verify_audit_log(db = nothing; database = nothing, checkpoint = nothing)
    (checkpoint !== nothing && database === nothing) &&
        throw(ArgumentError("a checkpoint belongs to one log; say which with `database`"))
    scopes = audit_scopes(db, database)
    results = [verify_audit_dir(dir, checkpoint) for (_, dir) in scopes]
    return (
        scope = first.(scopes),
        ok = [r[1] for r in results],
        lines = [r[3] for r in results],
        uuid = [r[2] for r in results],
        head = [r[4] for r in results],
        line = [r[5] for r in results],
        problem = [r[6] for r in results],
    )
end

"""
    audit_checkpoint([db]; database) -> NamedTuple

The state of one audit log to be written down somewhere that the package does not control (a
notebook, a commit message, an e-mail): its identifier, the number of events, the hash of the last
line and the time. Later, `verify_audit_log(db; database, checkpoint = …)` proves that the log
still has that history. The log is checked first, and a broken one is an error.
"""
function audit_checkpoint(db = nothing; database)
    report = verify_audit_log(db; database)
    only(report.ok) || throw(
        ArgumentError(
            "the audit log of \"$database\" does not verify (line $(only(report.line)): " *
            "$(only(report.problem)))",
        ),
    )
    return (
        scope = only(report.scope),
        uuid = only(report.uuid),
        lines = only(report.lines),
        head = only(report.head),
        time = utc_timestamp(),
    )
end

# Fixed text of a time bound: a date, a date and time or a text of either.
audit_time(x::Dates.DateTime) = x
audit_time(x::Dates.Date) = Dates.DateTime(x)
audit_time(x::AbstractString) = Dates.DateTime(rstrip(x, 'Z'))

"""
    audit_log([db]; database = nothing, since = nothing, event = nothing)

The events of the audit logs as a table (columns `scope`, `seq`, `time`, `event`, `object`,
`detail`, `sha256`, `before` and `after`), oldest first within each log. `since` keeps the events
from that date or time on, and `event` (a name or a vector of names, such as `"database_saved"`)
only those. Events: `archive_installed`, `database_saved`, `database_exported`, `database_imported`, `database_removed`, `database_cleared`, `reference_removed`, `points_replaced`, `priority_changed`, `compounds_saved`
and `log_recreated`; the start of an operation (`database_save_started`, `database_export_started`, `database_import_started`, `compounds_save_started`,
`archive_install_started`) and its failure (`..._failed`, with the error in `detail`); and
`archive_rejected` and `database_unreadable`. `before` and `after` are the counts of references,
experiments and points of a database (the number of rows for the compounds) before and after the
change.
"""
function audit_log(db = nothing; database = nothing, since = nothing, event = nothing)
    from = since === nothing ? nothing : audit_time(since)
    names = event === nothing ? nothing : String.(vcat(event))
    cols = (
        scope = String[],
        seq = Int[],
        time = Dates.DateTime[],
        event = String[],
        object = String[],
        detail = String[],
        sha256 = String[],
        before = String[],
        after = String[],
    )
    for (scope, dir) in audit_scopes(db, database)
        path = audit_log_path(dir)
        isfile(path) || continue
        walk_audit_log(
            path,
            fields -> collect_audit_event!(cols, scope, fields, from, names),
        )
    end
    return cols
end

function collect_audit_event!(cols, scope, fields, from, names)
    time = Dates.DateTime(rstrip(String(fields[2]), 'Z'))
    (from !== nothing && time < from) && return nothing
    (names !== nothing && !(String(fields[3]) in names)) && return nothing
    push!(cols.scope, scope)
    push!(cols.seq, parse(Int, fields[1]))
    push!(cols.time, time)
    for (column, i) in zip((:event, :object, :detail, :sha256, :before, :after), 3:8)
        push!(getfield(cols, column), String(fields[i]))
    end
    return nothing
end
