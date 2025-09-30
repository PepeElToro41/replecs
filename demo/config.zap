opt server_output = "src/server/zap.luau"
opt client_output = "src/shared/zap.luau"

type Variants = unknown[][]

funct WaitForServer = {
    call: Async,
    rets: (buffer?, Variants?)
}


event OnUnreliableUpdates = {
    from: Server,
    type: OrderedUnreliable,
    call: Polling,
    data: (buf: buffer, variants: Variants?)
}

event OnReliableUpdates = {
    from: Server,
    type: Reliable,
    call: Polling,
    data: (buf: buffer, variants: Variants?)
}