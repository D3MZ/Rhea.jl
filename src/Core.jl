# DO NOT REMOVE INLINE COMMENTS

using Dates, StaticArrays, StatsBase, Statistics, HTTP, JSON, Graphs
import Base: get

# HTTP utils
get(url, headers) = JSON.parse(String(HTTP.request("GET", url, headers).body))
post(url, headers; body) = JSON.parse(String(HTTP.request("POST", url, headers; body=body).body))
put(url, headers; body=nothing) = JSON.parse(String(HTTP.request("PUT", url, headers; body=body).body))

# Mathematical helpers
export l1sphere, neutral, normalize, logprices

l1sphere(v) = v ./ (sum(abs, v) + eps(eltype(v)))
neutral(w) = w .- sum(w) / length(w)
normalize(w) = w ./ (sqrt(sum(abs2, w)) + eps(eltype(w)))
zscore(x, μ, σ²) = (x - μ) / sqrt(σ² + eps(one(σ²)))

# Core types and functions
abstract type Broker end
abstract type Agent end
abstract type Reward end
abstract type Order end
struct FilledOrder{T} <: Order
    index::Int
    price::T
    units::T
    time::DateTime
    balance::T
end

struct OrderReject <: Order
    reason::String
end

struct Instrument{T<:AbstractFloat}
    symbol::Symbol
    currency::Symbol # Currency the symbol is denominated in.
    step::T # increment step. (i.e. Currencies can be traded in 1e-5 increments, Futures can be 0.25)
    size::T # minimum order size
    margin::T # margin that the broker authorizes. (i.e. 0.5 = 2x leverage)
    fee::T # per-unit fee expressed in price units
    index::Int # Allows O(1) access when creating new states from a price or order stream
end
fee(i::Instrument) = i.fee
margin(i::Instrument) = i.margin
isvalid(units, i::Instrument) = abs(units) >= i.size
quantize(units, i::Instrument) = trunc(units / i.step) * i.step

struct Price{T<:AbstractFloat}
    mark::T
    units::T
end

struct Book{T<:AbstractFloat,L}
    time::DateTime
    bid::SVector{L,Price{T}}
    ask::SVector{L,Price{T}}
end
bestbid(b::Book) = first(b.bid).mark
bestask(b::Book) = first(b.ask).mark
mid(b::Book) = (bestbid(b) + bestask(b)) / 2
rates(b::Book) = (bestbid(b), 1 / bestask(b))

function rates(quotes::SVector{N,Book{T,L}}) where {T,L,N}
    f(i) = i % 2 == 1 ? bestbid(quotes[(i+1)÷2]) : 1 / bestask(quotes[i÷2])
    SVector{2N,T}(ntuple(f, 2N))
end

struct Position{T<:AbstractFloat}
    price::T
    units::T
    time::DateTime
end

islong(p::Position) = p.units > 0
isshort(p::Position) = p.units < 0
isflat(p::Position) = iszero(p.units)
"value or cost of a position"
value(p::Position) = p.price * p.units
"Unrealized profit"
profit(p::Position, b::Book) = islong(p) ? (bestbid(b) - p.price) * p.units : isshort(p) ? (p.price - bestask(b)) * abs(p.units) : zero(p.price)

function Base.:+(p1::Position, p2::Position)
    units = p1.units + p2.units
    time = max(p1.time, p2.time)
    iszero(units) && return Position(zero(p1.price + p2.price), units, time)
    price = (p1.price * p1.units + p2.price * p2.units) / units
    Position(price, units, time)
end

struct Weight{T<:AbstractFloat}
    value::T
end

struct MarketOrder{T} <: Order
    symbol::Symbol
    index::Int
    units::T
end
MarketOrder(units::T, i::Instrument) where T = MarketOrder(i.symbol, i.index, units)
MarketOrder(cash, w::Weight, b::Book, i::Instrument, s) = MarketOrder(units(cash, w, b, i, s), i)

