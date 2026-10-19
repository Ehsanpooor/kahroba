// Screen overlay: soft vignette + a whisper of film grain.
shader_type canvas_item;

uniform float vignette = 0.62;
uniform float grain = 0.035;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

void fragment() {
	vec2 q = (UV - vec2(0.5, 0.47)) * vec2(1.25, 0.82);
	float v = smoothstep(0.32, 0.92, length(q)) * vignette;
	float g = hash(floor(FRAGCOORD.xy) + fract(TIME * 7.0) * 113.0);
	vec3 c = mix(vec3(0.0, 0.0, 0.02), vec3(g), grain / max(v + grain, 0.001));
	COLOR = vec4(c, v + grain * abs(g - 0.5));
}
