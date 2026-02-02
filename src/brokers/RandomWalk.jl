export RandomWalkBroker


mutable struct RandomWalkBroker{T<:AbstractFloat,R<:AbstractRNG,L,N,M} <: Broker
    rng::R
    σ::T
    spread::T
    state::State{T,L,N,M}
end

function RandomWalkBroker(rng::AbstractRNG, instruments::AbstractVector{<:Instrument{T}}; σ::T=T(0.01), spread::T=T(0.0005), time::DateTime=DateTime(2025, 1, 1), cash::T=T(10_000.0), mid::T=T(100.0), currency::Symbol=:USD, pairs=[]) where {T<:AbstractFloat}
    bid = mid * (one(T) - spread)
    ask = mid * (one(T) + spread)
    books = [Book(time, SVector(Price(bid, one(T))), SVector(Price(ask, one(T)))) for _ in instruments]
    positions = [Position(zero(T), zero(T), time) for _ in instruments]
    pvec = build_paths(instruments, pairs, currency)

    state = State(time, instruments, books, positions, cash, currency, pvec)
    RandomWalkBroker(rng, σ, spread, state)
end

RandomWalkBroker(rng::AbstractRNG, instrument::Instrument{T}; σ::T=T(0.01), spread::T=T(0.0005), time::DateTime=DateTime(2025, 1, 1), cash::T=T(10_000.0), mid::T=T(100.0)) where {T<:AbstractFloat} =
    RandomWalkBroker(rng, [instrument]; σ=σ, spread=spread, time=time, cash=cash, mid=mid)

function RandomWalkBroker(rng::AbstractRNG; n::Integer=1, symbols=[Symbol("ASSET$i") for i in 1:n], step=1e-4, size=1e-3, margin=1.0, fee=0.0, σ=0.01, spread=0.0005, time::DateTime=DateTime(2025, 1, 1), cash=10_000.0, mid=100.0, currency=:USD, instrument_currencies=fill(currency, length(symbols)), pairs=[])
    T = typeof(float(mid))
    instruments = [Instrument{T}(s, instrument_currencies[i], T(step), T(size), T(margin), T(fee), i) for (i, s) in enumerate(symbols)]
    RandomWalkBroker(rng, instruments; σ=T(σ), spread=T(spread), time=time, cash=T(cash), mid=T(mid), currency=currency, pairs=pairs)
end

function State(b::RandomWalkBroker{T}, s::State) where {T<:AbstractFloat}
    time₂ = s.time + Millisecond(1)
    books₂ = map(s.quotes) do book
        m = mid(book)
        m₂ = m * exp(b.σ * randn(b.rng))
        bid = m₂ * (one(T) - b.spread)
        ask = m₂ * (one(T) + b.spread)
        Book(time₂, SVector(Price(bid, one(T))), SVector(Price(ask, one(T))))
    end

    b.state = State(s, time₂, books₂)
    b.state
end

State(b::RandomWalkBroker) = b.state

# RandomWalkBroker uses the generic Core.fillorder logic
fillorder(b::RandomWalkBroker, s::State, o::Order) = Persephone.fillorder(s, o)

sync!(b::RandomWalkBroker, s::State) = (b.state = s)
