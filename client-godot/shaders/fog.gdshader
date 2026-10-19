// Slow drifting mist patches near the table edges.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix, shadows_disabled;

#include "res://shaders/common.gdshaderinc"

uniform vec4 color : source_color = vec4(0.55, 0.62, 0.8, 0.16);
uniform float speed = 0.015;
uniform float seed = 0.0;

void fragment() {
	vec2 drift = vec2(TIME * speed, TIME * speed * 0.6);
	float n = fbm(UV * 2.6 + drift + seed);
	float n2 = fbm(UV * 5.0 - drift * 1.7 + seed * 2.0);
	float mask = 1.0 - smoothstep(0.15, 0.5, length(UV - 0.5));
	float v = smoothstep(0.35, 0.85, n * 0.7 + n2 * 0.45) * mask;
	ALBEDO = color.rgb;
	ALPHA = color.a * v;
}
