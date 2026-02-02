using Rhea, Statistics, Dates, Random, Logging, JSON
import Rhea: GeneticAgent, Node, OpNode, FeatureNode, ConstNode, dict, node_from_dict, State, Reward, run!, nlv, DataBroker, mid, targetorders

Base.copy(n::ConstNode) = ConstNode(n.val)
Base.copy(n::FeatureNode{S}) where S = FeatureNode{S}(S, n.param)
Base.copy(n::OpNode{S}) where S = OpNode{S}(S, Node[copy(c) for c in n.children])

function sample(root::Node)
    choice = root
    i = 0
    function walk(n)
        i += 1
        rand() < 1/i && (choice = n)
        n isa OpNode && foreach(walk, n.children)
    end
    walk(root)
    return choice
end

swap(root::Node, target::Node, replacement::Node) = 
    root === target ? copy(replacement) : replace_node(root, target, replacement)

replace_node(n::OpNode, target::Node, replacement::Node) = 
    OpNode{n.op}(n.op, Node[swap(c, target, replacement) for c in n.children])

replace_node(n::Node, ::Node, ::Node) = n

# --- Genetic Primitives ---

mutate(root::Node) = 
    swap(root, sample(root), rand() < 0.5 ? Rhea.random_node(1, 4) : Rhea.random_node(3, 3))

crossover(p1::Node, p2::Node) = 
    swap(p1, sample(p1), sample(p2))

# --- Metrics & Simulation ---

mutable struct TurnoverTracker <: Reward
    total::Float64
    TurnoverTracker() = new(0.0)
end

function Rhea.Reward(r::TurnoverTracker, s1::State, s2::State)
    r.total += sum(i -> abs(s2.positions[i].units - s1.positions[i].units), eachindex(s1.positions))
    return 0.0
end

struct Outcome
    fitness::Float64
    days::Float64
    nlv::Float64
    turnover::Float64
    success::Bool
end

Outcome() = Outcome(-Inf, 0.0, 0.0, 0.0, false)

function simulate(genome, config)
    try
        broker = DataBroker(configpath=config)
        state = State(broker)
        balance₁ = state.cash
        tracker = TurnoverTracker()
        
        start = state.time
        final = run!(GeneticAgent(state, genome), broker, tracker)
        
        days = Dates.value(final.time - start) / 8.64e7
        val = nlv(final)
        fitness = iszero(tracker.total) ? -Inf : (val * days)/balance₁
        
        @info "Eval | Fit: $(round(fitness, digits=1)) | NLV: $(round(val)) | Vol: $(round(tracker.total, digits=3)) | Days: $(round(days, digits=1))"
        return Outcome(fitness, days, val, tracker.total, true)
    catch e
        @error "Simulation failed" exception=(e, catch_backtrace())
        return Outcome()
    end
end

# --- Persistence ---

save_pop(pop, path) = (mkpath(dirname(path)); open(io -> JSON.print(io, dict.(pop)), path, "w"))

load_pop(path) = isfile(path) ? node_from_dict.(JSON.parsefile(path)) : nothing

# --- Evolutionary Loop ---

function evaluate!(pop, cache, config)
    pending = filter(g -> !haskey(cache, g), pop)
    
    if !isempty(pending)
        results = Vector{Outcome}(undef, length(pending))
        Threads.@threads for i in eachindex(pending)
            results[i] = simulate(pending[i], config)
        end
        for (g, res) in zip(pending, results)
            cache[g] = res
        end
    end
    return [cache[g] for g in pop]
end

function select_node(pop, fits)
    i, j = rand(eachindex(pop)), rand(eachindex(pop))
    return fits[i] > fits[j] ? pop[i] : pop[j]
end

function advance(pop, fits)
    next = Vector{Node}(undef, length(pop))
    best = argmax(fits)
    next[1] = Rhea.simplify(pop[best])
    
    for i in 2:length(pop)
        child = crossover(select_node(pop, fits), select_node(pop, fits))
        child = rand() < 0.3 ? mutate(child) : child
        next[i] = Rhea.simplify(child)
    end
    return next, best
end

function resizepop(pop, size)
    pop === nothing && return Node[Rhea.random_node(1, 3) for _ in 1:size]
    n = length(pop)
    n >= size && return pop[1:size]
    needed = size - n
    vcat(pop, Node[Rhea.random_node(1, 3) for _ in 1:needed])
end

function evolve(; gens=50, size=1000, path="latest_population.json", config="configs/DataBroker.json")
    pop = resizepop(load_pop(path), size)
    cache = Dict{Node, Outcome}()
    for g in 1:gens
        outcomes = evaluate!(pop, cache, config)
        fits = [r.success ? r.fitness : -Inf for r in outcomes]
        
        # Sort population by fitness descending
        p = sortperm(fits, rev=true)
        pop = pop[p]
        fits = fits[p]
        outcomes = outcomes[p]
        
        save_pop(pop, path)
        
        best = outcomes[1]
        @info "Gen $g | Fit: $(round(best.fitness, digits=1)) | NLV: $(round(best.nlv)) | Vol: $(round(best.turnover, digits=3)) | Days: $(round(best.days, digits=1))"

        next_pop, idx = advance(pop, fits)
        pop = next_pop
    end
end

evolve()
