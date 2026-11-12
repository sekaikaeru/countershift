extends SceneTree
## Headless check: plays N seeded games with the bot and prints what happened.
## Usage: godot --headless --path . -s tools/bot_test.gd -- [games] [skill]

const Sim = preload("res://scripts/sim.gd")
const Bot = preload("res://scripts/bot.gd")


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var games := int(args[0]) if args.size() > 0 else 20
	var skill := float(args[1]) if args.size() > 1 else 1.0
	var tot_wave := 0.0
	var tot_time := 0.0
	var tot_score := 0.0
	var scores: Array = []
	var max_enemies := 0
	var max_bullets := 0
	for g in games:
		var sim := Sim.new(1000 + g)
		var bot := Bot.new(77 + g, skill)
		var steps := 0
		var kinds := {}
		while sim.dead_t < 0.5 and steps < 60 * 60 * 20:
			var inp := bot.decide(sim, 1.0 / 60.0)
			sim.step(1.0 / 60.0, inp)
			for e in sim.events:
				kinds[e["k"]] = kinds.get(e["k"], 0) + 1
			sim.events.clear()
			max_enemies = maxi(max_enemies, sim.enemies.size())
			max_bullets = maxi(max_bullets, sim.bullets.size())
			for e in sim.enemies:
				assert(Sim.ARENA.grow(2.0).has_point(e.pos), "enemy left the arena")
			assert(Sim.ARENA.grow(1.0).has_point(sim.p_pos), "player left the arena")
			steps += 1
		print("seed %d: wave %d  time %.0fs  score %d  kills %d (shift %d)  swaps %d  chain %d  burst %d  timeout=%s" % [
			1000 + g, sim.wave, sim.real_time, sim.score, sim.kills, sim.shift_kills, sim.swaps, sim.max_chain, sim.best_burst, str(sim.alive)])
		if g == 0:
			print("  events: ", kinds)
		tot_wave += sim.wave
		tot_time += sim.real_time
		tot_score += sim.score
		scores.append(sim.score)
	scores.sort()
	print("AVG wave %.1f  time %.0fs  score %.0f  median %d  min %d  max %d  | peak enemies %d bullets %d" % [
		tot_wave / games, tot_time / games, tot_score / games, scores[games / 2], scores[0], scores[-1], max_enemies, max_bullets])
	quit()
