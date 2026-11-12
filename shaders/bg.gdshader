shader_type canvas_item;
// Arena floor: a grid that bends around the player and ripples with every shift.

uniform vec2 player_uv = vec2(0.5);
uniform float time_s = 0.0;
uniform float focus = 0.0;
uniform float hue = 0.55;
uniform float dim = 0.0;
uniform vec4 arena = vec4(0.04, 0.12, 0.92, 0.8);
uniform vec3 warps[6];      // xy = uv, z = ring radius (aspect units)
uniform float warp_s[6];    // strength, 0 = unused

vec3 hsv(float h, float s, float v) {
	vec3 k = clamp(abs(fract(h + vec3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0) - 1.0, 0.0, 1.0);
	return v * mix(vec3(1.0), k, s);
}

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

void fragment() {
	vec2 asp = vec2(16.0 / 9.0, 1.0);
	vec2 p = UV * asp;
	vec2 disp = vec2(0.0);
	float ripple = 0.0;
	for (int i = 0; i < 6; i++) {
		if (warp_s[i] > 0.001) {
			vec2 v = p - warps[i].xy * asp;
			float l = length(v) + 0.0001;
			float band = exp(-pow((l - warps[i].z) / 0.07, 2.0)) * warp_s[i];
			disp += v / l * band * 0.035;
			ripple += band;
		}
	}
	vec2 pv = p - player_uv * asp;
	float pl = length(pv) + 0.0001;
	float well = exp(-pl * pl / (0.012 + focus * 0.05));
	disp -= pv / pl * well * (0.012 + focus * 0.03);
	vec2 g = (p + disp) * 18.0;
	vec2 cell = abs(fract(g) - 0.5);
	float thin = smoothstep(0.47, 0.5, max(cell.x, cell.y));
	vec2 cell4 = abs(fract(g / 4.0) - 0.5);
	float thick = smoothstep(0.488, 0.5, max(cell4.x, cell4.y));
	float dots = smoothstep(0.46, 0.5, cell.x) * smoothstep(0.46, 0.5, cell.y);

	vec3 tint = hsv(hue, 0.65, 1.0);
	vec3 tint2 = hsv(hue + 0.12, 0.7, 1.0);
	float neb = noise(p * 2.2 + vec2(time_s * 0.03, -time_s * 0.02)) * noise(p * 5.0 - vec2(time_s * 0.02));
	vec3 col = vec3(0.016, 0.021, 0.044) + tint2 * neb * 0.07;
	float inside = step(arena.x, UV.x) * step(arena.y, UV.y) * step(UV.x, arena.x + arena.z) * step(UV.y, arena.y + arena.w);
	float lines = thin * 0.15 + thick * 0.24 + dots * 0.3;
	lines *= mix(0.35, 1.0, inside);
	lines *= 0.75 + 0.25 * sin(time_s * 0.7 + p.x * 3.0 + p.y * 2.0);
	col += tint * lines;
	col += tint * ripple * (0.10 + thin * 0.9);
	col += tint * well * 0.07 * (1.0 + focus * 2.0);
	col = mix(col, vec3(dot(col, vec3(0.3, 0.6, 0.1))) * vec3(0.7, 0.95, 1.25), focus * 0.5);
	col *= 1.0 - dim * 0.55;
	COLOR = vec4(col, 1.0);
}
