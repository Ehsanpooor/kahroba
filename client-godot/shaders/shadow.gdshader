// Soft drop shadow made from any texture's alpha (blurred via mip level).
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix, shadows_disabled;

uniform sampler2D tex : filter_linear_mipmap, repeat_disable;
uniform float strength = 0.55;
uniform float blur = 2.5;

void fragment() {
	float a = textureLod(tex, UV, blur).a;
	ALBEDO = vec3(0.0, 0.0, 0.015);
	ALPHA = a * strength;
}
