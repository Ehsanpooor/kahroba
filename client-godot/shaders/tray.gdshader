// Your area along the bottom: dark leather with a gold edge that glows on
// your turn.
shader_type spatial;
render_mode cull_disabled;

#include "res://shaders/common.gdshaderinc"

uniform vec2 size_px = vec2(1880.0, 200.0);
uniform float glow = 0.0;

void fragment() {
	vec2 px = UV * size_px;
	float n = fbm(UV * vec2(40.0, 5.0));
	vec3 c = vec3(0.07, 0.055, 0.05) * (0.75 + 0.5 * n);
	float d = min(min(px.x, size_px.x - px.x), min(px.y, size_px.y - px.y));
	vec3 gold = vec3(0.92, 0.72, 0.36);
	c = mix(c, gold * 0.75, 1.0 - smoothstep(2.0, 3.5, d));
	c = mix(c, gold * 0.6, (1.0 - smoothstep(0.4, 1.1, abs(d - 7.0))) * 0.8);
	ALBEDO = c;
	EMISSION = c * 0.4 + gold * glow * 0.5 * (1.0 - smoothstep(0.0, 12.0, d));
	ROUGHNESS = 0.7;
	SPECULAR = 0.2;
}
