using Logging
using Rhea: getmarginavailable, getnav, islong, isshort

navvalue(s) = nlv(s)
marginavailablevalue(s) = availablemargin(s)

@testset "OandaBroker (live)" begin
    rtol_margin = 1e-2
    atol_margin = 200.0
    enabled = get(ENV, "Rhea_OANDA_LIVE", "") in ("1", "true", "TRUE")
    enabled || (Test.@test_skip "set ENV[Rhea_OANDA_LIVE]=1 to enable live OANDA tests"; return)

    configpath = joinpath(@__DIR__, "..", "config.json")
    isfile(configpath) || (Test.@test_skip "missing config.json at repo root"; return)

    broker = OandaBroker(; configpath=configpath)
    config = broker.config

    @testset "Helpers" begin
        # getinstruments
        raw_insts = getinstruments(config)
        @test raw_insts isa AbstractVector
        @test !isempty(raw_insts)
        inst = Instrument(first(raw_insts), 1)
        @test inst isa Instrument
        @test inst.symbol isa Symbol

        # getquotes
        time, quotes = getquotes(config)
        @test time isa DateTime
        @test quotes isa AbstractVector
        book = Book(first(quotes))
        @test book isa Book
        @test !isempty(book.bid)

        # getpositions
        pos_dict = getpositions(config, now())
        @test pos_dict isa AbstractDict
        if !isempty(pos_dict)
            @test first(values(pos_dict)) isa Position
        end

        # getcash
        cash = getcash(config)
        @test cash isa Number
        @test cash >= 0
    end

    # Test State initialization
    state = State(broker)
    @test state isa State
    @test length(state.quotes) == length(config.symbols)
    @test length(state.positions) == length(config.symbols)
    @test isapprox(state.cash, getcash(config); rtol=1e-6, atol=1e-2)
    @test isapprox(navvalue(state), getnav(config); rtol=1e-3, atol=1.0)
    @test isapprox(marginavailablevalue(state), getmarginavailable(config); rtol=rtol_margin, atol=atol_margin)
    @info "oanda live init" nlv = nlv(state) nav_api = getnav(config) margin_available = marginavailablevalue(state) margin_available_api = getmarginavailable(config) cash = state.cash cash_api = getcash(config)

    state = closepositions!(broker, state)
    try
        @test isapprox(state.cash, getcash(config); rtol=1e-6, atol=1e-2)
        @test isapprox(navvalue(state), getnav(config); rtol=1e-3, atol=1.0)
        @test isapprox(marginavailablevalue(state), getmarginavailable(config); rtol=rtol_margin, atol=atol_margin)


        # Test Flip: 100% Long -> 100% Short (using 90% to be safe)
        @info "Test Flip: Long -> Short"
        w_long = vcat([0.9, 0.0], zeros(length(state.instruments) - 2), [0.1]) # 90% Long Inst 1
        orders_long = targetorders(state, w_long)
        state_long = State(broker, state, orders_long)
        @test islong(state_long.positions[1])

        w_short = vcat([-0.9, 0.0], zeros(length(state.instruments) - 2), [0.1]) # 90% Short Inst 1
        orders_short = targetorders(state_long, w_short) # Should generate Sell 2x size
        state_short = State(broker, state_long, orders_short)
        @test isshort(state_short.positions[1])

        state = closepositions!(broker, state_short)

        # Test Split Flip: [-0.45, 0.45] -> [0.45, -0.45] (Two instruments)
        if length(state.instruments) >= 2
            @info "Test Split Flip"
            w_split1 = vcat([-0.45, 0.45], zeros(length(state.instruments) - 2), [0.1])
            orders_split1 = targetorders(state, w_split1)
            state_s1 = State(broker, state, orders_split1)
            @test isshort(state_s1.positions[1])
            @test islong(state_s1.positions[2])

            w_split2 = vcat([0.45, -0.45], zeros(length(state.instruments) - 2), [0.1])
            orders_split2 = targetorders(state_s1, w_split2)
            # This requires sorting! Sell Long(2) -> Buy Short(2), Buy Short(1) -> Sell Long(1)
            # Both legs flip. 
            state_s2 = State(broker, state_s1, orders_split2)
            @test islong(state_s2.positions[1])
            @test isshort(state_s2.positions[2])

            state = closepositions!(broker, state_s2)
        end
    finally
        stop!(broker)
        closepositions!(broker, state)
    end
end
