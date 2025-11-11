opt server_output = "src/server/zap.luau"
opt client_output = "src/shared/zap.luau"

funct WaitForServer = {
	call: Async,
	rets: (
		buffer?,
		unknown,
	),
}

event OnUnreliableUpdates = {
	from: Server,
	type: OrderedUnreliable,
	call: SingleAsync,
	data: (
		buf: buffer,
		variants: unknown,
	),
}

event OnReliableUpdates = {
	from: Server,
	type: Reliable,
	call: SingleAsync,
	data: (
		buf: buffer,
		variants: unknown,
	),
}
