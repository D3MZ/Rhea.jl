using StaticArrays

@testset "Core cash" begin
    initial_cash = 10_000.0
    m = 100.0
    rng = MersenneTwister(1)
    broker = RandomWalkBroker(rng; n=1, σ=0.0, spread=0.0, fee=0.0, cash=initial_cash, mid=m)
    state₀ = State(broker)

    @test state₀.cash == initial_cash

    state₁ = State(broker, state₀)
    @test mid(first(state₁.quotes)) == m

    instrument = first(state₀.instruments)

    state₂ = State(broker, state₀, [MarketOrder(10.0, instrument)])
    @test state₂.cash == initial_cash

    state₃ = State(broker, state₂, [MarketOrder(-3.0, instrument)])
    @test state₃.cash == initial_cash

    state₄ = State(broker, state₃, [MarketOrder(-8.0, instrument)])
    @test state₄.cash == initial_cash

    state₅ = State(broker, state₄, [MarketOrder(1.0, instrument)])
    @test state₅.cash == initial_cash
end

@testset "Flat position cash" begin
    initial_cash = 10_000.0
    m = 100.0
    broker = RandomWalkBroker(MersenneTwister(2); n=1, σ=0.0, spread=0.0, fee=0.0, cash=initial_cash, mid=m)
    state₀ = State(broker)
    instrument = first(state₀.instruments)

    state₁ = State(broker, state₀, [MarketOrder(-5.0, instrument)])
    state₂ = State(broker, state₁, [MarketOrder(5.0, instrument)])

    @test state₂.cash == initial_cash
end

@testset "Cash with spread fee price" begin
    initial_cash = 10_000.0
    mid₀ = 100.0
    mid₁ = 120.0
    spread = 0.5
    fee = 0.25

    broker = RandomWalkBroker(MersenneTwister(3); n=1, σ=0.0, spread=spread, fee=fee, cash=initial_cash, mid=mid₀)
    state₀ = State(broker)
    instrument = first(state₀.instruments)

    state₁ = State(broker, state₀, [MarketOrder(10.0, instrument)])
    # In margin broker, only fee is subtracted
    expected₁ = initial_cash - 10.0 * fee
    @test state₁.cash == expected₁

    state₃ = State(broker, state₁, [MarketOrder(-10.0, instrument)])
    # Closing at 50.0 (bid) when pos was opened at 150.0 (ask). PnL = (50-150)*10 = -1000.
    expected₃ = expected₁ - 10.0 * (150.0 - 50.0) - 10.0 * fee
    @test state₃.cash == expected₃
end

@testset "Position math" begin
    time = DateTime(2025)
    p1 = Position(100.0, 10.0, time)
    p2 = Position(110.0, 5.0, time)
    p3 = p1 + p2
    @test p3.units == 15.0
    @test p3.price ≈ (100 * 10 + 110 * 5) / 15

    p1 = Position(100.0, 10.0, time)
    p2 = Position(120.0, -5.0, time)
    p3 = p1 + p2
    @test p3.units == 5.0
    @test p3.price ≈ (100 * 10 - 120 * 5) / 5

    p1 = Position(100.0, 10.0, time)
    p2 = Position(120.0, -15.0, time)
    p3 = p1 + p2
    @test p3.units == -5.0
    @test p3.price ≈ (100 * 10 - 120 * 15) / -5

    p1 = Position(100.0, -10.0, time)
    p2 = Position(80.0, 5.0, time)
    p3 = p1 + p2
    @test p3.units == -5.0
    @test p3.price ≈ (-100 * 10 + 80 * 5) / -5

    p1 = Position(100.0, -10.0, time)
    p2 = Position(80.0, 15.0, time)
    p3 = p1 + p2
    @test p3.units == 5.0
    @test p3.price ≈ (-100 * 10 + 80 * 15) / 5

    p1 = Position(100.0, -10.0, time)
    p2 = Position(90.0, -5.0, time)
    p3 = p1 + p2
    @test p3.units == -15.0
    @test p3.price ≈ (100 * 10 + 90 * 5) / 15

    p1 = Position(100.0, 10.0, time)
    p2 = Position(120.0, -10.0, time)
    p3 = p1 + p2
    @test p3.units == 0.0
    @test p3.price == 0.0
