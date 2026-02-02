using Rhea
using Dates
using JSON
using Random
using Test

import Rhea: Orders

include("core.jl")
include("brokers.jl")
include("deterministic.jl")

struct DrainAgent <: Agent end

function Orders(::DrainAgent, s::State)
    inst = first(s.instruments)
    units = s.cash / inst.fee
    [MarketOrder(units, inst)]
end

@testset "Rhea.jl" begin
    steps = 1_000
    initial_cash = 100_000.0

    rng = MersenneTwister(1)
    broker = RandomWalkBroker(rng; n=10, σ=0.01, spread=0.0005, cash=initial_cash, mid=100.0)
    agent = RandomAgent(MersenneTwister(2))
    r = PnLReward()
    stats = Stats(broker.state)
    initial = nlv(broker.state)

    run!(steps, agent, broker, r, stats)
    lines = readlines(stats.path)
    @test length(lines) <= steps
    @test isfinite(parse(Float64, last(split(last(lines), ","))))

    broker₂ = RandomWalkBroker(MersenneTwister(4); n=10, σ=0.01, spread=0.0005, cash=initial_cash, mid=100.0)
    agent₂ = RuleBasedAgent(EqualWeight())
    stats₂ = Stats(broker₂.state)
    initial₂ = nlv(broker₂.state)
    run!(steps, agent₂, broker₂, r, stats₂)
    lines₂ = readlines(stats₂.path)
    @test length(lines₂) <= steps
    @test isfinite(parse(Float64, last(split(last(lines₂), ","))))

    broker₃ = RandomWalkBroker(MersenneTwister(7); n=1, σ=0.01, spread=0.0005, cash=100.0, mid=100.0, fee=1.0)
    agent₃ = DrainAgent()
    stats₃ = Stats(broker₃.state)
    run!(steps, agent₃, broker₃, r, stats₃)
    lines₃ = readlines(stats₃.path)
    @test length(lines₃) < steps
end

@testset "StatArbAgent" begin
    steps = 2_000
    initial_cash = 100_000.0
    broker = RandomWalkBroker(MersenneTwister(11); n=8, σ=0.0001, spread=0.0005, cash=initial_cash, mid=10_000.0)
    agent = StatArbAgent(broker.state, MersenneTwister(12); κ=0.05, η=1e-3, α=0.995, entry=1.0, exit=0.25, risk=0.2, cash=0.5)
    reward = PnLReward()
    stats = Stats(broker.state)

    s = State(broker, State(broker))
    orders = Orders(agent, s)
    @test orders isa AbstractVector{<:Order}

    run!(steps, agent, broker, reward, stats)
    lines = readlines(stats.path)
    @test length(lines) <= steps
    @test isfinite(parse(Float64, last(split(last(lines), ","))))
end

@testset "Oanda parsing" begin
    root = joinpath(@__DIR__, "fixtures", "oanda")
    instruments_fixture = joinpath(root, "instruments.json")
    pricing_fixture = joinpath(root, "pricing.json")
    orderfill_fixture = joinpath(root, "order_fill.json")

    pricing_json = JSON.parse(String(read(pricing_fixture)))
    quotes_map = Dict(Symbol(q["instrument"]) => q for q in pricing_json["prices"])

    instruments_json = JSON.parse(String(read(instruments_fixture)))
    response_instruments = map(enumerate(instruments_json["instruments"])) do (i, inst)
        Instrument(inst, i)
    end
    @test length(response_instruments) == length(instruments_json["instruments"])
    @test first(response_instruments).symbol == Symbol(instruments_json["instruments"][1]["name"])

    books = map(Book, pricing_json["prices"])
    @test length(books) == length(pricing_json["prices"])
    @test bestbid(first(books)) == parse(Float64, pricing_json["prices"][1]["bids"][1]["price"])
    @test bestask(first(books)) == parse(Float64, pricing_json["prices"][1]["asks"][1]["price"])



    orderfill_json = JSON.parse(String(read(orderfill_fixture)))
    f = Rhea.oandafill(orderfill_json)
    @test f.type == :fill
    @test f.instrument == orderfill_json["orderFillTransaction"]["instrument"]

    position_fixture = joinpath(root, "position_eur_usd.json")
    position_json = JSON.parse(String(read(position_fixture)))
    time = DateTime(2025)
    p = Position(position_json["position"], time)
    @test p isa Position
    @test p.units == 350.0
    @test p.price == 1.13032

    # Mixed data
    data = Dict(
        "long" => Dict("averagePrice" => "1.13032", "units" => "350"),
        "short" => Dict("averagePrice" => "1.13050", "units" => "100")
    )
    # (1.13032 * 350 - 1.13050 * 100) / 250
    expected_price = (1.13032 * 350 - 1.13050 * 100) / 250
    p = Position(data, time)
    @test p.units == 250.0
    @test p.price ≈ expected_price
end

include("oanda_live.jl")
