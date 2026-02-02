export MomentumAgent

signal(fast, slow) = normalize(neutral(fast .- slow))

mutable struct MomentumAgent{N,T<:AbstractFloat} <: Agent
    α::T
    β::T
    risk::T
    cash_target::T
    fast::SVector{N,T}
    slow::SVector{N,T}
    prev::SVector{N,T}
    vol::SVector{N,T}
    prev_time::SVector{N,DateTime}
end

function MomentumAgent(s::State; α=0.2, β=0.02, risk=0.9, cash=0.1)
    T = typeof(s.cash)
    x = logprices(s)
    N = length(x)
    fast = SVector{N,T}(x)
    slow = SVector{N,T}(x)
    prev = SVector{N,T}(x)
    vol = SVector{N,T}(fill(one(T), N))
    prev_time = SVector{N,DateTime}(getfield.(s.quotes, :time))
    MomentumAgent{N,T}(T(α), T(β), T(risk), T(cash), fast, slow, prev, vol, prev_time)
end

weights(a::MomentumAgent) =
    let w = l1sphere(signal(a.fast, a.slow))
        w = l1sphere(w ./ (a.vol .+ eps()))
        vcat(a.risk .* (one(eltype(w)) - a.cash_target) .* w, a.cash_target)
    end

Orders(a::MomentumAgent, s::State) = targetorders(s, weights(a))

function Agent(a::MomentumAgent{N,T}, ::State, ::Orders, ::Any, s₂::State) where {N,T<:AbstractFloat}
    xₜ = logprices(s₂)
    tₜ = getfield.(s₂.quotes, :time)
    Δt = tₜ .- a.prev_time
    Δτ = T.(Dates.value.(Δt)) ./ T(1000)
    Δτ⁺ = max.(Δτ, zero(T))
    scale = sqrt.(Δτ⁺ .+ eps(one(T)))
    rₜ = ifelse.(Δτ⁺ .> 0, (xₜ .- a.prev) ./ scale, zero(T))
    a.fast = a.α .* xₜ .+ (one(T) - a.α) .* a.fast
    a.slow = a.β .* xₜ .+ (one(T) - a.β) .* a.slow
    a.vol = sqrt.(a.β .* (rₜ .^ 2) .+ (one(T) - a.β) .* (a.vol .^ 2))
    a.prev = ifelse.(Δτ⁺ .> 0, xₜ, a.prev)
    a.prev_time = ifelse.(Δτ⁺ .> 0, tₜ, a.prev_time)
    a
end