end

@testset "State balances" begin
    initial_cash = 10_000.0
    m = 100.0
    broker = RandomWalkBroker(MersenneTwister(4); n=1, σ=0.0, spread=0.0, fee=0.0, margin=1.0, cash=initial_cash, mid=m)
    state₀ = State(broker)
    instrument = first(state₀.instruments)

    @test nlv(state₀) == initial_cash
    @test usedmargin(state₀) == 0.0
    @test availablemargin(state₀) == initial_cash

    state₁ = State(broker, state₀, [MarketOrder(10.0, instrument)])
    @test nlv(state₁) == initial_cash
    @test usedmargin(state₁) == 10.0 * m
    @test availablemargin(state₁) == initial_cash - 10.0 * m

    state₂ = State(broker, state₁, [MarketOrder(-5.0, instrument)])
    @test nlv(state₂) ≈ initial_cash # Spread is 0, price is constant, so profit=0
    @test usedmargin(state₂) == 5.0 * m
    @test availablemargin(state₂) == initial_cash - 5.0 * m

    state₃ = State(broker, state₂, [MarketOrder(-10.0, instrument)])
    @test nlv(state₃) ≈ initial_cash
    @test usedmargin(state₃) == 5.0 * m
    @test availablemargin(state₃) == initial_cash - 5.0 * m

    state₄ = State(broker, state₃, [MarketOrder(5.0, instrument)])
    @test nlv(state₄) ≈ initial_cash
    @test usedmargin(state₄) == 0.0
    @test availablemargin(state₄) == initial_cash
end

@testset "NLV" begin
    i = Instrument{Float64}(:TEST, :USD, 1.0, 1.0, 1.0, 0.0, 1)
    time = DateTime(2025)
    b = Book(time, SVector(Price(101.0, 1.0)), SVector(Price(102.0, 1.0)))
    # Create a dummy state where currency matches instrument currency (conversion = 1.0)
    s = State(time, SVector(i), SVector(b), SVector(Position(0.0, 0.0, time)), 0.0, :USD, SVector(101.0, 1 / 102.0), zeros(Int, 1, 4))

    long_pos = Position(100.0, 10.0, time)
    short_pos = Position(100.0, -10.0, time)
    flat_pos = Position(100.0, 0.0, time)

    @test nlv(long_pos, b, i, s) == (101.0 - 100.0) * 10.0
    @test nlv(short_pos, b, i, s) == (100.0 - 102.0) * 10.0
    @test nlv(flat_pos, b, i, s) == 0.0
end

@testset "Multi-currency RandomWalkBroker" begin
    rng = MersenneTwister(123)
    # Goal: Trade an asset in EUR while account is in USD.
    # We need a EUR_USD instrument to provide the rate.
    # ASSET1 is in EUR, EUR_USD is in USD.
    symbols = [:ASSET1, :EUR_USD]
    currencies = [:EUR, :USD]
    # ASSET1 price is in EUR. EUR_USD price is in USD (price of 1 EUR in USD).
    broker = RandomWalkBroker(rng; symbols=symbols, instrument_currencies=currencies, cash=10_000.0, mid=1.1, currency=:USD, pairs=[:EUR => :USD])
    state = State(broker)

    @test state.currency == :USD
    @test state.instruments[1].currency == :EUR
    @test state.instruments[2].currency == :USD

    # Path check: ASSET1(EUR) -> account(USD) should have a path.
    # EUR_USD is instrument 2. rates are (bid, 1/ask).
    # Path should be instrument 2 bid (rate index 3).
    @test state.paths[1, 1] != 0
    # EUR_USD is in USD already, so its path to USD should be empty.
    @test state.paths[2, 1] == 0

    # Check conversion factor for ASSET1
    # EUR_USD mid is 1.1, spread is small.
    confac = conversion(state.instruments[1], state)
    @test confac ≈ 1.1 * (1 - 0.0005) # bestbid of EUR_USD
