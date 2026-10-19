// 2D HUD avatar: crop the face out of a portrait cutout into a circle.
shader_type canvas_item;

uniform vec4 uv_rect = vec4(0.22, 0.04, 0.56, 0.56);
uniform vec3 back : source_color = vec3(0.09, 0.1, 0.13);

void fragment() {
	vec2 uv = uv_rect.xy + UV * uv_rect.zw;
	vec4 c = texture(TEXTURE, uv);
	float r = length(UV - 0.5);
	vec3 bg = back * (1.25 - r);
	COLOR = vec4(mix(bg, c.rgb, c.a), 1.0 - smoothstep(0.47, 0.5, r));
}
