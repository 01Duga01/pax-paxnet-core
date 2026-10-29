extends RefCounted
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
# If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# ОБЩИЙ СЧЁТЧИК СЛУЧАЙНОСТЕЙ. Хост задаёт зерно партии и номер шага; всё, что у игроков должно
# выпасть одинаково (бои, события, процедурные отряды), берёт поток отсюда: (зерно, шаг, имя
# потока) → одна и та же последовательность у всех. Алгоритм PCG32 — одинаков на любой машине,
# в отличие от RandomNumberGenerator движка, который не обещает стабильности между версиями.

const MULT := 6364136223846793005

var _state := 0
var _inc := 0


static func at(world_seed: int, tick: int, stream: String = "") -> RefCounted:
	var r = new()
	r.seed_with(world_seed, tick, stream)
	return r


func seed_with(world_seed: int, tick: int, stream: String = "") -> void:
	var s := _splitmix(world_seed ^ (tick * -7046029254386353131))
	_inc = (_splitmix(s ^ _fnv(stream)) << 1) | 1
	_state = 0
	next_u32()
	_state += s
	next_u32()


# FNV-1a по байтам строки: одинаков на любой машине и версии движка, в отличие от hash().
static func _fnv(s: String) -> int:
	var h := -3750763034362895579
	for b in s.to_utf8_buffer():
		h = (h ^ int(b)) * 1099511628211
	return h


static func _splitmix(x: int) -> int:
	x += 0x1E3779B97F4A7C15
	x = (x ^ (x >> 30)) * 0x3F58476D1CE4E5B9
	x = (x ^ (x >> 27)) * 0x14D049BB133111EB
	return x ^ (x >> 31)


func next_u32() -> int:
	var old := _state
	_state = old * MULT + _inc
	var xorshifted := (((old >> 18) ^ old) >> 27) & 0xFFFFFFFF
	var rot := (old >> 59) & 31
	return ((xorshifted >> rot) | (xorshifted << ((-rot) & 31))) & 0xFFFFFFFF


# Имена не совпадают со встроенными randf/randi_range: голый вызов внутри класса ушёл бы в общий
# генератор движка (так и было — тест сверки поймал рассинхрон).
func frand() -> float:
	return float(next_u32()) / 4294967296.0


func irange(lo: int, hi: int) -> int:
	if hi <= lo:
		return lo
	return lo + int(next_u32() % (hi - lo + 1))


func chance(p: float) -> bool:
	return self.frand() < p


func pick(a: Array):
	return a[next_u32() % a.size()] if not a.is_empty() else null
