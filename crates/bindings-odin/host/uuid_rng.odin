package host

Uuid_Rng_State :: struct {
	key: [8]u32,
	counter: u64,
	block: [64]u8,
	offset: int,
}

uuid_rng_from_seed :: proc "contextless" (seed: u64) -> Uuid_Rng_State {
	state := Uuid_Rng_State{offset = 64}
	pcg_state := seed
	for index in 0 ..< len(state.key) {
		pcg_state = pcg_state * 6364136223846793005 + 11634580027462260723
		xorshifted := u32(((pcg_state >> 18) ~ pcg_state) >> 27)
		rotation := u32(pcg_state >> 59)
		state.key[index] = xorshifted >> rotation | xorshifted << ((32 - rotation) & 31)
	}
	return state
}

@(private)
uuid_rng_rotate_left :: proc "contextless" (value: u32, rotation: u32) -> u32 {
	return value << rotation | value >> (32 - rotation)
}

@(private)
uuid_rng_quarter_round :: proc "contextless" (words: ^[16]u32, a, b, c, d: int) {
	words[a] += words[b]
	words[d] = uuid_rng_rotate_left(words[d] ~ words[a], 16)
	words[c] += words[d]
	words[b] = uuid_rng_rotate_left(words[b] ~ words[c], 12)
	words[a] += words[b]
	words[d] = uuid_rng_rotate_left(words[d] ~ words[a], 8)
	words[c] += words[d]
	words[b] = uuid_rng_rotate_left(words[b] ~ words[c], 7)
}

@(private)
uuid_rng_next_block :: proc "contextless" (state: ^Uuid_Rng_State) {
	initial := [16]u32{
		0x61707865, 0x3320646e, 0x79622d32, 0x6b206574,
		state.key[0], state.key[1], state.key[2], state.key[3],
		state.key[4], state.key[5], state.key[6], state.key[7],
		u32(state.counter), u32(state.counter >> 32), 0, 0,
	}
	working := initial
	for _ in 0 ..< 6 {
		uuid_rng_quarter_round(&working, 0, 4, 8, 12)
		uuid_rng_quarter_round(&working, 1, 5, 9, 13)
		uuid_rng_quarter_round(&working, 2, 6, 10, 14)
		uuid_rng_quarter_round(&working, 3, 7, 11, 15)
		uuid_rng_quarter_round(&working, 0, 5, 10, 15)
		uuid_rng_quarter_round(&working, 1, 6, 11, 12)
		uuid_rng_quarter_round(&working, 2, 7, 8, 13)
		uuid_rng_quarter_round(&working, 3, 4, 9, 14)
	}
	for word, index in working {
		value := word + initial[index]
		base := index * 4
		state.block[base] = u8(value)
		state.block[base + 1] = u8(value >> 8)
		state.block[base + 2] = u8(value >> 16)
		state.block[base + 3] = u8(value >> 24)
	}
	state.counter += 1
	state.offset = 0
}

uuid_rng_fill :: proc "contextless" (state: ^Uuid_Rng_State, output: []u8) {
	for &byte in output {
		if state.offset == len(state.block) do uuid_rng_next_block(state)
		byte = state.block[state.offset]
		state.offset += 1
	}
}
