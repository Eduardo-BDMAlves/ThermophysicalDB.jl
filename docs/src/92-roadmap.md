# [Roadmap](@id roadmap)

This page lists what is planned for ThermophysicalDB.jl and records what has been done as the package grows. Items are intentions, not promises: their order and scope can change. Each item moves from *Planned* to *In progress* and then to *Done*, and the finished ones are described in the [changelog](https://github.com/Eduardo-BDMAlves/ThermophysicalDB.jl/blob/main/CHANGELOG.md).

## Planned

The first three items are linked: the sample data are needed to write valid ThermoML, which in turn is the basis for adding data of the user.

### 1. Sample metadata

The ThermoML Archive describes the sample of every compound: where it came from, how it was purified, its purity and the analytical method used to state it. Many authors consider this among the most important information to report, because the purity and the hydration of a sample change the composition that was actually measured, and a difference of a few tenths of a per cent in composition can move a density or a heat capacity by more than its stated uncertainty. The package does not read it yet.

Design decision: the sample data live in a table of their own, with one row per sample, and every experiment points to the sample of each of its components by an index. A sample is shared by many measurements of the same article, so this avoids repeating it, keeps filters fast, and gives users one place to look at.

- A `SampleTable`, in the same column-based layout as the other tables, read directly from the archive. Besides the sample number, the source and the status of the sample, it keeps the purity (by mole, mass or volume, with the stated digits), the content of water or halides when given, the analytical method, and the purification methods and steps.
- The link between the experiment and the sample of each component, read from the sample number that every component of a measurement carries in the archive.
- Optional fields stay optional: a sample without a stated purity is valid and is simply reported as such. Users can reach the sample data of a selection of points and filter by purity, source or method.
- The evaluator and the method of the uncertainty evaluation, next to the coverage level that is already read.

### 2. Compliance with ThermoML

The goal is that data written by the package are valid ThermoML, and that the package states clearly how complete they are.

- Target schema: the ThermoML schema published by NIST/TRC (documented as version 4.0, the 2011 update of the IUPAC recommendations). A version 5.0 has been announced for metal-based systems, with additional reporting requirements for phases and for the characterisation of samples; it will be followed if and when it is published, and the sample table is designed to hold those fields.
- Two levels of checking: *valid*, meaning that the file satisfies the schema (the elements that the schema requires, such as the sample number, the phase, the property with its method and presentation, and the variables and constraints with their values), and *complete*, meaning that it also carries the information that the literature considers essential for reuse (source and purity of each sample, uncertainty with its coverage level, and the reference).
- Validation against the schema file and a round trip, in which the reader of the package reads what its writer wrote.

### 3. Data of the user

- Add experimental data of the user to the local database, kept apart from the archive, which is never modified.
- Start from a fill-in template that contains every field needed for valid ThermoML, then add a reusable mapping so that tables from other sources can be imported once their columns are declared.
- Write valid ThermoML from those data.

### 4. Systems with many components

The experiment tables hold at most three components per system. This limit is meant to become configurable, so that multicomponent systems such as brines can be represented completely.

### 5. Composition and molar mass

- Convert between composition bases (molality, mass fraction, mole fraction), using the molar mass of each compound.

### 6. Planning of experiments

- Map the coverage of the data in temperature, pressure and composition for a given system.
- Suggest the points that reduce the most the uncertainty of the parameters of a model, using the uncertainty of the data as weights.

## In progress

Nothing is listed yet.

## Done

Nothing is listed yet; see the [changelog](https://github.com/Eduardo-BDMAlves/ThermophysicalDB.jl/blob/main/CHANGELOG.md) for the changes of each version.
