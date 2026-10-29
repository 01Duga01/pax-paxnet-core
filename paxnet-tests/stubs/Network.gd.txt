extends Node
var fake_factory: Callable = Callable()
func relay_pipe(first: Dictionary) -> Object:
	return fake_factory.call(first) if fake_factory.is_valid() else null
