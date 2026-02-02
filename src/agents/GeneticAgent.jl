export GeneticAgent, Node, OpNode, FeatureNode, ConstNode, random_node, simplify

using DataStructures
using Statistics
using Random

# ==========================================
# 1. The Language (AST)
# ==========================================

abstract type Node end

# --- Operations ---
struct OpNode{S} <: Node
    op::Symbol
    children::Vector{Node}
end

# --- Terminals ---
struct FeatureNode{S} <: Node
    feature::Symbol # :Price, :Mean, :Std, :Max, :Min
    param::Int      # Window size
end

struct ConstNode <: Node
    val::Float64
end

Base.:(==)(a::ConstNode, b::ConstNode) = a.val == b.val
Base.:(==)(a::FeatureNode{S}, b::FeatureNode{S}) where S = a.param == b.param
Base.:(==)(a::FeatureNode, b::FeatureNode) = false
Base.:(==)(a::OpNode{S}, b::OpNode{S}) where S = length(a.children) == length(b.children) && all(a.children .== b.children)
Base.:(==)(a::OpNode, b::OpNode) = false

Base.hash(a::ConstNode, h::UInt) = hash(a.val, h)
Base.hash(a::FeatureNode{S}, h::UInt) where S = hash(a.param, hash(S, h))
Base.hash(a::OpNode{S}, h::UInt) where S = hash(a.children, hash(S, h))

# --- Evaluator ---

evaluate(n::ConstNode, ::CircularBuffer{Float64})::Float64 = n.val

# Optimized evaluation for OpNodes using multiple dispatch
evaluate(n::OpNode{:+}, h)::Float64 = evaluate(n.children[1], h)::Float64 + evaluate(n.children[2], h)::Float64
evaluate(n::OpNode{:-}, h)::Float64 = evaluate(n.children[1], h)::Float64 - evaluate(n.children[2], h)::Float64
evaluate(n::OpNode{:*}, h)::Float64 = evaluate(n.children[1], h)::Float64 * evaluate(n.children[2], h)::Float64
function evaluate(n::OpNode{:/}, h)::Float64
    v2 = evaluate(n.children[2], h)::Float64
    iszero(v2) ? 0.0 : evaluate(n.children[1], h)::Float64 / v2
end
evaluate(n::OpNode{:Max}, h)::Float64 = max(evaluate(n.children[1], h)::Float64, evaluate(n.children[2], h)::Float64)
evaluate(n::OpNode{:Min}, h)::Float64 = min(evaluate(n.children[1], h)::Float64, evaluate(n.children[2], h)::Float64)
evaluate(n::OpNode{:IfGT}, h)::Float64 = evaluate(n.children[1], h)::Float64 > evaluate(n.children[2], h)::Float64 ? 
                                evaluate(n.children[3], h)::Float64 : evaluate(n.children[4], h)::Float64

# Optimized evaluation for FeatureNodes
evaluate(n::FeatureNode, h)::Float64 = length(h) < n.param ? 0.0 : _eval_feature(n, h)::Float64

_eval_feature(n::FeatureNode{:Price}, h)::Float64 = h[lastindex(h) - n.param + 1]
_eval_feature(n::FeatureNode{:Delta}, h)::Float64 = h[end] - h[lastindex(h) - n.param + 1]
_eval_feature(n::FeatureNode{:Mean}, h)::Float64 = mean(view(h, (length(h)-n.param+1):length(h)))
_eval_feature(n::FeatureNode{:Std}, h)::Float64 = std(view(h, (length(h)-n.param+1):length(h)))
_eval_feature(n::FeatureNode{:Max}, h)::Float64 = maximum(view(h, (length(h)-n.param+1):length(h)))
_eval_feature(n::FeatureNode{:Min}, h)::Float64 = minimum(view(h, (length(h)-n.param+1):length(h)))

function _eval_feature(n::FeatureNode{:MaxIndex}, h)::Float64
    window = view(h, (length(h)-n.param+1):length(h))
    _, idx = findmax(window)
    return Float64(length(window) - idx)
end

function _eval_feature(n::FeatureNode{:MinIndex}, h)::Float64
    window = view(h, (length(h)-n.param+1):length(h))
    _, idx = findmin(window)
    return Float64(length(window) - idx)
end

function _eval_feature(n::FeatureNode{:UpMean}, h)::Float64
    idx = (length(h)-n.param+1):length(h)
    s = 0.0
    for i in 2:length(idx)
        s += max(h[idx[i]] - h[idx[i-1]], 0.0)
    end
    return s / (n.param - 1)
end

function _eval_feature(n::FeatureNode{:DownMean}, h)::Float64
    idx = (length(h)-n.param+1):length(h)
    s = 0.0
    for i in 2:length(idx)
        s += max(h[idx[i-1]] - h[idx[i]], 0.0)
    end
    return s / (n.param - 1)
end

# --- Simplification ---
simplify(n::ConstNode) = n
simplify(n::FeatureNode) = n

