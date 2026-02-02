using Rhea
using Random
using Test

function runnlv(steps, agent, broker, reward)
    state = State(broker)
    initial_cash = state.cash
    ran = false
    for _ in 1:steps
        state_next = State(broker, state)
        state_next === state && break
        orders = Orders(agent, state_next)
        state₂ = State(broker, state_next, orders)
        r = Reward(reward, state_next, state₂)
        agent = Agent(agent, state_next, orders, r, state₂)
        state = state₂
        ran || (initial_cash = state.cash; ran = true)
        state.cash <= initial_cash / 2 && break
    end
    nlv(ran ? state : State(broker))
end

steps = 1_000
reward = PnLReward()
config_path = joinpath(@__DIR__, "databroker", "config.json")

cases = [
    ("RandomWalkBroker", "RandomAgent", () -> RandomWalkBroker(MersenneTwister(1); n=5, σ=0.01, spread=0.0005, cash=100_000.0, mid=100.0), s -> RandomAgent(; seed=2), 38677.30139005501),
    ("RandomWalkBroker", "RuleBasedAgent", () -> RandomWalkBroker(MersenneTwister(1); n=5, σ=0.01, spread=0.0005, cash=100_000.0, mid=100.0), s -> RuleBasedAgent(EqualWeight()), 158224.94581503738),
    ("RandomWalkBroker", "MomentumAgent", () -> RandomWalkBroker(MersenneTwister(1); n=5, σ=0.01, spread=0.0005, cash=100_000.0, mid=100.0), s -> MomentumAgent(s), 248388.95467892286),
    ("RandomWalkBroker", "MeanReversionAgent", () -> RandomWalkBroker(MersenneTwister(1); n=5, σ=0.01, spread=0.0005, cash=100_000.0, mid=100.0), s -> MeanReversionAgent(s), 100000.0),
    ("RandomWalkBroker", "StatArbAgent", () -> RandomWalkBroker(MersenneTwister(1); n=5, σ=0.01, spread=0.0005, cash=100_000.0, mid=100.0), s -> StatArbAgent(s, MersenneTwister(3); κ=0.05, η=1e-3, α=0.995, entry=1.0, exit=0.25, risk=0.2, cash=0.5), 100000.0),
    ("RandomWalkBroker", "PatternMatchAgent", () -> RandomWalkBroker(MersenneTwister(1); n=5, σ=0.01, spread=0.0005, cash=100_000.0, mid=100.0), s -> PatternMatchAgent(length(s.positions); k=50, lookback=10, range_size=0.0005), 46649.355050478276),
    ("DataBroker", "RandomAgent", () -> DataBroker(configpath=config_path), s -> RandomAgent(; seed=2), 41624.03136496582),
    ("DataBroker", "RuleBasedAgent", () -> DataBroker(configpath=config_path), s -> RuleBasedAgent(EqualWeight()), 100216.61979525007),
    ("DataBroker", "MomentumAgent", () -> DataBroker(configpath=config_path), s -> MomentumAgent(s), 44529.26978082993),
    ("DataBroker", "MeanReversionAgent", () -> DataBroker(configpath=config_path), s -> MeanReversionAgent(s), 100000.0),
    ("DataBroker", "StatArbAgent", () -> DataBroker(configpath=config_path), s -> StatArbAgent(s, MersenneTwister(3); κ=0.05, η=1e-3, α=0.995, entry=1.0, exit=0.25, risk=0.2, cash=0.5), 100000.0),
    ("DataBroker", "PatternMatchAgent", () -> DataBroker(configpath=config_path), s -> PatternMatchAgent(length(s.positions); k=50, lookback=10, range_size=0.0005), 100000.0),
]

@testset "Deterministic NLV" begin
    results = Vector{Tuple{String,String,Float64,Float64}}(undef, length(cases))
    Threads.@threads for i in eachindex(cases)
        broker_name, agent_name, build_broker, build_agent, expected = cases[i]
        broker = build_broker()
        agent = build_agent(State(broker))
        value = runnlv(steps, agent, broker, reward)
        results[i] = (broker_name, agent_name, value, expected)
    end
    for (broker_name, agent_name, value, expected) in results
        @test value ≈ expected
    end
end