Position(o::FilledOrder) = Position(o.price, o.units, o.time)
Position(p::Position, o::FilledOrder) = p + Position(o)

# Helper to update a positions SVector with a FilledOrder
update(positions::SVector{N,Position{T}}, o::FilledOrder{T}) where {N,T} =
    setindex(positions, positions[o.index] + Position(o), o.index)

const Orders{T} = Vector{T} where {T<:Order}

struct State{T<:AbstractFloat,L,N,M,K,NK}
    time::DateTime
    instruments::SVector{N,Instrument{T}}
    quotes::SVector{N,Book{T,L}}
    positions::SVector{N,Position{T}}
    cash::T
    currency::Symbol
    rates::SVector{M,T}
    paths::SMatrix{N,K,Int,NK} # Row i is the path for instrument i, padded with 0s
end

function State(s::State, b::Book, idx)
    b_rate, a_rate = rates(b)
    r = setindex(s.rates, b_rate, 2idx - 1)
    r = setindex(r, a_rate, 2idx)
    State(b.time, s.instruments, setindex(s.quotes, b, idx), s.positions, s.cash, s.currency, r, s.paths)
end
State(s::State, p::Position, index) = State(p.time, s.instruments, s.quotes, setindex(s.positions, p, index), s.cash, s.currency, s.rates, s.paths)
State(s::State, time::DateTime, quotes::SVector{N,Book{T,L}}) where {T,L,N} = State(time, s.instruments, quotes, s.positions, s.cash, s.currency, rates(quotes), s.paths)
State(s::State, o::FilledOrder) = State(o.time, s.instruments, s.quotes, update(s.positions, o), o.balance, s.currency, s.rates, s.paths)

function State(time, instruments::SVector{N,Instrument{T}}, quotes::SVector{N,Book{T,L}}, positions::SVector{N,Position{T}}, cash::T, currency::Symbol, rates::SVector{M,T}, paths::SMatrix{N,K,Int,NK}) where {T,L,N,M,K,NK}
    State{T,L,N,M,K,NK}(time, instruments, quotes, positions, cash, currency, rates, paths)
end

function State(time, instruments::SVector{N,Instrument{T}}, quotes::SVector{N,Book{T,L}}, positions::SVector{N,Position{T}}, cash::T, currency::Symbol, rates::SVector{M,T}, paths::AbstractMatrix{Int}) where {T,L,N,M}
    K = size(paths, 2)
    pts = SMatrix{N,K,Int,N*K}(paths)
    State(time, instruments, quotes, positions, cash, currency, rates, pts)
end

function State(time, instruments::AbstractVector{<:Instrument{T}}, quotes::AbstractVector{Book{T,L}}, positions::AbstractVector{Position{T}}, cash::T, currency::Symbol, paths::AbstractMatrix{Int}) where {T,L}
    insts = SVector{length(instruments)}(instruments)
    qts = SVector{length(quotes)}(quotes)
    pos = SVector{length(positions)}(positions)
    rts = rates(qts)
    K = size(paths, 2)
    pts = SMatrix{length(instruments),K,Int,length(instruments)*K}(paths)
    State(time, insts, qts, pos, cash, currency, rts, pts)
end

function conversion(i::Instrument, s::State)
    v = one(eltype(s.rates))
    @inbounds for j in 1:size(s.paths, 2)
        idx = s.paths[i.index, j]
        idx == 0 && break
        v *= s.rates[idx]
    end
    v
end

exitprice(p::Position, b::Book, i::Instrument) = islong(p) ? bestask(b) + fee(i) : bestbid(b) - fee(i)

long(i::Instrument, b::Book, s::State) = (bestask(b) + fee(i)) * margin(i) * conversion(i, s)
short(i::Instrument, b::Book, s::State) = (bestbid(b) - fee(i)) * margin(i) * conversion(i, s)
nlv(p::Position, b::Book, i::Instrument, s::State) = profit(p, b) * conversion(i, s)
usedmargin(p::Position, b::Book, i::Instrument, s::State) = abs(p.units * exitprice(p, b, i)) * conversion(i, s) * margin(i)

