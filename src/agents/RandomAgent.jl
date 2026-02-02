export RandomAgent

struct RandomAgent{R<:AbstractRNG} <: Agent
    rng::R
end

RandomAgent(; seed::Integer=1) = RandomAgent(MersenneTwister(seed))

function Orders(a::RandomAgent, s::State)
    n = length(s.positions)
    w = rand(a.rng, n + 1)
    w = w ./ sum(w)
    targetorders(s, w)
end
