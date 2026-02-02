using Dates, JSON, StaticArrays, Mmap
using Base.Iterators: Stateful, peek
import Base: close

loadconfig(path) = JSON.parsefile(path)
accountcurrency(config) = Symbol(config["account_currency"])
cash(config) = Float64(config["cash"])
instrumentconfig(config) = Vector{Dict{String,Any}}(config["instruments"])

columns() = (time=1, ask=3, bid=4)

# -- Optimized Parsing --

isend(data::Vector{UInt8}, idx::Int) = idx > length(data)

function nextcomma(data::Vector{UInt8}, p::Int, stop::Int)
    @inbounds while p <= stop && data[p] != UInt8(',')
        p += 1
    end
    p
end

function findnewline(data::Vector{UInt8}, idx::Int)
    len = length(data)
    @inbounds while idx <= len && data[idx] != UInt8('\n')
        idx += 1
    end
    idx
end

function parsebytes(::Type{Int}, data::Vector{UInt8}, start::Int, stop::Int)
    res = 0
    @inbounds for i in start:stop
        res = res * 10 + (data[i] - UInt8('0'))
    end
    res
end

function parseintpart(data::Vector{UInt8}, start::Int, stop::Int)
    res = 0.0
    i = start
    @inbounds while i <= stop && data[i] != UInt8('.')
        res = res * 10 + (data[i] - UInt8('0'))
        i += 1
    end
    return res, i
end

function parsefracpart(data::Vector{UInt8}, start::Int, stop::Int)
    frac = 0.0
    divisor = 1.0
    i = start
    @inbounds while i <= stop
        frac = frac * 10 + (data[i] - UInt8('0'))
        divisor *= 10.0
        i += 1
    end
    return frac / divisor
end

function parsebytes(::Type{Float64}, data::Vector{UInt8}, start::Int, stop::Int)
    val, idx = parseintpart(data, start, stop)
    if idx <= stop && data[idx] == UInt8('.')
        val += parsefracpart(data, idx + 1, stop)
    end
    val
end

function parsebytes(::Type{DateTime}, data::Vector{UInt8}, start::Int)
    # Format: 2023-10-25T00:00:00.000
    #         01234567890123456789012
    y = parsebytes(Int, data, start, start + 3)
    m = parsebytes(Int, data, start + 5, start + 6)
    d = parsebytes(Int, data, start + 8, start + 9)
    H = parsebytes(Int, data, start + 11, start + 12)
    M = parsebytes(Int, data, start + 14, start + 15)
    S = parsebytes(Int, data, start + 17, start + 18)
    ms = parsebytes(Int, data, start + 20, start + 22)
    DateTime(y, m, d, H, M, S, ms)
end

function Book(data::Vector{UInt8}, start::Int, stop::Int)
    # CSV: time,open,high,low,close,vol...
    # Book needs: time, bid(low), ask(high)
    c1 = nextcomma(data, start, stop)
    dt = parsebytes(DateTime, data, start)
    c2 = nextcomma(data, c1 + 1, stop) # Open
    c3 = nextcomma(data, c2 + 1, stop) # High (Ask)
    ask_val = parsebytes(Float64, data, c2 + 1, c3 - 1)
    c4 = nextcomma(data, c3 + 1, stop) # Low (Bid)
    bid_val = parsebytes(Float64, data, c3 + 1, c4 - 1)
    
    bid = Price(bid_val, 1e6)
    ask = Price(ask_val, 1e6)
    Book{Float64,1}(dt, SVector(bid), SVector(ask))
end

struct MmapBookIterator
    data::Vector{UInt8}
    start_idx::Int
end

function MmapBookIterator(path::AbstractString)
    data = Mmap.mmap(path)
    idx = findnewline(data, 1) # Skip header
    MmapBookIterator(data, idx + 1)
end

function Base.iterate(it::MmapBookIterator, idx::Int=it.start_idx)
    isend(it.data, idx) && return nothing
    next_idx = findnewline(it.data, idx)
    stop_parse = next_idx - 1
    if stop_parse >= idx && it.data[stop_parse] == UInt8('\r')
        stop_parse -= 1
    end
    book = Book(it.data, idx, stop_parse)
    (book, next_idx + 1)
