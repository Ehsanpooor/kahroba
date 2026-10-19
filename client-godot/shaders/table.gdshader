// The tabletop: dark navy slate, worn gold arcane engraving, candle pool,
// and a warm glow that follows the player's finger.
shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled;

#include "res://shaders/common.gdshaderinc"

uniform vec2 rune_center = vec2(0.0);
uniform sampler2D table_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform vec4 board_rect = vec4(-5.0, -11.0, 10.0, 22.0); // world xz min, size
uniform float tex_mix = 1.0;
uniform vec3 base_dark : source_color = vec3(0.035, 0.043, 0.064);
uniform vec3 base_light : source_color = vec3(0.085, 0.097, 0.13);
uniform vec3 engrave : source_color = vec3(0.62, 0.47, 0.22);

float line(float d, float w) {
	return 1.0 - smoothstep(0.0, w, abs(d));
}

void fragment() {
	vec3 wp = world_pos(INV_VIEW_MATRIX, VERTEX);
	vec2 p = wp.xz / px_unit;

	float n = fbm(p * 0.0035);
	float n2 = fbm(p * 0.028 + 7.0);
	float grain = vnoise(p * 0.6);
	vec3 col = mix(base_dark, base_light, n);
	col *= 0.86 + 0.24 * n2 + 0.06 * grain;
	// painted tabletop, mirrored beyond the board edges
	vec2 tuv = (wp.xz - board_rect.xy) / board_rect.zw;
	tuv = 1.0 - abs(mod(tuv, 2.0) - 1.0);
	vec3 painted = texture(table_tex, tuv).rgb * (0.92 + 0.08 * grain);
	col = mix(col, painted, tex_mix);

	// arcane rings around the nobles
	vec2 q = (wp.xz - rune_center) / px_unit;
	float r = length(q);
	float ang = atan(q.y, q.x);
	float rings = line(r - 330.0, 1.8) + line(r - 344.0, 1.1) + 0.7 * line(r - 560.0, 1.4)
			+ 0.5 * line(r - 760.0, 1.2);
	float seg = abs(fract(ang / 6.28318 * 24.0) - 0.5);
	float spokes = line(seg * r * 0.26, 1.0) * step(344.0, r) * step(r, 560.0);
	float ticks = line(seg * r * 0.26, 1.5) * step(560.0, r) * step(r, 590.0);
	float wear = smoothstep(0.35, 0.75, fbm(p * 0.01 + 2.0));
	float eng = (rings + spokes * 0.55 + ticks * 0.8) * wear;
	col = mix(col, engrave, clamp(eng, 0.0, 1.0) * mix(0.16, 0.07, tex_mix));

	col *= candle(wp);
	col += vec3(0.09, 0.06, 0.025) * pointer_glow(wp) * 0.55;
	ALBEDO = col;
}