end

@testset "Path Connectivity Checks" begin
    # Test Case 1: Disconnected Graph
    # EUR_USD (denominated in USD) -> Account is JPY
    # No way to get from USD to JPY with just this pair.

    i1 = Instrument{Float64}(:EUR_USD, :USD, 1e-4, 1.0, 0.02, 0.0, 1)
    insts = [i1]
    pairs = [:EUR => :USD]
    account_currency = :JPY

    @test_throws ErrorException Persephone.build_paths(insts, pairs, account_currency)

    try
        Persephone.build_paths(insts, pairs, account_currency)
    catch e
        @test e isa ErrorException
        @test contains(e.msg, "No conversion path found")
    end

    # Test Case 2: Connected Graph
    # EUR_USD (USD) -> USD_JPY (JPY) -> Account JPY
    i2 = Instrument{Float64}(:USD_JPY, :JPY, 1e-2, 1.0, 0.02, 0.0, 2)
    insts2 = [i1, i2]
    pairs2 = [:EUR => :USD, :USD => :JPY]

    paths = Persephone.build_paths(insts2, pairs2, account_currency)
    @test size(paths) == (2, 4)
    @test paths[1, 1] != 0 # EUR_USD (USD) -> JPY needs conversion
    @test paths[2, 1] == 0  # USD_JPY (JPY) is already in home currency
end
@testset "Incremental State Updates" begin
    time₁ = DateTime(2025, 1, 1)
    time₂ = DateTime(2025, 1, 1, 0, 0, 1)

    inst1 = Instrument{Float64}(:EUR_USD, :USD, 1e-4, 1.0, 1.0, 0.0, 1)
    inst2 = Instrument{Float64}(:GBP_USD, :USD, 1e-4, 1.0, 1.0, 0.0, 2)
    insts = SVector(inst1, inst2)

    book1_v1 = Book(time₁, SVector(Price(1.1000, 1.0)), SVector(Price(1.1001, 1.0)))
    book2_v1 = Book(time₁, SVector(Price(1.3000, 1.0)), SVector(Price(1.3001, 1.0)))
    quotes = SVector(book1_v1, book2_v1)

    positions = SVector(Position(0.0, 0.0, time₁), Position(0.0, 0.0, time₁))
    paths = zeros(Int, 2, 4)

    # EUR_USD is idx 1. rates -> (bid, 1/ask)
    # rates index: 2*1-1=1 (EUR_USD bid), 2*1=2 (EUR_USD 1/ask), 2*2-1=3 (GBP_USD bid), 2*2=4 (GBP_USD 1/ask)

    s1 = State(time₁, insts, quotes, positions, 10000.0, :USD, paths)

    @test s1.time == time₁
    @test s1.rates[1] == 1.1000
    @test s1.rates[2] == 1 / 1.1001
    @test s1.rates[3] == 1.3000
    @test s1.rates[4] == 1 / 1.3001

    # Update EUR_USD (idx 1)
    book1_v2 = Book(time₂, SVector(Price(1.1005, 1.0)), SVector(Price(1.1006, 1.0)))
    s2 = State(s1, book1_v2, 1)

    @test s2.time == time₂
    @test s2.quotes[1] == book1_v2
    @test s2.quotes[2] == book2_v1

    # Rates update
    @test s2.rates[1] == 1.1005
    @test s2.rates[2] == 1 / 1.1006
    @test s2.rates[3] == 1.3000 # Unchanged
    @test s2.rates[4] == 1 / 1.3001 # Unchanged
end
