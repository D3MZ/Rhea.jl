export MeanReversionAgent

using LinearAlgebra, Statistics
import Base: push!

mutable struct RollingBuffer{T}
    data::Matrix{T}
    head::Int
    count::Int
end

RollingBuffer(n, capacity, ::Type{T}=Float64) where {T} = RollingBuffer(zeros(T, n, capacity), 1, 0)

capacity(b::RollingBuffer) = size(b.data, 2)

function push!(b::RollingBuffer, x)
    copyto!(view(b.data, :, b.head), x)
    b.head = b.head % capacity(b) + 1
    b.count = min(b.count + 1, capacity(b))
    b
end

function window(b::RollingBuffer)
    m = b.count
    c = capacity(b)
    m < c && return b.data[:, 1:m]
    b.head == 1 && return b.data
    hcat(view(b.data, :, b.head:c), view(b.data, :, 1:b.head-1))
end

samples(seconds, hz) = Int(round(seconds * hz))

function groups(n)
    g = Vector{Vector{Int}}()
    for k in 2:n
        append!(g, combos(n, k))
    end
    g
end

function groups(n, max_k)
    g = Vector{Vector{Int}}()
    kmax = min(n, max_k)
    for k in 2:kmax
        append!(g, combos(n, k))
    end
    g
end

function combos(n, k)
    res = Vector{Vector{Int}}()
    idx = collect(1:k)
    while true
        push!(res, copy(idx))
        i = k
        while i >= 1 && idx[i] == i + n - k
            i -= 1
        end
        i == 0 && break
        idx[i] += 1
        for j in i+1:k
            idx[j] = idx[j-1] + 1
        end
    end
    res
end

function johansen(x)
    n, t = size(x)
    Δx = diff(x; dims=2)
    xₜ₋₁ = x[:, 1:end-1]
    x₀ = Δx .- mean(Δx; dims=2)
    x₁ = xₜ₋₁ .- mean(xₜ₋₁; dims=2)
    s₀₀ = x₀ * x₀' / (t - 1)
    s₁₁ = x₁ * x₁' / (t - 1)
    s₀₁ = x₀ * x₁' / (t - 1)
    s₁₀ = s₀₁'
    ridge = eps(eltype(x))
    m = ((s₁₁ + ridge * I) \ s₁₀) * ((s₀₀ + ridge * I) \ s₀₁)
    eig = eigen(m)
    λ = real(eig.values)
    β = real(eig.vectors)
    order = sortperm(λ; rev=true)
    λ[order], β[:, order]
end

rank(λ, λmin) = sum(λ .> λmin)

