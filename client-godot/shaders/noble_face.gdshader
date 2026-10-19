// A noble, as the host's design: the portrait inside a thin gold frame with
// large rounded corners, the frame casting a soft shadow onto the portrait
// (Figma drop shadow: blur 3, black 80 %).
shader_type spatial;
render_mode cull_disabled, unshaded;

#include "res://shaders/common.gdshaderinc"

uniform sampler2D tex : source_color, filter_linear_mipmap, repeat_disable;
uniform float has_tex = 0.0;
uniform vec3 tint : source_color = vec3(0.45, 0.12, 0.14);
uniform vec2 size_px = vec2(184.0, 184.0);
uniform float radius_px = 30.0;
uniform float band_px = 4.5;  // the gold line
uniform float shadow_px = 7.0;  // its shadow's blur
uniform float highlight = 0.0;
uniform float flash = 0.0;

float sd_round(vec2 p, vec2 b, float r) {
	vec2 q = abs(p) - b + r;
	return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

void fragment() {
	vec2 p = (UV - 0.5) * size_px;
	float d = sd_round(p, size_px * 0.5, radius_px);  // < 0 inside
	if (d > 0.5) {
		discard;
	}
	vec3 c;
	if (has_tex > 0.5) {
		c = texture(tex, UV).rgb;
	} else {
		c = tint * (0.5 + 0.6 * fbm(UV * 8.0 + 2.0));
	}
	float inner = -d - band_px;  // distance inside the gold line
	// the frame's shadow on the portrait
	c *= 1.0 - 0.8 * exp(-max(inner, 0.0) / (shadow_px * 0.5)) * step(0.0, inner);
	// the gold line: bright in the middle, darker at its edges
	float band = 1.0 - smoothstep(-0.6, 0.6, inner);
	float t = clamp(-d / band_px, 0.0, 1.0);
	vec3 gold = mix(vec3(0.62, 0.43, 0.15), vec3(0.98, 0.8, 0.42), sin(t * 3.14159));
	c = mix(c, gold, band);
	ALBEDO = c * (1.0 + highlight * 0.15) + vec3(1.0, 0.85, 0.5) * flash;
	ALPHA = 1.0 - smoothstep(-0.5, 0.5, d);
}
