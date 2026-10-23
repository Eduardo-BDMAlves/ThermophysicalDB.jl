# Location of the on-disk data: one root directory with a sub-directory per data source.
#
#   <root>/thermoml/   cached NIST/TRC ThermoML archive and its manifest
#   <root>/user/       the user's own database (never touched by archive updates)

const DATA_DIR_ENV = "THERMOPHYSICALDB_DATA_DIR"
const DATA_DIR_PREFERENCE = "data_dir"

"""
    default_data_dir() -> String

Platform default for the root data directory: `%LOCALAPPDATA%\\ThermophysicalDB` on
Windows, `~/Library/Application Support/ThermophysicalDB` on macOS and
`\$XDG_DATA_HOME/ThermophysicalDB` (default `~/.local/share`) elsewhere.
"""
function default_data_dir()::String
    if Sys.iswindows()
        base = get(ENV, "LOCALAPPDATA", "")
        isempty(base) && (base = joinpath(homedir(), "AppData", "Local"))
        return joinpath(base, "ThermophysicalDB")
    elseif Sys.isapple()
        return joinpath(homedir(), "Library", "Application Support", "ThermophysicalDB")
    else
        base = get(ENV, "XDG_DATA_HOME", "")
        isempty(base) && (base = joinpath(homedir(), ".local", "share"))
        return joinpath(base, "ThermophysicalDB")
    end
end

"""
    data_dir(; create = false) -> String

Root directory where ThermophysicalDB keeps its data. Resolution order:

1. the environment variable `THERMOPHYSICALDB_DATA_DIR`;
2. the preference stored by [`set_data_dir!`](@ref);
3. the platform default, see [`default_data_dir`](@ref).

The directory is only created when `create = true`.
"""
function data_dir(; create::Bool = false)::String
    from_env = get(ENV, DATA_DIR_ENV, "")
    dir = if !isempty(from_env)
        from_env
    else
        pref = Preferences.load_preference(@__MODULE__, DATA_DIR_PREFERENCE, nothing)
        pref isa AbstractString && !isempty(pref) ? String(pref) : default_data_dir()
    end
    dir = abspath(expanduser(dir))
    create && mkpath(dir)
    return dir
end

function subdir(name::AbstractString, create::Bool)::String
    dir = joinpath(data_dir(), name)
    create && mkpath(dir)
    return dir
end

"""
    thermoml_dir(; create = false) -> String

Directory holding the cached ThermoML archive and its manifest.
"""
thermoml_dir(; create::Bool = false) = subdir("thermoml", create)

"""
    user_dir(; create = false) -> String

Directory reserved for the user's own database.
"""
user_dir(; create::Bool = false) = subdir("user", create)

"""
    set_data_dir!(path) -> String

Persistently set the root data directory through Preferences.jl. The preference lives in
the `LocalPreferences.toml` of the *active Julia environment*, so it applies only to that
environment. To change the location for every environment on the machine, set the
environment variable `THERMOPHYSICALDB_DATA_DIR` instead (it takes precedence).

Existing data is not moved. Returns the path that was stored. The new location is
guaranteed to be in effect after restarting Julia.
"""
function set_data_dir!(path::AbstractString)
    dir = abspath(expanduser(path))
    Preferences.set_preferences!(@__MODULE__, DATA_DIR_PREFERENCE => dir)
    return dir
end

"""
    reset_data_dir!()

Remove the preference set by [`set_data_dir!`](@ref), so that the platform default (or the
environment variable) applies again after restarting Julia.
"""
function reset_data_dir!()
    Preferences.delete_preferences!(@__MODULE__, DATA_DIR_PREFERENCE)
    return nothing
end