spread(β, x) = vec(β' * x)

function adfstat(x)
    Δx = diff(x)
    xₜ₋₁ = x[1:end-1]
    b = sum(xₜ₋₁ .* Δx) / (sum(xₜ₋₁ .* xₜ₋₁) + eps())
    r = Δx .- b .* xₜ₋₁
    σ² = sum(r .* r) / (length(r) - 1 + eps())
    se = sqrt(σ² / (sum(xₜ₋₁ .* xₜ₋₁) + eps()))
    b / (se + eps())
end

function halflife(x)
    Δx = diff(x)
    xₜ₋₁ = x[1:end-1]
    b = sum(xₜ₋₁ .* Δx) / (sum(xₜ₋₁ .* xₜ₋₁) + eps())
    b >= 0 && return floatmax(eltype(x))
    -log(2) / b
end

turnover(x) = mean(abs.(diff(x))) / (std(x) + eps())
sharpe(x) = mean(x) / (std(x) + eps())
expectedmove(x, hl) =
    let μ = mean(x)
        σ = std(x) + eps()
        δ = x[end] - μ
        decay = exp(-one(δ) / (hl + eps()))
        -δ * (one(δ) - decay) / σ
    end

function validspread(a, x)
    std(x) > eps() &&
        adfstat(x) < a.adf_threshold &&
        halflife(x) < a.halflife_max &&
        isfinite(turnover(x))
end

function fullweights(β, n, idx)
    w = zeros(n)
    w[idx] = normalize(neutral(β))
    w
end

function score(a, xₑ, s, w)
    expectedmove(xₑ, a.halflife_max) - spreadcost(s, w)
end

function bestcandidate(a, s, idx)
    xₛ = window(a.structural)[idx, :]
    λ, β = johansen(xₛ)
    r = rank(λ, a.λmin)
    T = eltype(xₛ)
    r == 0 && return (-Inf, Vector{T}(), Vector{T}(), idx)
    best = -Inf
    wbest = Vector{T}()
    βbest = Vector{T}()
    xₑ = window(a.execution)[idx, :]
    for j in 1:r
        βⱼ = normalize(neutral(β[:, j]))
        xspread = spread(βⱼ, xₛ)
        validspread(a, xspread) || continue
        w = fullweights(βⱼ, length(s.positions), idx)
        sscore = score(a, spread(βⱼ, xₑ), s, w)
        if sscore > best
            best = sscore
            wbest = w
            βbest = βⱼ
        end
    end
    (best, wbest, βbest, idx)
end

function select(a, s)
    best = -Inf
    T = eltype(a.structural.data)
    wbest = Vector{T}()
    βbest = Vector{T}()
    gbest = Vector{Int}()
    for g in a.groups
        sscore, w, β, idx = bestcandidate(a, s, g)
        if sscore > best
            best = sscore
            wbest = w
            βbest = β
            gbest = idx
        end
    end
    (best, wbest, βbest, gbest)
end

function zscore(x)
    μ = mean(x)
    σ = std(x) + eps()
    (x[end] - μ) / σ
end

function cycle(a, z)
    z > a.entry ? -a.risk :
    z < -a.entry ? a.risk :
    abs(z) < a.exit ? zero(a.risk) :
    a.q
end

function switch(a, s, score, w, β, g)
    isempty(w) && return a
    cost = spreadcost(s, w)
    if score - a.score > 2 * cost + a.min_improvement
        a.score = score
        a.weights = w
        a.β = β
        a.current = g
    end
    a
end

mutable struct MeanReversionAgent{T} <: Agent
    structural::RollingBuffer{T}
    execution::RollingBuffer{T}
    groups::Vector{Vector{Int}}
    current::Vector{Int}
    β::Vector{T}
    weights::Vector{T}
    score::T
    min_improvement::T
    min_rebalance::T
    last_target::Vector{T}
    q::T
    entry::T
    exit::T
    risk::T
    cash_target::T
    λmin::T
    adf_threshold::T
    halflife_max::T
    step::Int
    stride::Int
end

function MeanReversionAgent(s::State; hz=40, structural_hours=1, execution_minutes=5, entry=1.0, exit=0.25, risk=0.9, cash=0.0, λmin=0.05, adf=-2.8, halflife=3600.0, stride=40, min_improvement=0.0, min_rebalance=0.0, max_group=0)
    n = length(s.positions)
    T = typeof(s.cash)
    structural = RollingBuffer(n, samples(structural_hours * 3600, hz), T)
    execution = RollingBuffer(n, samples(execution_minutes * 60, hz), T)
    push!(structural, logprices(s))
    push!(execution, logprices(s))
    g = max_group == 0 ? groups(n) : groups(n, max_group)
    MeanReversionAgent{T}(
        structural,
        execution,
        g,
        Int[],
        T[],
        T[],
        -T(Inf),
        T(min_improvement),
        T(min_rebalance),
        zeros(T, n),
        zero(T),
        T(entry),
        T(exit),
        T(risk),
        T(cash),
        T(λmin),
        T(adf),
        T(halflife),
        0,
        stride,
    )
end

function Orders(a::MeanReversionAgent, s::State)
    a.structural.count < 50 && return Order[]
    if isempty(a.weights) || a.step % a.stride == 0
        score, w, β, g = select(a, s)
        switch(a, s, score, w, β, g)
    end
    isempty(a.weights) && return Order[]
    a.score <= 2 * spreadcost(s, a.weights) && return Order[]
    xₑ = spread(a.β, window(a.execution)[a.current, :])
    z = zscore(xₑ)
    a.q = cycle(a, z)
    q = a.q
    if q == 0
        # any(!iszero, getfield.(s.positions, :units)) && @info "mean reversion closing" score = a.score z = z
        return Order[]
    end
    scale = min(one(q), max(zero(q), availablemargin(s) / (nlv(s) + eps())))
    wₜ = scale .* q .* (one(q) - a.cash_target) .* a.weights
    # @info "mean reversion trading" score = a.score z = z scale = scale
    maximum(abs.(wₜ .- a.last_target)) < a.min_rebalance && return Order[]
    a.last_target = wₜ
    targetorders(s, wₜ)
end

function Agent(a::MeanReversionAgent, ::State, ::Orders, ::Any, s₂::State)
    push!(a.structural, logprices(s₂))
    push!(a.execution, logprices(s₂))
    a.step += 1
    a
end
