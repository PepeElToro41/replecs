opt server_output = "src/server/zap.luau"
opt client_output = "src/shared/zap.luau"

funct WaitForServer = {
	call: Async,
	rets: (
		buffer?,
		unknown,
		unknown,
	),
}

event OnUnreliableUpdates = {
	from: Server,
	type: OrderedUnreliable,
	call: Polling,
	data: (
		buf: buffer,
		variants: unknown,
	),
}

event OnReliableUpdates = {
	from: Server,
	type: Reliable,
	call: Polling,
	data: (
		buf: buffer,
		variants: unknown,
	),
}
