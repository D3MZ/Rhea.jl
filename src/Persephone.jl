module Persephone

using StatsBase, Dates, Random, StaticArrays, HTTP, JSON
import Plots: plot, plot!, savefig

export Agent, Broker, Reward
export Book, FilledOrder, Instrument, MarketOrder, Order, Orders, Position, Price, State, Weight
export BuyHold, CashOnly, DataBroker, EqualWeight, Harvest, LogReturnReward, MeanReversionAgent, MomentumAgent, NoTradeAgent, OandaBroker, PnLReward, RandomAgent, RandomWalkBroker, RuleBasedAgent, SharpeReward
export Stats, StatArbAgent, availablemargin, bestask, bestbid, closepositions!, conversion, fee, get, getcash, getinstruments, getpositions, getquotes, logreturn, margin, mid, nlv, order, orderfill, post, put, run!, stop!, stream, submitorder, summary, targetorders, update!, usedmargin
export GeneticAgent, Node, OpNode, FeatureNode, ConstNode, random_node, dict, node_from_dict, simplify

include("Core.jl")
include("agents/RandomAgent.jl")
include("agents/NoTradeAgent.jl")
include("agents/RuleBased.jl")
include("agents/StatArbAgent.jl")
include("agents/PatternMatching.jl")
include("agents/MomentumAgent.jl")
include("agents/MeanReversionAgent.jl")
include("agents/GeneticAgent.jl")
include("brokers/Oanda.jl")
include("brokers/DataBroker.jl")
include("brokers/RandomWalk.jl")
include("rewards/Rewards.jl")

end
