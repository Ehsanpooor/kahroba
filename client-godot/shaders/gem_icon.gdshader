// A cut gem icon lying on the table: the painted gem when it exists, else a
// faceted gem drawn here (crown facets, table, sparkle).
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix, shadows_disabled;

uniform sampler2D tex : source_color, filter_linear_mipmap, repeat_disable;
uniform float has_tex = 0.0;
uniform vec3 col : source_color = vec3(0.8, 0.1, 0.1);
uniform vec3 glint : source_color = vec3(1.0);
uniform float alpha = 1.0;

void fragment() {
	if (has_tex > 0.5) {
		vec4 t = texture(tex, UV);
		ALBEDO = t.rgb;
		ALPHA = t.a * alpha;
	} else {
		vec2 p = (UV - 0.5) * 2.0;
		p.y *= 1.12;
		float ang = atan(p.y, p.x);
		float k = cos(PI / 8.0) / cos(mod(ang, PI / 4.0) - PI / 8.0);
		float r = length(p) / k;
		float a = 1.0 - smoothstep(0.82, 0.88, r);
		float tbl = 1.0 - smoothstep(0.42, 0.46, r);
		float facet = 0.5 + 0.5 * cos(ang * 8.0 + 0.4);
		vec3 c = col * (0.55 + 0.55 * facet);
		c = mix(c, col * 1.15 + 0.12, tbl);
		c = mix(c, col * 0.35, smoothstep(0.7, 0.86, r));
		float lines = 1.0 - smoothstep(0.0, 0.06, abs(sin(ang * 4.0)) * r);
		c += glint * 0.18 * lines * (1.0 - tbl);
		c += glint * 0.9 * pow(max(0.0, 1.0 - length(p - vec2(-0.25, -0.3)) * 3.2), 2.0);
		c = mix(c, vec3(0.02), smoothstep(0.84, 0.88, r) * 0.8);
		ALBEDO = c;
		ALPHA = a * alpha;
	}
}
