```@meta
CurrentModule = ThermophysicalDB
```

# [API reference](@id reference)

Everything exported by ThermophysicalDB.jl, grouped by purpose. The functions of the last section are not exported and are subject to change; they are documented for contributors.

## Getting the database

```@docs
ThermophysicalDB
```

```@docs
database
check_update
update_database!
ensure_archive
install_archive!
```

## Where the data are stored

```@docs
data_dir
set_data_dir!
reset_data_dir!
```

## Selecting and extracting points

```@docs
points
DataView
table
```

## The dataset

```@docs
Dataset
```

## Internals

These docstrings document the implementation. They are not part of the public interface and may change in any release.

```@autodocs
Modules = [ThermophysicalDB]
Public = false
Filter = x -> x !== ThermophysicalDB.Dataset
```
