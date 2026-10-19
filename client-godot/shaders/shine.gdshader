shader_type canvas_item;
// A band of light sweeping across gold letters (the logo).
uniform float progress = -0.3;  // band centre along the diagonal, 0..1 crosses the image
uniform float width = 0.12;
uniform float strength = 0.9;

void fragment() {
	vec4 c = texture(TEXTURE, UV);
	float d = abs((UV.x * 0.8 + UV.y * 0.2) - progress);
	float band = smoothstep(width, 0.0, d);
	c.rgb += vec3(1.0, 0.95, 0.8) * band * strength * c.a;
	COLOR = c * COLOR;
}
