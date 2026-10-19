// Player panel: dark inset with a double gold border and a slow sheen.
// Placeholder until panel_frame.png arrives from the art pass.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix, shadows_disabled;

#include "res://shaders/common.gdshaderinc"

uniform vec2 size_px = vec2(852.0, 300.0);
uniform float chamfer = 26.0;
uniform vec4 fill : source_color = vec4(0.045, 0.052, 0.075, 0.9);
uniform float glow = 0.0;
uniform float lines = 1.0;

void fragment() {
	vec2 p = UV * size_px;
	vec2 e = min(p, size_px - p);
	float d = min(min(e.x, e.y), (e.x + e.y - chamfer) * 0.7071);
	vec3 wp = world_pos(INV_VIEW_MATRIX, VERTEX);
	float n = fbm(p * 0.02);
	vec3 col = fill.rgb * (0.8 + 0.4 * n);
	float sheen = 0.5 + 0.5 * sin((p.x - p.y * 0.5) * 0.01 - TIME * 0.7);
	vec3 gold = mix(vec3(0.4, 0.27, 0.09), vec3(1.0, 0.83, 0.46), sheen * 0.75 + 0.2 * n);
	float l1 = (1.0 - smoothstep(0.7, 1.6, abs(d - 3.5))) * lines;
	float l2 = (1.0 - smoothstep(0.4, 1.0, abs(d - 10.0))) * lines;
	float inner = smoothstep(14.0, 60.0, d);
	col *= 0.75 + 0.25 * inner;
	col = mix(col, gold, max(l1, l2 * 0.8));
	col += vec3(1.0, 0.75, 0.35) * glow * (1.0 - smoothstep(0.0, 40.0, d)) * 0.5;
	col *= candle(wp);
	ALBEDO = col;
	ALPHA = max(fill.a, max(l1, l2)) * smoothstep(-0.5, 0.8, d);
}
