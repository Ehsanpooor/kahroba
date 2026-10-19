shader_type canvas_item;
// The brightness setting: the finished picture, scaled.
uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform float brightness = 1.0;

void fragment() {
	vec3 c = texture(screen_tex, SCREEN_UV).rgb;
	COLOR = vec4(c * brightness, 1.0);
}
