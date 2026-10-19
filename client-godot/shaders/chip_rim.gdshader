// Edge of a gem token, as the host's tokens: the enamel colour, darker toward
// the bottom, with a thin gold line along the top and bottom of each token.
shader_type spatial;
render_mode cull_disabled;

uniform vec3 col : source_color = vec3(0.8, 0.1, 0.1);
uniform vec3 gold : source_color = vec3(0.95, 0.75, 0.36);
uniform float dark = 0.0;

void fragment() {
	vec3 c = col * mix(1.05, 0.6, UV.y);
	float line = 1.0 - smoothstep(0.08, 0.16, min(UV.y, 1.0 - UV.y));
	c = mix(c, gold, line * 0.85);
	c = mix(c, c * 0.32, dark);
	ALBEDO = c * 0.25;
	EMISSION = c * 0.9;
	ROUGHNESS = 0.35;
	SPECULAR = 0.6;
}
