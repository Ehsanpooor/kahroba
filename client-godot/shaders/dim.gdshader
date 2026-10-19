// Darkens the table behind an inspected card.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix, shadows_disabled;

uniform float alpha = 0.0;

void fragment() {
	ALBEDO = vec3(0.008, 0.01, 0.018);
	ALPHA = alpha;
}
