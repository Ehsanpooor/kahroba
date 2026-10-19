// Lit coin face: the painted element coin, with real specular so it glints
// as it flips through the air under the table lights.
shader_type spatial;
render_mode cull_disabled;

uniform sampler2D tex : source_color, filter_linear_mipmap, repeat_disable;
uniform vec3 glow_color : source_color = vec3(1.0, 0.8, 0.4);
uniform float glow = 0.0;
uniform float dark = 0.0; // empty bank pile

void fragment() {
	vec4 c = texture(tex, UV);
	c.rgb = mix(c.rgb, vec3(dot(c.rgb, vec3(0.3, 0.59, 0.11))) * 0.22, dark);
	ALBEDO = c.rgb * 0.8;
	ROUGHNESS = 0.3;
	METALLIC = 0.3;
	SPECULAR = 0.75;
	EMISSION = c.rgb * 0.85 + glow_color * glow;
}
