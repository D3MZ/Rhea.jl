export LogReturnReward, PnLReward, SharpeReward

struct PnLReward <: Reward end
Reward(::PnLReward, s₁::State, s₂::State) = nlv(s₂) - nlv(s₁)

struct LogReturnReward <: Reward end
Reward(::LogReturnReward, s₁::State, s₂::State) = logreturn(s₁, s₂)

mutable struct SharpeReward{T<:AbstractFloat} <: Reward
    μ::T
    σ²::T
    n::Int
end

SharpeReward() = SharpeReward(0.0, 0.0, 0)

function Reward(r::SharpeReward, s₁::State, s₂::State)
    x = logreturn(s₁, s₂)
    n = r.n + 1
    δ = x - r.μ
    μ = r.μ + δ / n
    σ² = r.σ² + δ * (x - μ)
    r.n = n
    r.μ = μ
    r.σ² = σ²
    μ / (sqrt(r.σ² / n) + eps())
end
