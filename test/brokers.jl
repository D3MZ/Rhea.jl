using Rhea
using Test
using Dates
using StaticArrays
using JSON

# --- Helpers ---

materializeconfig(path, root) = begin
    config = JSON.parsefile(path)
    config["instruments"] = map(config["instruments"]) do inst
        file = inst["file"]
        inst["file"] = startswith(file, "/") ? file : root * "/" * file
        inst
    end
    out = tempname()
    open(out, "w") do io
        JSON.print(io, config)
    end
    out
end

create_temp_csv(filename, content) = begin
    path = joinpath(tempdir(), filename)
    open(path, "w") do io
        write(io, content)
    end
    path
end

# --- DataBroker Tests ---

@testset "DataBroker" begin
    root = dirname(@__DIR__)
    config_path = root * "/test/fixtures/brokers/DataBrokerTest.json"
    resolved_config = materializeconfig(config_path, root)
    broker = DataBroker(configpath=resolved_config)

    @testset "Initialization" begin
        state = State(broker)
        @test state.cash == 100000.0
        @test length(state.instruments) == 2
        @test state.currency == :USD

        # Initial time should be the latest across all streams
        # EURUSD: 10:00:00, USDJPY: 10:01:00
        @test state.time == DateTime(2024, 1, 1, 10, 1, 0)

        # Initial quotes
        @test state.instruments[1].symbol == :EUR
        @test state.instruments[2].symbol == :USD
        @test mid(state.quotes[1]) == 1.08025
        @test mid(state.quotes[2]) == 140.025
    end

    @testset "Chronological Transition" begin
        # EURUSD events: 10:00, 10:02, 10:04, 10:06 (ends)
        # USDJPY events: 10:01, 10:03, 10:05, 10:07, 10:09, 10:11
        # Tests out-of-sync data where one instrument ends before the other

        broker = DataBroker(configpath=resolved_config)
        state = State(broker) # s0 at 10:01

        times = DateTime[]
        symbols = Symbol[]

        # Collect all events until exhaustion
        for _ in 1:20
            state_next = State(broker, state)
            state_next.time <= state.time && break

            push!(times, state_next.time)
            for i in eachindex(state_next.quotes)
                if state_next.quotes[i].time != state.quotes[i].time
                    push!(symbols, state_next.instruments[i].symbol)
                end
            end
            state = state_next
        end

        # Sequence starting from 10:01 (init):
        # 10:02 (EUR), 10:03 (USD), 10:04 (EUR), 10:05 (USD), 10:06 (EUR), 10:07 (USD), 10:09 (USD), 10:11 (USD)
        expected_times = [
            DateTime(2024, 1, 1, 10, 2, 0),
            DateTime(2024, 1, 1, 10, 3, 0),
            DateTime(2024, 1, 1, 10, 4, 0),
            DateTime(2024, 1, 1, 10, 5, 0),
            DateTime(2024, 1, 1, 10, 6, 0),
            DateTime(2024, 1, 1, 10, 7, 0),
            DateTime(2024, 1, 1, 10, 9, 0),
            DateTime(2024, 1, 1, 10, 11, 0),
        ]
        expected_symbols = [:EUR, :USD, :EUR, :USD, :EUR, :USD, :USD, :USD]

        @test times == expected_times
        @test symbols == expected_symbols
        @test all(diff(times) .> Dates.Second(0))
    end

    @testset "FX Conversion Paths" begin
        # New broker instance
        broker = DataBroker(configpath=resolved_config)
        state = State(broker)
        # EURUSD: term is USD, account is USD -> empty path
        @test state.paths[1, 1] == 0
        # USDJPY: term is JPY, account is USD -> JPY to USD path
        @test state.paths[2, 1] == 4 # Edge 4 is JPYUSD bid (inverse of USDJPY ask)
    end

    @testset "Trading Loop Integration" begin
        broker = DataBroker(configpath=resolved_config)
        agent = RandomAgent()
        reward = PnLReward()

        # Run 5 steps
        stats = Stats(State(broker))
        final_state = run!(5, agent, broker, reward, stats)

        # Verify that cash changed (fees/PnL)
        @test final_state.cash != 100000.0
        # Verify that positions were taken
        @test any(!iszero(p.units) for p in final_state.positions)
        # Verify that NLV is not astronomical (sanity check)
        @test abs(nlv(final_state)) < 1e9
    end

    @testset "Stream Merging and Warmup" begin
        csv_a = "timestamp,open,high,low,close,volume,transactions,vwap\n" *
                "2023-01-01T00:00:01.000,0,1.0002,1.0001,0,100,100,0\n" *
                "2023-01-01T00:00:02.000,0,1.0004,1.0003,0,100,100,0\n" *
                "2023-01-01T00:00:10.000,0,1.0006,1.0005,0,100,100,0\n" *
                "2023-01-01T00:00:11.000,0,1.0008,1.0007,0,100,100,0\n"

        csv_b = "timestamp,open,high,low,close,volume,transactions,vwap\n" *
                "2023-01-01T00:00:10.000,0,100.02,100.01,0,100,100,0\n" *
                "2023-01-01T00:00:11.000,0,100.04,100.03,0,100,100,0\n"

        path_a = create_temp_csv("stream_a.csv", csv_a)
        path_b = create_temp_csv("stream_b.csv", csv_b)

        config_json = """
        {
            "account_currency": "USD",
            "cash": 100000.0,
            "instruments": [
                {"symbol": "A", "currency": "USD", "step": 0.0001, "size": 1.0, "margin": 0.0, "fee": 0.0, "file": "$(escape_string(path_a))", "index": 1},
                {"symbol": "B", "currency": "USD", "step": 0.01, "size": 1.0, "margin": 0.0, "fee": 0.0, "file": "$(escape_string(path_b))", "index": 2}
            ]
        }
        """
        config_path = joinpath(tempdir(), "test_config.json")
        write(config_path, config_json)

        broker = DataBroker(configpath=config_path)
        s = State(broker)

        @test s.time == DateTime("2023-01-01T00:00:10")
        @test s.quotes[1].time == DateTime("2023-01-01T00:00:10")
        @test s.quotes[2].time == DateTime("2023-01-01T00:00:10")

        s_next = State(broker, s)
        @test s_next.time == DateTime("2023-01-01T00:00:11")
        @test s_next.quotes[1].time == DateTime("2023-01-01T00:00:11")
        @test s_next.quotes[2].time == DateTime("2023-01-01T00:00:10") 

        s_next_2 = State(broker, s_next)
        @test s_next_2.time == DateTime("2023-01-01T00:00:11")
        @test s_next_2.quotes[1].time == DateTime("2023-01-01T00:00:11")
        @test s_next_2.quotes[2].time == DateTime("2023-01-01T00:00:11")

        rm(path_a); rm(path_b); rm(config_path)
    end

    @testset "Uneven Stream Agent Logic" begin
        csv_eur = "timestamp,open,high,low,close,volume,transactions,vwap\n" *
                  "2024-01-01T10:00:00.000,1.08,1.08,1.08,1.08,100,100,1.08\n" *
                  "2024-01-01T10:02:00.000,1.09,1.09,1.09,1.09,100,100,1.09\n"
        
        csv_jpy = "timestamp,open,high,low,close,volume,transactions,vwap\n" *
                  "2024-01-01T10:01:00.000,140.0,140.0,140.0,140.0,100,100,140.0\n" *
                  "2024-01-01T10:03:00.000,141.0,141.0,141.0,141.0,100,100,141.0\n" *
                  "2024-01-01T10:05:00.000,142.0,142.0,142.0,142.0,100,100,142.0\n"

        path_eur = create_temp_csv("uneven_eur.csv", csv_eur)
        path_jpy = create_temp_csv("uneven_jpy.csv", csv_jpy)

        config_json = """
        {
            "account_currency": "USD",
            "cash": 100000.0,
            "instruments": [
                {"symbol": "EUR", "currency": "USD", "step": 0.0001, "size": 1.0, "margin": 1.0, "fee": 0.0, "file": "$(escape_string(path_eur))", "index": 1},
                {"symbol": "USD", "currency": "JPY", "step": 0.01, "size": 1.0, "margin": 1.0, "fee": 0.0, "file": "$(escape_string(path_jpy))", "index": 2}
            ]
        }
        """
        config_path = joinpath(tempdir(), "uneven_config.json")
        write(config_path, config_json)

        broker = DataBroker(configpath=config_path)
        agent = RandomAgent()
        reward = PnLReward()
        stats = Stats()

        s_final = run!(10, agent, broker, reward, stats)

        @test s_final.time == DateTime("2024-01-01T10:05:00")
        @test s_final.quotes[1].time == DateTime("2024-01-01T10:02:00") # Stale
        @test s_final.quotes[2].time == DateTime("2024-01-01T10:05:00") # Current

        rm(path_eur); rm(path_jpy); rm(config_path)
    end
end