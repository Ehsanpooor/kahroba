// A gem-merchant dialog body: dark onyx-green leather with a gold bevelled
// rim, a fine inner gold line, and an inner shadow under the rim. No glow.
// The control is exactly the panel (no padding). Used until the painted
// dialog body (art/generated/ui3/dialog_body.png) exists.
shader_type canvas_item;

uniform vec2 size = vec2(800.0, 500.0);
uniform float radius = 28.0;
uniform float rim = 12.0;
uniform vec3 leather : source_color = vec3(0.055, 0.075, 0.06);

float hash(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), u.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), u.x), u.y);
}

float sd_box(vec2 p, vec2 b, float r) {
	vec2 q = abs(p) - b + r;
	return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

void fragment() {
	vec2 p = (UV - 0.5) * size;
	float d = sd_box(p, size * 0.5, radius);  // < 0 inside
	// leather: soft grain and a little mottling, lighter in the middle
	float n = noise(p / 7.0) * 0.5 + noise(p / 23.0) * 0.35 + noise(p / 60.0) * 0.15;
	vec3 c = leather * (0.75 + 0.5 * n);
	c *= 1.0 + 0.35 * (1.0 - smoothstep(0.0, 0.7, length(UV - vec2(0.5, 0.4))));
	float inner = -d - rim;
	// shadow cast by the rim onto the leather
	c *= 1.0 - 0.55 * exp(-max(inner, 0.0) / 10.0) * step(0.0, inner);
	// a fine inner gold line
	c = mix(c, vec3(0.72, 0.55, 0.26), (1.0 - smoothstep(0.4, 1.3, abs(inner - 9.0))) * 0.75);
	// the gold rim, bevelled: light from the top
	float t = clamp(-d / rim, 0.0, 1.0);
	float bevel = sin(t * 3.14159);
	vec3 gold = mix(vec3(0.5, 0.33, 0.1), vec3(1.0, 0.84, 0.48), bevel);
	gold *= 0.85 + 0.3 * (1.0 - UV.y);
	c = mix(c, gold, 1.0 - smoothstep(-0.6, 0.6, inner));
	COLOR = vec4(c, 1.0 - smoothstep(-0.8, 0.4, d));
}
