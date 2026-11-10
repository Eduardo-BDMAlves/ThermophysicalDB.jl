@testitem "native_value and native_difference: Unitful temperature scales" tags =
    [:unit, :fast] begin
    using Unitful: Unitful, @u_str
    T = ThermophysicalDB
    kind = T.NativeTemperature()
    @test T.native_value(25.0u"°C", kind) ≈ 298.15
    @test T.native_value(77.0u"°F", kind) ≈ 298.15
    @test T.native_value(300.0u"K", kind) == 300.0
    # An uncertainty is an interval: 0.01 degC is 0.01 K, not 273.16 K.
    @test T.native_difference(0.01u"°C", kind) ≈ 0.01
    @test T.native_difference(1.8u"°F", kind) ≈ 1.0
    pk = T.NativePressure()
    @test T.native_value(1.0u"bar", pk) ≈ 100.0
    @test T.native_value(101325.0u"Pa", pk) ≈ 101.325
    @test T.native_difference(2.0u"MPa", pk) ≈ 2000.0
    @test_throws Exception T.native_value(1.0u"m", kind)
    @test T.native_value(3, kind) === 3.0
end

@testitem "native_value: DynamicQuantities and FlexUnits" tags = [:unit, :fast] begin
    using DynamicQuantities: DynamicQuantities as DQ
    using FlexUnits: FlexUnits as FU
    T = ThermophysicalDB
    kt, kp = T.NativeTemperature(), T.NativePressure()
    @test T.native_value(DQ.uparse("K") * 300.0, kt) ≈ 300.0
    @test T.native_value(DQ.uparse("bar") * 1.0, kp) ≈ 100.0
    @test T.native_difference(DQ.uparse("K") * 0.5, kt) ≈ 0.5
    @test_throws Exception T.native_value(DQ.uparse("m") * 1.0, kt)
    reg = FU.UnitRegistry
    @test T.native_value(1.0 * reg.uparse("bar"), kp) ≈ 100.0
    @test T.native_value(300.0 * reg.uparse("K"), kt) ≈ 300.0
    @test_throws Exception T.native_value(1.0 * reg.uparse("m"), kt)
end

@testitem "table(; quantities) attaches units for every backend" setup = [Toy] tags =
    [:unit, :fast] begin
    using Unitful: Unitful
    using DynamicQuantities: DynamicQuantities as DQ
    using FlexUnits: FlexUnits as FU
    T = ThermophysicalDB
    ds = Toy.build()
    view = T.points(ds; component = "methane")
    plain = T.table(view)

    uf = T.table(view; quantities = Unitful)
    @test Unitful.ustrip.(uf.value) == plain.value
    @test Unitful.ustrip.(uf.temperature) == plain.temperature

    dq = T.table(view; quantities = DQ)
    @test DQ.ustrip.(dq.value) ≈ plain.value
    @test DQ.ustrip.(dq.temperature) ≈ plain.temperature
    @test DQ.dimension(dq.temperature[1]) == DQ.dimension(DQ.uparse("K"))

    fu = T.table(view; quantities = FU)
    @test FU.ustrip.(fu.temperature) ≈ plain.temperature
    @test FU.ustrip.(fu.value) ≈ plain.value

    # The backend is only chosen with `quantities`; there is no other keyword for it.
    @test_throws MethodError T.table(view; unitful = true)
    # No backend, plain Float64 columns.
    @test eltype(plain.value) == Float64
end

@testitem "an unregistered backend is reported clearly" setup = [Toy] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    ds = Toy.build()
    view = T.points(ds; component = "methane")
    @test_throws ArgumentError T.table(view; quantities = :NoSuchPackage)
    @test_throws ArgumentError T.parse_unit(T.unit_backend(nothing), "K")
end

@testitem "points and reference_summary accept quantities from any backend" setup = [Toy] tags =
    [:unit, :fast] begin
    using Unitful: Unitful, @u_str
    using DynamicQuantities: DynamicQuantities as DQ
    T = ThermophysicalDB
    ds = Toy.build()
    base = T.points(ds; component = "methane", temperature = (100, 400))
    uf = T.points(ds; component = "methane", temperature = (-173.15u"°C", 126.85u"°C"))
    dq = T.points(
        ds;
        component = "methane",
        temperature = (DQ.uparse("K") * 100.0, DQ.uparse("K") * 400.0),
    )
    @test length(uf) == length(base)
    @test length(dq) == length(base)
    @test T.convert_native(1.0, T.NativePressure(), "bar") ≈ 0.01
    @test T.convert_native(300.0, T.NativeTemperature(), "°C") ≈ 26.85
end