end

Base.eltype(::Type{MmapBookIterator}) = Book{Float64,1}

bookstream(path, ::Type{T}=Float64) where {T<:AbstractFloat} = Stateful(MmapBookIterator(path))
nexttime(stream) = isempty(stream) ? typemax(DateTime) : peek(stream).time

Instrument(inst::AbstractDict, i, ::Type{T}) where {T<:AbstractFloat} =
    Instrument{T}(
        Symbol(inst["symbol"]::String),
        Symbol(inst["currency"]::String),
        T(inst["step"]::Real),
        T(inst["size"]::Real),
        T(inst["margin"]::Real),
        T(inst["fee"]::Real),
        i
    )

struct MergedStream{S,T}
    streams::Vector{S}
end

Base.IteratorSize(::Type{<:MergedStream}) = Base.SizeUnknown()
Base.eltype(::Type{MergedStream{S,T}}) where {S,T} = Tuple{Book{T,1},Int}

function Base.iterate(ms::MergedStream{S,T}, state=nothing) where {S,T}
    N = length(ms.streams)
    best_time, idx = mapreduce(i -> (nexttime(ms.streams[i]), i), min, 1:N)
    best_time == typemax(DateTime) && return nothing
    ((popfirst!(ms.streams[idx]), idx), nothing)
end

struct DataBroker{T<:AbstractFloat,S,N} <: Broker
    account_currency::Symbol
    cash::T
    instruments::SVector{N,Instrument{T}}
    stream::MergedStream{S,T}
end

function makestream(inst, configpath, ::Type{T}) where {T}
    file = inst["file"]
    path = isabspath(file) ? file : joinpath(dirname(configpath), file)
    bookstream(path, T)
end

function DataBroker(; configpath::AbstractString="configs/DataBroker.json")
    config = loadconfig(configpath)
    insts = instrumentconfig(config)
    acc_currency = accountcurrency(config)
    balance = cash(config)
    N = length(insts)
    instruments = SVector{N}([Instrument(inst, i, Float64) for (i, inst) in enumerate(insts)])
    streams = [makestream(inst, configpath, Float64) for inst in insts]
    DataBroker{Float64,eltype(streams),N}(acc_currency, balance, instruments, MergedStream{eltype(streams),Float64}(streams))
end

Base.close(::DataBroker) = nothing

function State(b::DataBroker{T,S,N}) where {T,S,N}
    # 1. Initialize with Head of streams to avoid nulls
    raw_quotes = ntuple(i -> peek(b.stream.streams[i]), N)
    any(isnothing, raw_quotes) && error("Streams cannot be empty at initialization")
    quotes = SVector{N,Book{T,1}}(map(q -> q::Book{T,1}, raw_quotes))

    time_max = maximum(q.time for q in quotes)
    positions = SVector{N,Position{T}}(ntuple(_ -> Position(zero(T), zero(T), time_max), N))
    pairs = ntuple(i -> (b.instruments[i].symbol, b.instruments[i].currency), N)
    paths = build_paths(b.instruments, pairs, b.account_currency)

    s = State(minimum(q.time for q in quotes), b.instruments, quotes, positions, b.cash, b.account_currency, paths)

    # 2. Warmup: Synchronize all streams to the latest start time (time_max)
    while true
        best_time, idx = mapreduce(i -> (nexttime(b.stream.streams[i]), i), min, 1:N)
        if best_time <= time_max
            res = iterate(b.stream)
            isnothing(res) && break
            (book, idx), _ = res
            s = State(s, book, idx)
        else
            break
        end
    end
    
    s.time < time_max ? State(time_max, s.instruments, s.quotes, s.positions, s.cash, s.currency, s.rates, s.paths) : s
end

function State(b::DataBroker{T,S,N}, s::State) where {T,S,N}
    res = iterate(b.stream)
    isnothing(res) && return s
    ((book, idx), _) = res
    State(s, book, idx)
end

fillorder(b::DataBroker{T,S,N}, s::State{T,L,N,M}, o::Order) where {T<:AbstractFloat,L,N,M,S} = Rhea.fillorder(s, o)

function stop!(::DataBroker) end