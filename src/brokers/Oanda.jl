using Dates, JSON, Logging, LinearAlgebra, BufferedStreams
import HTTP
import HTTP: escapeuri

export OandaBroker

struct OandaConfig
    account::String
    account_url::String
    summary_url::String
    positions_url::String
    instruments_url::String
    pricing_url::String
    orders_url::String
    streaming_url_full::String
    headers::Vector{Pair{String,String}}
    symbols::Vector{Symbol}
end

OandaConfig(path::AbstractString) = OandaConfig(JSON.parsefile(path))

oanda_symbol(base, term) = Symbol(string(base) * "_" * string(term))
oanda_symbol(pair::AbstractVector) = oanda_symbol(pair[1], pair[2])
oanda_symbol(inst::AbstractDict) = oanda_symbol(inst["symbol"], inst["currency"])

function OandaConfig(json::AbstractDict)
    headers = map(collect(json["headers"])) do (k, v)
        string(k) => string(v)
    end
    account = string(json["account_id"])
    rest = string(json["rest"])
    streaming = string(json["streaming"])

    # Parse instruments
    instruments = json["instruments"]
    # symbols are used for Oanda API calls (e.g., EUR_CAD)
    symbols = map(oanda_symbol, instruments)
    symbols_string = join(map(string, symbols), ",")

    account_url = "$(rest)/v3/accounts/$(account)"
    summary_url = "$(account_url)/summary"
    positions_url = "$(account_url)/positions"
    instruments_url = "$(account_url)/instruments?instruments=$(escapeuri(symbols_string))"
    pricing_url = "$(account_url)/pricing?instruments=$(escapeuri(symbols_string))"
    orders_url = "$(account_url)/orders"
    streaming_url_full = "$(streaming)/v3/accounts/$(account)/pricing/stream?instruments=$(escapeuri(symbols_string))"
    OandaConfig(account, account_url, summary_url, positions_url, instruments_url, pricing_url, orders_url, streaming_url_full, headers, symbols)
end

RFC3339toDateTime(timestamp) = DateTime(timestamp[1:23], dateformat"yyyy-mm-ddTHH:MM:SS.sss")

function stream(url::String, headers::Vector{Pair{String,String}})
    ch = Channel{String}(100)
    # TODO: Update broker state in the producer task so slow consumers don't stall state updates.
    @async begin
        delay = 1.0
        while isopen(ch)
            try
                HTTP.open("GET", url, headers) do s
                    for line in eachline(BufferedInputStream(s))
                        !isopen(ch) && break
                        put!(ch, line)
                        delay = 1.0
                    end
                end
            catch e
                !isopen(ch) && break
                @warn "Stream error, retrying in $(round(delay; digits=1))s"
                sleep(delay)
                delay = min(delay * 2, 60.0)
            end
        end
    end
    ch
end

step(pip_location) = 10.0^pip_location

getinstruments(config::OandaConfig) = [i for i in get(config.instruments_url, config.headers)["instruments"]]
function getquotes(config::OandaConfig)
    body = get(config.pricing_url, config.headers)
    RFC3339toDateTime(body["time"]), body["prices"]
end
getpositions(config::OandaConfig, time::DateTime) = Dict(Symbol(p["instrument"]) => Position(p, time) for p in get(config.positions_url, config.headers)["positions"])
getcash(config::OandaConfig) = parse(Float64, get(config.summary_url, config.headers)["account"]["balance"])
getmarginavailable(config::OandaConfig) = parse(Float64, get(config.summary_url, config.headers)["account"]["marginAvailable"])
getnav(config::OandaConfig) = parse(Float64, get(config.summary_url, config.headers)["account"]["NAV"])
getaccountcurrency(config::OandaConfig) = Symbol(get(config.summary_url, config.headers)["account"]["currency"])

conversion(q::AbstractDict) = parse(Float64, q["quoteHomeConversionFactors"]["positiveUnits"])

