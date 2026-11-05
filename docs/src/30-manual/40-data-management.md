```@meta
CurrentModule = ThermophysicalDB
```

# [Downloads, updates and cache](@id updates)

[`database`](@ref) hides all of this behind one call. This page explains what happens underneath, so you can control it and fix it when something goes wrong.

## Where the data live

Everything is stored under one root directory, returned by [`database_dir`](@ref):

| Platform | Default location |
| :-- | :-- |
| Windows | `%LOCALAPPDATA%\ThermophysicalDB` |
| macOS | `~/Library/Application Support/ThermophysicalDB` |
| Linux | `$XDG_DATA_HOME/ThermophysicalDB` (default `~/.local/share/ThermophysicalDB`) |

Inside it, each data source has its own folder. The NIST archive lives in `thermoml/`:

| File | Content |
| :-- | :-- |
| `ThermoML.vYYYY-MM-DD.tgz` | the archive exactly as NIST publishes it |
| `manifest.toml` | version, SHA-256 digest, source URL, download date and size of the archive. Written last: a manifest on disk always describes a complete, verified archive. |
| `dataset.jld2` | the parsed database as flat arrays (the binary cache) |
| `dataset.toml` | which archive and schema version the cache was built from. Written last, so a cache without it is ignored. |

The list of compounds (see [Compounds and their identifiers](@ref compounds)) lives next to it, in `compounds/`, and is downloaded the first time `compound_database()` is called.

To keep the data somewhere else (a larger disk, a shared folder), use either of these. The environment variable wins when both are set:

```julia
set_database_dir!("D:/data/thermophysical")   # stored in the active environment's LocalPreferences.toml
```

```bash
export THERMOPHYSICALDB_DATA_DIR=/shared/thermophysical   # applies to every environment
```

Existing data are not moved. [`reset_database_dir!`](@ref) removes the preference again.

## What `database()` does

```julia
db = database()
```

1. Returns the object already built in this session, if there is one.
2. Makes sure a verified archive is installed (`ensure_archive`): downloads it if missing, or checks whether NIST has a newer one.
3. Loads the binary cache if it matches the installed archive; otherwise parses the archive and writes the cache.

The keywords change this behaviour:

| Keyword | Effect |
| :-- | :-- |
| `update = :notify` (default) | If NIST has a newer archive, keep the local one and log a warning. |
| `update = :install` | Download and switch to the newer archive. |
| `update = :never` | Do not contact NIST at all. Use this offline. |
| `reload = true` | Repeat the update check and reload, even within the same session. |
| `rebuild = true` | Also ignore the cache and parse the archive again. |
| `progress = false` | No progress bars, useful in scripts and in CI. |

## Several databases that look like one

[`database`](@ref) returns a [`Database`](@ref): a list of independent databases, the *members*. Today it holds the ThermoML archive (`:thermoml`); points you measure (`:user`) or take from the literature (`:literature`) are separate members with the same tables and the same fields, so nothing of the archive is ever changed by what you add. Every member lives in its own file and is read only when a query can find something in it.

```julia
db = database()
members(db)                            # the databases, first the one that wins on a repeated point
view = points(db; component = "methane")
parts(view)                            # one DataView for each database that has points
table(view)                            # all the points, with a column `database` when there are several
```

What makes this fast is a small index that is always in memory (the *registry*): it gives each compound, property and reference one number in all the members, and says which member has what. A question about a compound that only one member knows reads only that member. The tables of a member that are rarely needed (samples, purity, conditions and extra fields) are read the first time something asks for them; [`loaded_tables`](@ref) shows what is in memory.

- A compound is the same in two members when its key is: the InChIKey, or `name:...` for a compound that the archive knows only by name. Nothing is merged by guessing. A compound that has only a name is listed in `db.registry.unkeyed`, so you can give it an InChIKey.
- A property is the pair (label, unit) and a reference is a DOI.
- [`add_member!`](@ref) and [`remove_member!`](@ref) manage the members; `priority` (smaller first) decides which database wins when the same point is in several.
- `find_compounds(db, text)` joins the databases: one row for each compound, with the points of all of them, and its result can be given as the `component` of `points`.
- Functions that join the points of several databases (export, outliers, references) work on one database for now: use `parts(view)`.

## Checking and updating by hand

[`check_update`](@ref) compares the local archive with the latest one published by NIST. It never throws because of network problems: if NIST cannot be reached it falls back to the releases the package knows, and says so in `source`.

```julia
status = check_update()
status.state       # :not_installed, :up_to_date, :update_available or :unknown
status.latest      # the most recent release known
status.source      # :remote if NIST answered, :builtin otherwise
```

[`update_database!`](@ref) installs the latest archive only if the local one is missing or outdated. Old archives are deleted after a successful installation.

## Integrity

Every installation follows the same safe sequence, whether the file was downloaded or supplied by you:

1. the archive is written to a temporary `.part` file;
2. its SHA-256 digest is compared with the one NIST publishes (or with a digest that you provide);
3. only if they match is the file moved into place;
4. the manifest is written last.

A download that was interrupted, truncated or corrupted never looks like a valid installation, and a digest mismatch installs nothing.

## When the download fails

The archive is served by NIST through a redirect, and some networks, proxies and firewalls refuse the connection. ThermophysicalDB.jl does not give up at the first error:

- A download makes up to **four attempts**, pausing 2, 5 and 10 seconds between them. Each pause is announced in a warning with the reason for the previous failure.
- Within each attempt it tries up to **three independent ways** of fetching the file: Julia's own downloader, the same downloader with a browser-style `User-Agent`, and the `curl` program of the operating system (which uses the system's network stack, certificates and proxy settings) when it is available.
- A partial file is never left behind.

If every attempt fails, the error lists each try and what went wrong, and says what to do:

1. **Check the connection, VPN or proxy.** If your network requires a proxy, set the `HTTPS_PROXY` environment variable before starting Julia.
2. **Download the file in a browser** from [https://data.nist.gov/od/id/mds2-2422](https://data.nist.gov/od/id/mds2-2422) and install it with [`install_archive!`](@ref).
3. **Try again later.** The NIST servers sometimes refuse requests temporarily.

## Installing an archive from a file

[`install_archive!`](@ref) installs a file that is already on your disk, exactly as a download would be installed: verified, copied into the data directory and recorded in the manifest.

```julia
install_archive!("C:/Users/me/Downloads/ThermoML.v2020-09-30.tgz")
db = database()
```

The digest is taken from the `sha256` keyword, else from a `ThermoML.v2020-09-30.tgz.sha256` file next to the archive, else from the releases that the package knows about. The version is read from the file name when `version` is not given. A file whose digest does not match is rejected and nothing is installed.

## In automated builds

Parsing the archive takes minutes, so a continuous-integration job should keep the data directory between runs. Point the package at a directory you can cache, and silence the progress bars:

```bash
export THERMOPHYSICALDB_DATA_DIR="$RUNNER_TEMP/thermophysicaldb"
```

```julia
db = database(progress = false)
```

The documentation of this package is built that way: the data directory is restored from the cache of the workflow, so only a change to the parser causes a new parse.
