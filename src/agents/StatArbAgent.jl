export StatArbAgent

using Random


function spreadcost(s::State, w::AbstractVector)
    u = abs.(w)
    m = sum(u) + eps(eltype(u))
    δ = map(s.quotes, u) do book, weight
        (bestask(book) - bestbid(book)) / (mid(book) + eps(eltype(weight))) * weight
    end
    sum(δ) / m
end

mutable struct StatArbAgent{N,T<:AbstractFloat,R} <: Agent
    κ::T
    η::T
    α::T
    entry::T
    exit::T
    c::T
    risk::T
    cash_target::T
    w::SVector{N,T}
    xₜ₋₁::SVector{N,T}
    μ::T
    σ²::T
    q::T
    rng::R
end

function StatArbAgent(s::State, rng::AbstractRNG=Random.default_rng(); κ=0.05, η=1e-3, α=0.99, entry=1.0, exit=0.25, c=1.0, risk=0.9, cash=0.0)
    T = typeof(s.cash)
    x = logprices(s)
    N = length(x)
    w = normalize(neutral(SVector{N,T}(randn(rng, T, N))))
    μ = sum(w .* x)
    σ² = one(T)
    StatArbAgent{N,T,typeof(rng)}(T(κ), T(η), T(α), T(entry), T(exit), T(c), T(risk), T(cash), w, x, μ, σ², zero(T), rng)
end

function Orders(a::StatArbAgent, s::State)
    T = typeof(s.cash)
    xₜ = logprices(s)
    v = sum(a.w .* xₜ)
    z = zscore(v, a.μ, a.σ²)
    δ = spreadcost(s, a.w)
    σ = sqrt(a.σ² + eps(one(a.σ²)))
    entry_threshold = a.entry + a.c * δ / σ

    q = z > entry_threshold ? -a.risk :
        z < -entry_threshold ? a.risk :
        abs(z) < a.exit ? zero(T) :
        a.q
    a.q = q

    target_weights = q * (one(T) - a.cash_target) .* a.w
    targetorders(s, target_weights)
end

function Agent(a::StatArbAgent{N,T}, ::State, ::Orders, ::Any, s₂::State) where {N,T<:AbstractFloat}
    xₜ = logprices(s₂)
    Δx = xₜ .- a.xₜ₋₁
    sₜ₋₁ = sum(a.w .* a.xₜ₋₁)
    e = sum(a.w .* Δx) + a.κ * sₜ₋₁
    g = 2 * e .* (Δx .+ a.κ .* a.xₜ₋₁)
    a.w = normalize(neutral(a.w .- a.η .* g))
    v = sum(a.w .* xₜ)

    a.μ = a.α * a.μ + (one(T) - a.α) * v
    d = v - a.μ
    a.σ² = a.α * a.σ² + (one(T) - a.α) * d^2
    a.xₜ₋₁ = xₜ
    a
end
