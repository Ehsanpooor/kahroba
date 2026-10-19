// A deck card's back drawn in perspective on a flat trapezoid: the UVs carry
// the perspective weight q (UV = uv * q, UV2.x = q), divided per pixel, so the
// picture is foreshortened correctly (the host's Figma 3D setting).
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque, shadows_disabled;

uniform sampler2D tex : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform float shade = 1.0;

void fragment() {
	vec2 uv = UV / UV2.x;
	vec4 c = texture(tex, uv);
	if (c.a < 0.5) {
		discard;
	}
	ALBEDO = c.rgb * shade;
}
