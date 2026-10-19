// Glossy cost pip (a coloured enamel bead) like the mockup's cost circles.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix, shadows_disabled;

#include "res://shaders/common.gdshaderinc"

uniform vec4 col : source_color = vec4(0.8, 0.1, 0.1, 1.0);
uniform float alpha = 1.0;
uniform float dissolve = 0.0;

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);
	float a = 1.0 - smoothstep(0.93, 1.0, r);
	vec3 c = col.rgb * (0.7 + 0.5 * (1.0 - r));
	c += vec3(1.0) * 0.45 * (1.0 - smoothstep(0.0, 0.42, length(p - vec2(-0.32, -0.38))));
	c = mix(c, col.rgb * 0.3, smoothstep(0.78, 0.97, r));
	c = mix(c, vec3(0.05), smoothstep(0.9, 0.98, r));
	vec3 wp = world_pos(INV_VIEW_MATRIX, VERTEX);
	c *= mix(1.0, candle(wp), 0.6);
	if (dissolve > 0.0) {
		a *= step(dissolve, fbm(UV * 4.0 + 11.0) + 0.05);
	}
	ALBEDO = c;
	ALPHA = a * alpha;
}
