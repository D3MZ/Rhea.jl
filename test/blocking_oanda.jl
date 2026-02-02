using Persephone
using Dates
using JSON

@info "Starting Oanda Blocking Test"
config = Persephone.OandaConfig("config.json")

# Start the stream
lines = Persephone.stream(config.streaming_url_full, config.headers)

@info "Stream started. Waiting for initial ticks..."

# 1. Take 3 ticks to confirm it works
for i in 1:3
    line = take!(lines)
    msg = JSON.parse(line)
    @info "Received tick $i" type = get(msg, "type", "PRICE") time = get(msg, "time", "N/A")
end

@info "SUCCESS: Initial ticks received. Now BLOCKING for 30 seconds..."

# 2. Block the consumer. This will fill the internal Channel(10) and then block the HTTP task.
sleep(30)

@info "UNBLOCKING. Resuming consumption..."

# 3. Resume taking ticks. 
# We should see the buffered ticks first (up to 10), then live ones.
# If Oanda disconnected, Core.stream should have reconnected (we might see a @warn in logs).

ticks_to_collect = 10
for i in 1:ticks_to_collect
    if !isready(lines)
        @info "Channel empty, waiting for next tick..."
    end
    line = take!(lines)
    msg = JSON.parse(line)
    @info "Received post-block tick $i" type = get(msg, "type", "PRICE") time = get(msg, "time", "N/A")
end

@info "SUCCESS: Stream resumed successfully after blocking."
close(lines)
@info "Test complete."
