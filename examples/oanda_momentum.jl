using Rhea

using Dates
using Logging
using Plots
using Statistics

timestamp() = Dates.format(Dates.now(), "yyyymmdd_HHMMSS")

linesfromstats(path) = readlines(path)
valuesfromlines(lines) = parse.(Float64, last.(split.(lines, ",")))

function sharpefromvalues(values)
    Δ = diff(log.(values))
    μ = mean(Δ)
    σ = std(Δ)
    μ / (σ + eps())
end

function sharpefromstats(path)
    lines = linesfromstats(path)
    count = length(lines)
    sharpe = count > 50 ? sharpefromvalues(valuesfromlines(lines)) : missing
    (count=count, sharpe=sharpe)
end

function run_simulation(; steps=60, out=joinpath(@__DIR__, "..", "artifacts", "oanda_momentum_$(timestamp()).png"))
    broker = OandaBroker()
    state = State(broker)
    closepositions!(broker, state)
    agent = MomentumAgent(state; α=0.2, β=0.02, risk=0.8, cash=0.1)
    reward = LogReturnReward()
    stats = Stats(state)

    try
        run!(steps, agent, broker, reward, stats)
    finally
        stop!(broker)
        closepositions!(broker, state)
        update!(stats, broker.state, missing)
    end

    mkpath(dirname(out))
    plot(stats, out)
    metrics = sharpefromstats(stats.path)
    @info "stats=$(stats.path)"
    @info "lines=$(metrics.count)"
    @info "sharpe=$(metrics.sharpe)"
    (final_value=nlv(broker.state), out=out, stats=stats.path, sharpe=metrics.sharpe)
end

result = invokelatest(run_simulation)
@info "final_value=$(round(result.final_value; digits=2))"
@info "saved=$(result.out)"
