export BuyHold, CashOnly, EqualWeight, Harvest, RuleBasedAgent

abstract type Strategy end

struct EqualWeight <: Strategy end
struct CashOnly <: Strategy end

struct Harvest{T<:AbstractFloat} <: Strategy
    band::T
    cash_target::T
end
Harvest(; band=0.05, cash_target=0.0) = Harvest(float(band), float(cash_target))

struct BuyHold <: Strategy
    initialized::Bool
end
BuyHold() = BuyHold(false)

struct RuleBasedAgent{S<:Strategy} <: Agent
    strategy::S
end
RuleBasedAgent() = RuleBasedAgent(EqualWeight())

targetweights(::EqualWeight, n) = fill(1.0 / (n + 1), n + 1)
targetweights(::CashOnly, n) = vcat(fill(0.0, n), 1.0)
targetweights(strategy::Harvest, n) = vcat(fill((1.0 - strategy.cash_target) / n, n), strategy.cash_target)
targetweights(::BuyHold, n) = fill(1.0 / (n + 1), n + 1)

ordersfromeweights(s::State, w::AbstractVector) = targetorders(s, w)

Orders(a::RuleBasedAgent, s::State) = ordersfromeweights(s, targetweights(a.strategy, length(s.positions)))
