// Flat painted art lying on (or floating above) the table: frames, badges,
// digits, silhouettes, nobles. Supports highlight, dissolve-in and a flash.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix, shadows_disabled;

#include "res://shaders/common.gdshaderinc"

uniform sampler2D tex : source_color, filter_linear_mipmap, repeat_disable;
uniform vec4 tint : source_color = vec4(1.0);
uniform float alpha : hint_range(0.0, 1.0) = 1.0;
uniform float lit : hint_range(0.0, 1.0) = 1.0;
uniform float highlight = 0.0;
uniform float flash = 0.0;
uniform float circle_mask = 0.0;
uniform vec4 uv_rect = vec4(0.0, 0.0, 1.0, 1.0);
uniform float clip_v = 2.0; // hide below this UV.y (portraits tuck behind their bracket)
uniform float dissolve : hint_range(0.0, 1.0) = 0.0;
uniform vec3 ember : source_color = vec3(1.0, 0.62, 0.22);

void fragment() {
	vec2 uv = uv_rect.xy + UV * uv_rect.zw;
	vec4 c = texture(tex, uv) * tint;
	vec3 wp = world_pos(INV_VIEW_MATRIX, VERTEX);
	c.rgb *= mix(1.0, candle(wp), lit);
	c.rgb *= 1.0 + highlight * (0.18 + 0.3 * pointer_glow(wp));
	c.rgb += vec3(1.0, 0.82, 0.5) * flash;
	float a = c.a * alpha * (1.0 - smoothstep(clip_v - 0.02, clip_v, UV.y));
	if (circle_mask > 0.5) {
		a *= 1.0 - smoothstep(0.46, 0.5, length(UV - 0.5));
	}
	if (dissolve > 0.0) {
		float n = fbm(UV * 5.0 + 3.1);
		float th = mix(-0.05, 1.0, dissolve);
		float edge = 1.0 - smoothstep(th, th + 0.1, n);
		c.rgb = mix(c.rgb, ember * 1.6, edge);
		a *= smoothstep(th - 0.01, th + 0.02, n);
	}
	ALBEDO = c.rgb;
	ALPHA = a;
}
