export PatternMatchAgent

using DataStructures
using LinearAlgebra: norm
using Dates

struct PatternMatchAgent <: Agent
    k::Int
    lookback::Int
    range_size::Float64

    # State
    # memory[i] = continuous stream of range returns for instrument i
    memory::Vector{Vector{Float64}}

    # Tracks the price at the last "Range Bar" formation
    last_prices::Vector{Float64}

    # Signal Trigger: Only trade when new bars are formed
    last_memory_counts::Vector{Int}
end

function PatternMatchAgent(
    num_instruments::Int;
    k::Int=50,
    lookback::Int=10,
    range_size::Float64=0.0005,
)
    memory = [Float64[] for _ in 1:num_instruments]
    last_prices = zeros(Float64, num_instruments)
    last_memory_counts = zeros(Int, num_instruments)
    PatternMatchAgent(k, lookback, range_size, memory, last_prices, last_memory_counts)
end

function Agent(a::PatternMatchAgent, s::State, orders, r, prev_s::State)
    # Initialize prices if empty
    if all(iszero, a.last_prices)
        for i in 1:length(s.instruments)
            a.last_prices[i] = mid(s.quotes[i])
        end
        return a
    end

    for i in 1:length(s.instruments)
        current_price = mid(s.quotes[i])
        prev_price = a.last_prices[i]

        # Calculate return since last bar
        ret = log(current_price) - log(prev_price)

        # Check if range threshold exceeded
        if abs(ret) >= a.range_size
            # Valid Bar: Commit to memory
            push!(a.memory[i], ret)
            a.last_prices[i] = current_price
        end
    end
    return a
end

function k_nearest_neighbors(history::Vector{Float64}, pattern::AbstractVector{Float64}, k::Int)
    len_p = length(pattern)
    n = length(history)

    # We need at least one past instance of (Pattern + Outcome)
    # Total history must be > len_p + 1 (for outcome) + others
    if n < (len_p + 1) * 2
        return 0.0 # Not enough data
    end

    # Simple brute force search (optimization: use KDTree if slow, but for <10k pts brute is fast in Julia with SIDM)
    # We scan from 1 to N - len_p - 1
    # Candidate start indices
    candidates = 1:(n-len_p-1)

    # Calculate costs
    # Use a priority queue? Or partial sort? 
    # For simplicity: Calculate all distances, take partialsort

    dists = Float64[]
    outcomes = Float64[]

    for i in candidates
        # Slice history window
        window = view(history, i:(i+len_p-1))
        d = norm(window .- pattern)

        push!(dists, d)
        push!(outcomes, history[i+len_p]) # The value *after* the window
    end

    # Get indices of k smallest distances
    if length(dists) <= k
        perm = eachindex(dists)
    else
        perm = partialsortperm(dists, 1:k)
    end

    # Weighted average by inverse distance? Or simple average?
    # Simple average for robustness
    mean_outcome = mean(outcomes[perm])

    return mean_outcome
end

function Orders(a::PatternMatchAgent, s::State)
    # 1. Trigger check: Only trade if any instrument has formed a new bar since last call
    current_counts = length.(a.memory)
    if all(current_counts .== a.last_memory_counts)
        return Order[]
    end

    n_instruments = length(s.instruments)
    expected_returns = zeros(Float64, n_instruments)

    valid_signal = false

    for i in 1:n_instruments
        hist = a.memory[i]
        L = a.lookback

        if length(hist) <= L
            continue # Not enough current history to form a pattern
        end

        # Current pattern is the *last L* committed bars
        current_pattern = hist[end-L+1:end]

        # Predict
        pred = k_nearest_neighbors(hist[1:end-1], current_pattern, a.k)

        # Store prediction
        expected_returns[i] = pred

        if abs(pred) > 0
            valid_signal = true
        end
    end

    if !valid_signal
        return Order[]
    end

    # Convert expected returns to weights
    total_abs = sum(abs, expected_returns)
    if total_abs == 0
        return Order[]
    end

    weights = expected_returns ./ (total_abs + 1e-6) # Normalized to [-1, 1] range roughly

    # Update last seen counts
    a.last_memory_counts .= current_counts

    # Generate orders
    targetorders(s, weights)
end
