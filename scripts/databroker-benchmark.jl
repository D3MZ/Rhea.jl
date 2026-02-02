using Persephone
using BenchmarkTools
using Logging

config_path = "configs/DataBroker.json"

@info "Benchmark start" config_path = config_path

result = @benchmark begin
    steps = 0
    state = initial_state
    while true
        state_obs = State(broker, state)
        state_obs === state && break
        
        orders = Orders(agent, state_obs)
        state = State(broker, state_obs, orders)
        r = Reward(reward, state_obs, state)
        agent = Agent(agent, state_obs, orders, r, state)
        
        steps += 1
    end
    @info (steps=steps, final_value=nlv(state), final_time=state.time)
end setup=(broker = DataBroker(configpath=$config_path); agent = NoTradeAgent(); reward = PnLReward(); initial_state = State(broker))

display(result)

# 1.33 × 10⁶ steps/s (≈ 1.33 million steps per second).
# ┌ Info: Benchmark start
# └   config_path = "configs/DataBroker.json"
# [ Info: (steps = 6706099, final_value = 100000.0, final_time = Dates.DateTime("2025-10-23T23:59:00"))
# [ Info: (steps = 6706099, final_value = 100000.0, final_time = Dates.DateTime("2025-10-23T23:59:00"))
# [ Info: (steps = 6706099, final_value = 100000.0, final_time = Dates.DateTime("2025-10-23T23:59:00"))
# BenchmarkTools.Trial: 1 sample with 1 evaluation per sample.
#  Single result which took 5.041 s (0.00% GC) to evaluate,
#  with a memory estimate of 10.48 KiB, over 185 allocations.