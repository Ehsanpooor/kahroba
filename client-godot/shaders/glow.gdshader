// Additive light: a soft blob (ring = 0) or a thin expanding ring (ring = 1).
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;

uniform vec4 color : source_color = vec4(1.0, 0.8, 0.4, 1.0);
uniform float intensity = 1.0;
uniform float ring = 0.0;
uniform float ring_width = 0.08;

void fragment() {
	float r = length(UV - 0.5) * 2.0;
	float blob = pow(max(1.0 - r, 0.0), 2.2);
	float rg = (1.0 - smoothstep(0.0, ring_width, abs(r - 0.86))) * (1.0 - smoothstep(0.96, 1.0, r));
	float v = mix(blob, rg, ring);
	ALBEDO = color.rgb;
	ALPHA = clamp(v * intensity, 0.0, 1.0);
}