function Instrument(response::AbstractDict, index::Int)
    name = Symbol(response["name"])
    _, term = split(response["name"], "_")
    size = parse(Float64, response["minimumTradeSize"])
    margin = parse(Float64, response["marginRate"])
    unit_precision = Int(get(response, "tradeUnitsPrecision", 0))
    unit_step = 10.0^(-unit_precision)
    Instrument{Float64}(name, Symbol(term), unit_step, size, margin, 0.0, index)
end

Price(::Type{T}, msg) where {T} = Price{T}(parse(T, string(msg["price"])), parse(T, string(msg["liquidity"])))

function Book(price::AbstractDict, L::Int)
    T = Float64
    time = RFC3339toDateTime(price["time"])
    bids = price["bids"]
    asks = price["asks"]
    Book(time,
        SVector{L,Price{T}}(ntuple(i -> Price(T, bids[i]), L)),
        SVector{L,Price{T}}(ntuple(i -> Price(T, asks[i]), L))
    )
end

function Book(price::AbstractDict)
    bids = price["bids"]
    asks = price["asks"]
    L = min(length(bids), length(asks))
    Book(price, L)
end

long(position_msg::AbstractDict, time::DateTime) = Position(parse(Float64, get(position_msg, "averagePrice", "0")), parse(Float64, get(position_msg, "units", "0")), time)
short(position_msg::AbstractDict, time::DateTime) = Position(parse(Float64, get(position_msg, "averagePrice", "0")), -abs(parse(Float64, get(position_msg, "units", "0"))), time)
Position(position_msg::AbstractDict, time::DateTime) = long(position_msg["long"], time) + short(position_msg["short"], time)


function order(config::OandaConfig, instrument::String, units::String)
    JSON.json(Dict("order" => Dict("units" => units, "instrument" => instrument, "timeInForce" => "FOK", "type" => "MARKET", "positionFill" => "DEFAULT")))
end

function submitorder(config::OandaConfig; body)
    try
        post(config.orders_url, config.headers; body=body)
    catch e
        if e isa HTTP.Exceptions.StatusError && e.status == 400
            return JSON.parse(String(e.response.body))
        end
        rethrow(e)
    end
end

function oandafill(response)
    if haskey(response, "orderFillTransaction")
        txn = response["orderFillTransaction"]
        txn["type"] == "ORDER_FILL" || throw(ArgumentError(JSON.json(txn)))
        instrument = txn["instrument"]
        units = parse(Float64, txn["units"])
        price = parse(Float64, txn["price"])
        balance = parse(Float64, txn["accountBalance"])
        time = RFC3339toDateTime(txn["time"])
        return (type=:fill, instrument=instrument, units=units, price=price, balance=balance, time=time)
    end

    if haskey(response, "orderCancelTransaction")
        txn = response["orderCancelTransaction"]
        return (type=:reject, reason=Base.get(txn, "reason", "UNKNOWN"))
    end

    if haskey(response, "orderRejectTransaction")
        txn = response["orderRejectTransaction"]
        return (type=:reject, reason=Base.get(txn, "rejectReason", "REJECTED"))
    end

    throw(ArgumentError(JSON.json(response)))
end

function putclose!(config::OandaConfig, instrument::String, position::Position)
    body = Dict{String,Any}()
    iszero(position.units) && return nothing
    if position.units > 0
        body["longUnits"] = "ALL"
    elseif position.units < 0
        body["shortUnits"] = "ALL"
    end

    put("$(config.positions_url)/$(instrument)/close", config.headers; body=JSON.json(body))
end

mutable struct OandaBroker{T<:AbstractFloat,L,N,M} <: Broker
    config::OandaConfig
    index::Dict{Symbol,Int}
    ch::Channel{String}
    state::State{T,L,N,M}
end

