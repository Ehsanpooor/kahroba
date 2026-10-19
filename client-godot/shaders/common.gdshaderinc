// Shared lighting + noise for every flat-art shader on the table.
// Lighting is faked (unshaded) so painted art keeps its colours and the
// look is identical on web/mobile; "candle" is one warm pool of light.

global uniform vec3 pointer_world;
global uniform vec3 light_center;
global uniform float px_unit;
global uniform float flicker;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash21(i), hash21(i + vec2(1.0, 0.0)), u.x),
			mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), u.x), u.y);
}

float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 5; i++) {
		v += a * vnoise(p);
		p = p * 2.03 + vec2(1.7, 9.2);
		a *= 0.5;
	}
	return v;
}

// distance in mockup pixels between a world point and the light pool centre
float candle(vec3 wp) {
	vec2 d = (wp.xz - light_center.xz) / px_unit;
	float r = length(d * vec2(1.0, 0.62));
	float pool = 1.0 - smoothstep(120.0, 1250.0, r);
	return (0.62 + 0.48 * pool) * (1.0 + flicker * 0.05);
}

float pointer_glow(vec3 wp) {
	float r = length(wp.xz - pointer_world.xz) / px_unit;
	return 1.0 - smoothstep(0.0, 240.0, r);
}

vec3 world_pos(mat4 inv_view, vec3 view_vertex) {
	return (inv_view * vec4(view_vertex, 1.0)).xyz;
}
