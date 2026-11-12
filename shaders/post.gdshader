shader_type canvas_item;
// Screen pass: shockwave refraction, colour split, bloom, focus grade, vignette.

uniform sampler2D screen : hint_screen_texture, filter_linear, repeat_disable;
uniform float chroma = 0.0;
uniform float focus = 0.0;
uniform float flash = 0.0;
uniform float glitch = 0.0;
uniform float time_s = 0.0;
uniform vec3 shocks[4];     // xy = uv, z = radius (aspect units)
uniform float shock_s[4];

float hash(float n) {
	return fract(sin(n) * 43758.5453);
}

void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 asp = vec2(16.0 / 9.0, 1.0);
	for (int i = 0; i < 4; i++) {
		if (shock_s[i] > 0.001) {
			vec2 v = (uv - shocks[i].xy) * asp;
			float l = length(v) + 0.0001;
			float band = exp(-pow((l - shocks[i].z) / 0.045, 2.0)) * shock_s[i];
			uv += v / l * band * 0.028 / asp;
		}
	}
	if (glitch > 0.001) {
		float row = floor(uv.y * 28.0);
		float pick = step(0.82, hash(row * 3.7 + floor(time_s * 40.0) * 1.3));
		uv.x += (hash(row + floor(time_s * 40.0)) - 0.5) * 0.09 * glitch * pick;
	}
	vec2 dir = uv - 0.5;
	float ca = chroma + focus * 0.0025 + 0.0012;
	vec3 col;
	col.r = texture(screen, uv + dir * ca).r;
	col.g = texture(screen, uv).g;
	col.b = texture(screen, uv - dir * ca).b;

	// cheap bloom: two rings of taps, bright parts only
	vec3 bloom = vec3(0.0);
	vec2 px = SCREEN_PIXEL_SIZE;
	for (int i = 0; i < 8; i++) {
		float a = float(i) * 0.7854 + 0.3;
		vec2 o = vec2(cos(a), sin(a));
		bloom += max(texture(screen, uv + o * px * 5.0).rgb - 0.42, 0.0);
		bloom += max(texture(screen, uv + o * px * 13.0).rgb - 0.42, 0.0) * 0.6;
	}
	col += bloom * 0.085;

	float luma = dot(col, vec3(0.3, 0.6, 0.1));
	col = mix(col, luma * vec3(0.62, 0.95, 1.3), focus * 0.5);
	float vig = smoothstep(0.35, 0.95, length(dir * vec2(1.0, 0.85)) * 1.25);
	col *= 1.0 - vig * (0.42 + focus * 0.3);
	col += vec3(1.0, 0.12, 0.2) * flash * (0.22 + vig * 0.8);
	col *= 0.965 + 0.035 * sin(uv.y * 720.0 * 3.14159);
	COLOR = vec4(col, 1.0);
}