function OandaBroker(; configpath::AbstractString="configs/Oanda.json")
    config = OandaConfig(configpath)
    index = Dict(s => i for (i, s) in enumerate(config.symbols))
    ch = stream(config.streaming_url_full, config.headers)

    s = State(config)

    OandaBroker(config, index, ch, s)
end

# State construction from OandaConfig fetching everything from API
function State(config::OandaConfig, ::Type{T}=Float64) where {T<:AbstractFloat}
    raw_insts = getinstruments(config)
    time, raw_quotes = getquotes(config)
    raw_pos = getpositions(config, time)
    cash = getcash(config)

    insts_map = Dict(Symbol(i["name"]) => i for i in raw_insts)
    quotes_map = Dict(Symbol(q["instrument"]) => q for q in raw_quotes)

    # Determine consistent L
    L = minimum(min(length(quotes_map[s]["bids"]), length(quotes_map[s]["asks"])) for s in config.symbols)

    N = length(config.symbols)
    instruments = SVector{N,Instrument{T}}([Instrument(insts_map[s], i) for (i, s) in enumerate(config.symbols)])
    quotes = SVector{N,Book{T,L}}([Book(quotes_map[s], L) for s in config.symbols])
    positions = SVector{N,Position{T}}([get(raw_pos, s, Position(zero(T), zero(T), time)) for s in config.symbols])

    # Build FX graph and paths
    pairs = map(instruments) do i
        base, term = split(string(i.symbol), "_")
        (Symbol(base), Symbol(term))
    end
    acc_currency = getaccountcurrency(config)
    pvec = build_paths(instruments, pairs, acc_currency)

    State(time, instruments, quotes, positions, cash, acc_currency, pvec)
end

State(b::OandaBroker{T}) where {T} = State(b.config, T)

function State(b::OandaBroker, s::State{T,L,N,M}, msg::AbstractDict) where {T,L,N,M}
    haskey(msg, "instrument") || return s
    (length(msg["bids"]) < L || length(msg["asks"]) < L) && return s
    idx = b.index[Symbol(msg["instrument"])]
    book = Book(msg, L)

    State(s, book, idx)
end

function State(b::OandaBroker, s::State)
    while true
        line = take!(b.ch)
        msg = JSON.parse(line)
        haskey(msg, "type") && msg["type"] == "HEARTBEAT" && continue

        # Merge quotes from msg into the provided state s
        new_s = State(b, s, msg)
        b.state = new_s
        return new_s
    end
end

function closepositions!(b::OandaBroker{T}, s::State{T,L,N,M}) where {T,L,N,M}
    for instrument in s.instruments
        p = s.positions[instrument.index]
        try
            putclose!(b.config, string(instrument.symbol), p)
        catch e
            @warn "Failed to close $(instrument.symbol)" exception = e
        end
    end
    sleep(0.5) # Wait for propagation

    # Re-sync with actual account state
    time, _ = getquotes(b.config)
    raw_pos = getpositions(b.config, time)
    balance₂ = getcash(b.config)

    positions₂ = SVector{N,Position{T}}([get(raw_pos, i.symbol, Position(zero(T), zero(T), time)) for i in s.instruments])

    # Update broker state to match
    new_s = State(time, s.instruments, s.quotes, positions₂, T(balance₂), s.currency, s.rates, s.paths)
    b.state = new_s
    new_s
end

function stop!(b::OandaBroker{T}) where {T}
    @info "OandaBroker stopped account=$(b.config.account) instruments=$(b.config.symbols)"
    b
end

function fillorder(b::OandaBroker, s::State, o::Order)
    i = o.index
    sym = o.symbol
    units = o.units

    body = Rhea.order(b.config, string(sym), string(units))
    response = submitorder(b.config; body=body)
    f = oandafill(response)

    if f.type == :reject
        return OrderReject(f.reason)
    end

    # Return FilledOrder with index and OANDA's reported balance
    FilledOrder(i, f.price, f.units, f.time, f.balance)
end

sync!(b::OandaBroker, s::State) = (b.state = s)
