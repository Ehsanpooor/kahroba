// The top of the 3D marble board: the host's painted board, cut open where
// the deck holes are (the pits below show through). Unlit, so it looks
// exactly like the design; it still receives the cards' shadows.
shader_type spatial;
render_mode cull_disabled, depth_draw_opaque;

uniform sampler2D tex : source_color, filter_linear_mipmap, repeat_disable;
uniform vec4 holes[3]; // x, y, w, h in UV
uniform float hole_r = 0.008; // rounded corners (UV x)

float in_hole(vec2 uv, vec4 h) {
	vec2 c = h.xy + h.zw * 0.5;
	vec2 q = abs(uv - c) - h.zw * 0.5 + hole_r;
	return step(length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - hole_r, 0.0);
}

void fragment() {
	vec4 c = texture(tex, UV);
	float cut = max(max(in_hole(UV, holes[0]), in_hole(UV, holes[1])), in_hole(UV, holes[2]));
	if (c.a < 0.5 || cut > 0.5) {
		discard;
	}
	ALBEDO = c.rgb * 0.3;
	EMISSION = c.rgb * 0.75;
	ROUGHNESS = 0.4;
	SPECULAR = 0.3;
}
