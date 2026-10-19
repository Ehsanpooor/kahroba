// Back of a development card: embossed leather in the level's colour, gold
// filigree and an empty medallion (the I / II / III is drawn on top).
shader_type spatial;
render_mode cull_disabled;

#include "res://shaders/common.gdshaderinc"

uniform sampler2D tex : source_color, filter_linear_mipmap, repeat_disable;
uniform float has_tex = 0.0;
uniform vec3 tier_col : source_color = vec3(0.16, 0.4, 0.2);
uniform vec2 size_px = vec2(266.0, 190.0);
uniform float highlight = 0.0;

void fragment() {
	vec2 uv = UV;
	vec3 c;
	if (has_tex > 0.5) {
		c = texture(tex, uv).rgb;
	} else {
		vec2 px = uv * size_px;
		vec2 q = px - size_px * 0.5;
		float n = fbm(uv * vec2(12.0, 9.0));
		c = tier_col * (0.55 + 0.5 * n);
		c *= 1.0 - 0.45 * smoothstep(0.3, 0.75, length(uv - 0.5));
		float d = min(min(px.x, size_px.x - px.x), min(px.y, size_px.y - px.y));
		vec3 gold = vec3(0.95, 0.75, 0.36);
		c = mix(c, gold, (1.0 - smoothstep(0.6, 1.6, abs(d - 9.0))) * 0.9);
		c = mix(c, gold * 0.8, (1.0 - smoothstep(0.4, 1.0, abs(d - 14.0))) * 0.6);
		// filigree: interlaced curves between the frame and the medallion
		vec2 a = abs(q) / size_px.y;
		float f = abs(sin(a.x * 22.0 + sin(a.y * 18.0) * 1.6) * sin(a.y * 22.0 + sin(a.x * 14.0) * 1.4));
		float band = smoothstep(0.24, 0.3, length(q / size_px.yy));
		c = mix(c, gold * 0.75, (1.0 - smoothstep(0.03, 0.1, f)) * band * 0.45 * step(18.0, d));
		float r = length(q);
		c = mix(c, tier_col * 0.35, 1.0 - smoothstep(52.0, 54.0, r));
		c = mix(c, gold, 1.0 - smoothstep(1.0, 2.2, abs(r - 55.0)));
		c = mix(c, gold * 0.85, (1.0 - smoothstep(0.6, 1.4, abs(r - 61.0))) * 0.8);
	}
	vec3 wp = world_pos(INV_VIEW_MATRIX, VERTEX);
	ALBEDO = c * 0.65;
	EMISSION = c * (0.35 + highlight * (0.15 + 0.25 * pointer_glow(wp)));
	ROUGHNESS = 0.6;
	SPECULAR = 0.3;
}
