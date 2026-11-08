package host

Result_Ok :: struct($T: typeid) {
	value: T,
}

Result_Err :: struct($T: typeid) {
	value: T,
}

Result :: union($Ok: typeid, $Err: typeid) #no_nil {
	Result_Ok(Ok),
	Result_Err(Err),
}

Outbox_Result :: Result(struct {}, string)

Outbox_Result_Args :: struct($Row: typeid) {
	row: Row,
	result: Outbox_Result,
}
