// A soft light behind a card in its level's colour (I green, II amber,
// III blue): a rounded-rectangle glow spilling onto the table.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;

uniform vec4 color : source_color = vec4(0.3, 0.8, 0.4, 1.0);
uniform float intensity = 0.7;
uniform vec2 box = vec2(0.82, 0.78); // the card inside the quad (half size, UV*2 space)

void fragment() {
	vec2 p = abs(UV * 2.0 - 1.0);
	vec2 q = p - box + 0.06;
	float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - 0.06;
	float g = exp(-max(d, 0.0) * 9.0) * (1.0 - smoothstep(0.92, 1.0, max(p.x, p.y)));
	ALBEDO = color.rgb;
	ALPHA = clamp(g * intensity, 0.0, 1.0);
}