function fillorder(s::State{T}, o::MarketOrder) where T
    inst = s.instruments[o.index]
    book = s.quotes[o.index]
    price = o.units > 0 ? bestask(book) : bestbid(book)

    pos = s.positions[o.index]
    realized = zero(T)
    if (pos.units > 0 && o.units < 0) || (pos.units < 0 && o.units > 0)
        closed = min(abs(pos.units), abs(o.units)) * sign(o.units)
        pnl = pos.units > 0 ? (price - pos.price) * abs(closed) : (pos.price - price) * abs(closed)
        realized = pnl * conversion(inst, s)
    end

    fee_cost = abs(o.units) * inst.fee * conversion(inst, s)
    FilledOrder(o.index, price, T(o.units), s.time, s.cash + realized - fee_cost)
end

Weight(cash, p::Position, b::Book, i::Instrument, s::State) = Weight(usedmargin(p, b, i, s) / cash)
units(cash, w::Weight, b::Book, i::Instrument, s::State) = (cash * w.value) / (mid(b) * conversion(i, s) * margin(i))

nlv(s::State) = sum(nlv(p, b, i, s) for (p, b, i) in zip(s.positions, s.quotes, s.instruments)) + s.cash
usedmargin(s::State) = sum(usedmargin(p, b, i, s) for (p, b, i) in zip(s.positions, s.quotes, s.instruments))
availablemargin(s::State) = nlv(s) - usedmargin(s)
logreturn(s₁::State, s₂::State) = log(nlv(s₂)) - log(nlv(s₁))
logprices(s::State) = log.(mid.(s.quotes))

function targetorders(s::State{T,L,N}, w::AbstractVector) where {T,L,N}
    total = nlv(s)
    orders = MarketOrder{T}[]
    sizehint!(orders, N)
    @inbounds for i in 1:N
        inst = s.instruments[i]
        price = w[i] >= 0 ? bestask(s.quotes[i]) + fee(inst) : bestbid(s.quotes[i]) - fee(inst)
        target_units = total * w[i] / (price * conversion(inst, s) * margin(inst))
        Δunits = quantize(target_units - s.positions[i].units, inst)
        if isvalid(Δunits, inst)
            push!(orders, MarketOrder(inst.symbol, i, Δunits))
        end
    end
    return orders
end

function State(b::Broker, s::State{T,L,N,M}, orders::Orders) where {T,L,N,M}
    isempty(orders) && (sync!(b, s); return s)
    s_curr = s
    # Sort orders to prioritize releases (margin_impact < 0)
    sorted = sort(orders; by=o -> abs(s.positions[o.index].units + o.units) - abs(s.positions[o.index].units))
    for order in sorted
        res = fillorder(b, s_curr, order)
        if res isa FilledOrder
            s_curr = State(s_curr, res)
        elseif res isa OrderReject
            @info "order rejected" symbol = order.symbol reason = res.reason
        end
    end
    # Synchronize broker internal state if it's a stateful broker
    sync!(b, s_curr)
    return s_curr
end

# Default hooks for the order pipeline
function fillorder(::Broker, ::State, ::Order)
    return OrderReject("Not implemented")
end
sync!(::Broker, ::State) = nothing

State(::Broker) = throw(MethodError(State, (Broker,)))
State(::Broker, ::State) = throw(MethodError(State, (Broker, State)))

Reward(::Reward, ::State, ::State) = throw(MethodError(Reward, (Reward, State, State)))

Orders(::Agent, ::State{T,L,N,M}) where {T,L,N,M} = throw(MethodError(Orders, (Agent, State)))
Agent(agent::Agent, ::State, ::Any, ::Any, ::State) = agent

