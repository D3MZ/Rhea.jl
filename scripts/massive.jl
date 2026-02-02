using HTTP
using JSON
using CSV
using Dates
using Logging

# Constants
const CONFIG_PATH = joinpath(@__DIR__, "..", "configs", "massive.json")
const TIMEFRAME_MULTIPLIER = 1
const TIMEFRAME_SPAN = "minute"

"""
    normalize_ticker(ticker::String) -> String

Removes the prefix (e.g., "C:") from a ticker symbol.
"""
normalize_ticker(ticker::AbstractString) = replace(ticker, "C:" => "")

"""
    get_config() -> Dict

Loads and parses the configuration file.
"""
function get_config()
    return JSON.parsefile(CONFIG_PATH)
end

"""
    last_recorded_timestamp(filepath::String) -> Union{DateTime, Nothing}

Retrieves the timestamp of the last row in the CSV file.
Returns `nothing` if the file does not exist or is empty.
"""
function last_recorded_timestamp(filepath::String)
    isfile(filepath) || return nothing
    
    try
        csv = CSV.File(filepath)
        isempty(csv) && return nothing
        return DateTime(csv[end].timestamp)
    catch e
        @warn "Failed to read last timestamp from $filepath" exception=e
        return nothing
    end
end

"""
    format_iso(dt::DateTime) -> String

Formats a DateTime to ISO-8601 with millisecond precision.
"""
format_iso(dt::DateTime) = Dates.format(dt, "yyyy-mm-ddTHH:MM:SS.sss")

"""
    parse_bar(bar::AbstractDict) -> NamedTuple

Converts a raw API bar dictionary into a normalized NamedTuple.
"""
function parse_bar(bar::AbstractDict)
    ts_ms = get(bar, "t", 0)
    ts = unix2datetime(ts_ms / 1000)
    
    return (
        timestamp = format_iso(ts),
        open = get(bar, "o", NaN),
        high = get(bar, "h", NaN),
        low = get(bar, "l", NaN),
        close = get(bar, "c", NaN),
        volume = get(bar, "v", 0),
        transactions = get(bar, "n", 0),
        vwap = get(bar, "vw", NaN),
        _ts_obj = ts # Internal use for filtering, not written to CSV if we select columns
    )
end

"""
    fetch_chunk(url::String, api_key::String) -> (Vector{Any}, Union{String, Nothing})

Fetches a single page of data from the API.
"""
function fetch_chunk(url::String, api_key::String)
    # Ensure API key is present in the URL or query params
    # If the URL is a 'next_url', it might need the key appended
    final_url = occursin("apiKey", url) ? url : "$url&apiKey=$api_key"
    
    # Handle the case where the initial URL doesn't have query params yet (for the first call)
    # But our construction below adds params to the first call.
    # The 'next_url' from Polygon usually has params.
    
    resp = HTTP.get(final_url)
    data = JSON.parse(String(resp.body))
    
    results = get(data, "results", [])
    next_url = get(data, "next_url", nothing)
    
    return results, next_url
end

"""
    fetch_history(config, ticker, start_dt, end_dt) -> Vector{NamedTuple}

Fetches historical data for a given ticker within the specified range, handling pagination and rate limits.
"""
function fetch_history(config, ticker, start_dt, end_dt)
    base_url = config["base_url"]
    api_key = config["api_key"]
    limit = get(config, "limit", 50000)
    rate_limit = get(config, "rate_limit_per_minute", 5)
    sleep_duration = 60.0 / rate_limit
    
    from_str = Dates.format(start_dt, "yyyy-mm-dd")
    to_str = Dates.format(end_dt, "yyyy-mm-dd")
    
    initial_url = "$base_url/v2/aggs/ticker/$ticker/range/$TIMEFRAME_MULTIPLIER/$TIMEFRAME_SPAN/$from_str/$to_str?adjusted=true&sort=asc&limit=$limit"
    
    all_bars = Vector{NamedTuple}()
    next_url = initial_url
    
    while !isnothing(next_url)
        @info "Fetching chunk for $ticker..."
        
        # We handle the sleep *before* the request if we are in a loop, 
        # but usually rate limits apply to the frequency. 
        # A simple sleep after each request is robust.
        
        try
            raw_bars, next_url = fetch_chunk(next_url, api_key)
            
            # Map and append
            normalized = map(parse_bar, raw_bars)
            append!(all_bars, normalized)
            
        catch e
            @error "Failed to fetch data for $ticker" exception=e
            rethrow(e)
        end
        
        sleep(sleep_duration)
    end
    
    return all_bars
end

"""
    process_instrument(config, instrument)

Orchestrates the fetch and write process for a single instrument.
"""
function process_instrument(config, instrument)
    ticker = instrument["ticker"]
    clean_ticker = normalize_ticker(ticker)
    output_dir = joinpath(@__DIR__, "..", config["output_dir"])
    filepath = joinpath(output_dir, "$(clean_ticker)_1min.csv")
    
    mkpath(output_dir)
    
    last_ts = last_recorded_timestamp(filepath)
    
    # Determine start date
    start_dt = if isnothing(last_ts)
        DateTime(Date(config["from"]))
    else
        last_ts + Minute(1)
    end
    
    end_dt = now(UTC)
    
    if start_dt > end_dt
        @info "$clean_ticker is up to date."
        return
    end
    
    @info "Processing $clean_ticker from $start_dt to $end_dt"
    
    bars = fetch_history(config, ticker, start_dt, end_dt)
    
    if isempty(bars)
        @info "No new data found for $clean_ticker."
        return
    end
    
    # Filter strictly increasing timestamps if we are appending
    # The API might return overlaps if we aren't careful with dates, 
    # though usually start_date granularity is 'day'.
    # We use our internal _ts_obj for precise filtering.
    
    valid_bars = if !isnothing(last_ts)
        filter(b -> b._ts_obj > last_ts, bars)
    else
        bars
    end
    
    if isempty(valid_bars)
        @info "No valid new rows for $clean_ticker (all duplicates)."
        return
    end
    
    # Project to final schema (remove _ts_obj)
    final_rows = map(b -> (
        timestamp = b.timestamp,
        open = b.open,
        high = b.high,
        low = b.low,
        close = b.close,
        volume = b.volume,
        transactions = b.transactions,
        vwap = b.vwap
    ), valid_bars)
    
    # Write to disk
    is_appending = isfile(filepath)
    CSV.write(filepath, final_rows; append=is_appending, header=!is_appending)
    
    @info "Wrote $(length(final_rows)) rows to $filepath"
end

function main()
    config = get_config()
    
    for instrument in config["instruments"]
        try
            process_instrument(config, instrument)
        catch e
            @error "Critical error processing $(instrument["ticker"])" exception=e
            # Decide whether to stop everything or continue. Continuing is usually safer for long batch jobs.
        end
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
