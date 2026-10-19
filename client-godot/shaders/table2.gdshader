// The table: the painted board when it exists, else dark green velvet with a
// gold-tooled border and a warm pool of light in the middle. The picture is
// stretched to the SCREEN (whatever its shape), not to the tilted table.
// Lit, so cards and chips cast real shadows on it.
shader_type spatial;

#include "res://shaders/common.gdshaderinc"

uniform sampler2D tex : source_color, filter_linear_mipmap, repeat_disable;
uniform float has_tex = 0.0;
uniform vec2 vp_size = vec2(1920.0, 1080.0);
uniform vec2 tex_size = vec2(2400.0, 1080.0);
uniform float dim = 0.72;  // the painted table a little darker (1 = as painted)

void fragment() {
	// the picture fills the whole screen, stretched to its shape, so its
	// gold frame always runs along the four screen edges on any phone
	vec2 uv = SCREEN_UV;
	vec3 c;
	if (has_tex > 0.5) {
		c = texture(tex, uv).rgb * dim;
	} else {
		vec2 q = uv * vec2(2.2, 1.0);
		float n = fbm(q * 9.0);
		float fib = fbm(q * vec2(60.0, 4.0));
		c = vec3(0.045, 0.1, 0.075) * (0.75 + 0.45 * n + 0.12 * fib);
		float pool = 1.0 - smoothstep(0.1, 0.75, length((uv - vec2(0.52, 0.42)) * vec2(1.3, 1.0)));
		c *= 0.6 + 0.75 * pool;
		vec2 e = min(uv, 1.0 - uv) * vec2(2.2, 1.0);
		float d = min(e.x, e.y);
		vec3 gold = vec3(0.6, 0.45, 0.2);
		c = mix(c, gold * 0.55, (1.0 - smoothstep(0.0015, 0.004, abs(d - 0.012))) * 0.7);
		c = mix(c, gold * 0.4, (1.0 - smoothstep(0.001, 0.003, abs(d - 0.02))) * 0.5);
		c *= 1.0 - 0.5 * smoothstep(0.02, 0.0, d);
	}
	ALBEDO = c * 0.8;
	EMISSION = c * 0.28;
	ROUGHNESS = 0.9;
	SPECULAR = 0.12;
}
