export NoTradeAgent

struct NoTradeAgent <: Agent end

const NO_ORDERS = Order[]
Orders(::NoTradeAgent, ::State) = NO_ORDERS
