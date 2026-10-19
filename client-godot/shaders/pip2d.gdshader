// Glossy cost pip for 2D views (dialogs), matching shaders/pip.gdshader.
shader_type canvas_item;

uniform vec4 col : source_color = vec4(0.8, 0.1, 0.1, 1.0);

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);
	float a = 1.0 - smoothstep(0.93, 1.0, r);
	vec3 c = col.rgb * (0.7 + 0.5 * (1.0 - r));
	c += vec3(1.0) * 0.45 * (1.0 - smoothstep(0.0, 0.42, length(p - vec2(-0.32, -0.38))));
	c = mix(c, col.rgb * 0.3, smoothstep(0.78, 0.97, r));
	c = mix(c, vec3(0.05), smoothstep(0.9, 0.98, r));
	COLOR = vec4(c, a);
}
