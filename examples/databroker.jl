using Rhea

function simulation()
    broker = DataBroker(configpath="configs/DataBroker.json")
    state = State(broker)
    agent = MomentumAgent(state)
    reward = PnLReward()
    run!(agent, broker, reward)
end 

simulation()