# FX Graph utilities
# pairs is a list of (base, term) for each instrument
function build_paths(insts, pairs, currency)
    currencies = unique(Iterators.flatten(([p[1], p[2]] for p in pairs))) |> collect
    push!(currencies, currency)
    unique!(currencies)
    currency_index = Dict(c => i for (i, c) in enumerate(currencies))
    graph = SimpleDiGraph(length(currencies))

    edge_map = Dict{Tuple{Int,Int},Int}()
    for (i, (base, term)) in enumerate(pairs)
        b_idx, t_idx = currency_index[base], currency_index[term]
        add_edge!(graph, b_idx, t_idx)
        edge_map[(b_idx, t_idx)] = 2i - 1
        add_edge!(graph, t_idx, b_idx)
        edge_map[(t_idx, b_idx)] = 2i
    end

    home = currency_index[currency]
    parents = bfs_parents(reverse(graph), home)

    # Max path length 4 for now
    K = 4
    N = length(insts)
    path_matrix = zeros(Int, N, K)

    for (i, inst) in enumerate(insts)
        curr = currency_index[inst.currency]
        curr == home && continue
        parents[curr] == 0 && error("No conversion path found for instrument: $(inst.symbol) (currency: $(inst.currency)) to account currency: $currency")
        
        j = 1
        while curr != home && j <= K
            parent = parents[curr]
            path_matrix[i, j] = edge_map[(curr, parent)]
            curr = parent
            j += 1
        end
    end
    path_matrix
end

# Stats
mutable struct Stats
    path::String
    io::IOStream
    function Stats()
        path = joinpath("stats", Dates.format(now(), "yyyymmdd_HHMMSSsss") * ".csv")
        mkpath(dirname(path))
        io = open(path, "w")
        s = new(path, io)
        finalizer(x -> close(x.io), s)
        s
    end
end

Stats(s::State) = Stats()
Base.close(stats::Stats) = close(stats.io)
Base.flush(stats::Stats) = flush(stats.io)

function update!(stats::Stats, s::State, r)
    println(stats.io, Dates.format(s.time, "yyyy-mm-ddTHH:MM:SS.sss"), ',', nlv(s))
    stats
end

function step!(agent::Agent, broker::Broker, rewarder::Reward, state::State{T,L,N}) where {T,L,N}
    state_obs = State(broker, state)::State{T,L,N}
    state_obs === state && return nothing

    orders = Orders(agent, state_obs)::Vector{MarketOrder{T}}
    state_final = State(broker, state_obs, orders)::State{T,L,N}
    r = Reward(rewarder, state_obs, state_final)::T
    agent = Agent(agent, state_obs, orders, r, state_final)::Agent

    (agent=agent, state=state_final, reward=r)
end

function run!(steps::Integer, agent::Agent, broker::Broker, rewarder::Reward, stats::Stats)
    state = State(broker)
    initial_cash = state.cash
    state_final = state

    for _ in 1:steps
        step = step!(agent, broker, rewarder, state)
        isnothing(step) && break

        agent = step.agent
        state_final = step.state
        update!(stats, state_final, step.reward)
        state = state_final

        state.cash <= initial_cash / 2 && break
    end
    flush(stats)
    state_final
end

run!(agent::Agent, broker::Broker, rewarder::Reward, stats::Stats) = run!(typemax(Int), agent, broker, rewarder, stats)

function run!(steps::Integer, agent::Agent, broker::Broker, rewarder::Reward)
    state = State(broker)
    initial_cash = state.cash
    state_final = state

    for _ in 1:steps
        step = step!(agent, broker, rewarder, state)
        isnothing(step) && break

        agent = step.agent
        state_final = step.state
        state = state_final

        state.cash <= initial_cash / 2 && break
    end
    state_final
end

run!(agent::Agent, broker::Broker, rewarder::Reward) = run!(typemax(Int), agent, broker, rewarder)

function plot(stats::Stats, out::AbstractString)
    flush(stats)
    lines = readlines(stats.path)
    values = parse.(Float64, last.(split.(lines, ",")))
    plt = Persephone.plot(; show=false)
    Persephone.plot!(plt, values; title="Value", xlabel="Step", ylabel="Value", legend=false, linewidth=2, show=false)
    savefig(plt, out)
    out
end