function simplify(n::OpNode{S}) where S
    # 1. Simplify children first
    kids = Node[simplify(c) for c in n.children]
    
    # 2. Constant Folding
    if all(k -> k isa ConstNode, kids)
        dummy = CircularBuffer{Float64}(1)
        return ConstNode(evaluate(OpNode{S}(S, kids), dummy))
    end
    
    # 3. Identity & Logic Reductions
    if S == :+
        (kids[1] isa ConstNode && kids[1].val == 0.0) && return kids[2]
        (kids[2] isa ConstNode && kids[2].val == 0.0) && return kids[1]
    elseif S == :-
        (kids[2] isa ConstNode && kids[2].val == 0.0) && return kids[1]
        kids[1] == kids[2] && return ConstNode(0.0)
    elseif S == :*
        (kids[1] isa ConstNode && kids[1].val == 0.0) && return ConstNode(0.0)
        (kids[2] isa ConstNode && kids[2].val == 0.0) && return ConstNode(0.0)
        (kids[1] isa ConstNode && kids[1].val == 1.0) && return kids[2]
        (kids[2] isa ConstNode && kids[2].val == 1.0) && return kids[1]
    elseif S == :/
        (kids[1] isa ConstNode && kids[1].val == 0.0) && return ConstNode(0.0)
        (kids[2] isa ConstNode && kids[2].val == 1.0) && return kids[1]
        kids[1] == kids[2] && return ConstNode(1.0)
    elseif S == :IfGT
        if kids[1] isa ConstNode && kids[2] isa ConstNode
            return kids[1].val > kids[2].val ? kids[3] : kids[4]
        end
        kids[1] == kids[2] && return kids[4]
    end
    
    return OpNode{S}(S, kids)
end

# ==========================================
# 2. The Agent
# ==========================================

mutable struct GeneticAgent{N,T} <: Agent
    genome::Node
    
    # Memory: One buffer per instrument (SVector of references)
    history::SVector{N, CircularBuffer{Float64}}
    
    risk::T
    cash_target::T
end

function GeneticAgent(s::State{T,L,N}, genome::Node; risk=0.9, cash_target=0.1, lookback=200) where {T,L,N}
    # Init history buffers
    history = SVector{N, CircularBuffer{Float64}}(ntuple(_ -> CircularBuffer{Float64}(lookback), N))
    
    # Pre-fill with current price
    for i in 1:N
        push!(history[i], mid(s.quotes[i]))
    end
    
    GeneticAgent{N,T}(genome, history, T(risk), T(cash_target))
end

# --- Execution ---

function Orders(a::GeneticAgent{N,T}, s::State{T,L,N,M}) where {N,T,L,M}
    # Construction of signals manually to avoid closure allocations in ntuple
    sig_vals = MVector{N, Float64}(undef)
    @inbounds for i in 1:N
        sig_vals[i] = length(a.history[i]) > 10 ? tanh(evaluate(a.genome, a.history[i])::Float64) : 0.0
    end
    signals = SVector{N, Float64}(sig_vals)
    
    sum_abs = sum(abs, signals)
    if sum_abs < 1e-6
        return MarketOrder{T}[]
    end
    
    scale = (a.risk * (1.0 - a.cash_target)) / (sum_abs + eps())
    weights = signals .* scale
    
    targetorders(s, weights)
end

# --- State Update ---
# This is where we learn/record history
function Agent(a::GeneticAgent, ::State, ::Any, ::Any, s_new::State)
    # Update history buffers with new mid-prices
    for i in 1:length(s_new.instruments)
        push!(a.history[i], mid(s_new.quotes[i]))
    end
    a
end

# ==========================================
# 3. Evolution Helpers (Constructors)
# ==========================================

function random_node(depth::Int, max_depth::Int)
    if depth >= max_depth || (depth > 1 && rand() < 0.3)
        # Terminal
        if rand() < 0.7
            # Feature
            f = rand([:Price, :Delta, :Mean, :Std, :Max, :Min, :MaxIndex, :MinIndex, :UpMean, :DownMean])
            p = rand([5, 10, 14, 20, 50, 100])
            return FeatureNode{f}(f, p)
        else
            # Const
            return ConstNode(randn())
        end
    else
        # Operator
        op = rand([:+, :-, :*, :/, :IfGT, :Max, :Min])
        children = []
        n_children = op == :IfGT ? 4 : 2
        for _ in 1:n_children
            push!(children, random_node(depth + 1, max_depth))
        end
        return OpNode{op}(op, children)
    end
end

# --- Serialization ---
function dict(n::ConstNode)
    Dict("type" => "Const", "val" => n.val)
end

function dict(n::FeatureNode{S}) where S
    Dict("type" => "Feature", "feature" => string(S), "param" => n.param)
end

function dict(n::OpNode{S}) where S
    Dict("type" => "Op", "op" => string(S), "children" => [dict(c) for c in n.children])
end

function node_from_dict(d::AbstractDict)
    type = d["type"]
    if type == "Const"
        return ConstNode(Float64(d["val"]))
    elseif type == "Feature"
        f = Symbol(d["feature"])
        return FeatureNode{f}(f, Int(d["param"]))
    elseif type == "Op"
        op = Symbol(d["op"])
        children = Node[node_from_dict(c) for c in d["children"]]
        return OpNode{op}(op, children)
    end
    error("Unknown node type: $type")
end
