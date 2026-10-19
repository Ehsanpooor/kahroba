// Face of a gem token (a heavy poker-style chip): the painted face when it
// exists, else enamel in the gem's colour, an inlaid ring with edge spots and
// a cut gem in the middle. Lit, so it glints as it flips.
shader_type spatial;
render_mode cull_disabled;

uniform sampler2D tex : source_color, filter_linear_mipmap, repeat_disable;
uniform float has_tex = 0.0;
uniform vec3 col : source_color = vec3(0.8, 0.1, 0.1);
uniform vec3 inlay : source_color = vec3(0.95, 0.75, 0.36);
uniform vec3 glint : source_color = vec3(1.0);
uniform float dark = 0.0;

void fragment() {
	vec2 p = (UV - 0.5) * 2.0;
	float r = length(p);
	float ang = atan(p.y, p.x);
	vec3 c;
	if (has_tex > 0.5) {
		c = texture(tex, UV).rgb;
	} else {
		c = col * (0.8 + 0.25 * (1.0 - r));
		float spots = step(0.5, fract(ang / TAU * 8.0 + 0.25));
		float edge = smoothstep(0.78, 0.8, r);
		c = mix(c, mix(col * 0.75, vec3(0.96, 0.94, 0.88), spots * 0.9), edge);
		c = mix(c, inlay, 1.0 - smoothstep(0.012, 0.03, abs(r - 0.76)));
		c = mix(c, inlay * 0.9, 1.0 - smoothstep(0.01, 0.025, abs(r - 0.6)));
		float k = cos(PI / 8.0) / cos(mod(ang, PI / 4.0) - PI / 8.0);
		float gr = r / k;
		float gem = 1.0 - smoothstep(0.42, 0.45, gr);
		float facet = 0.5 + 0.5 * cos(ang * 8.0 + 0.4);
		vec3 g = col * (0.6 + 0.6 * facet);
		g = mix(g, col * 1.2 + 0.15, 1.0 - smoothstep(0.2, 0.23, gr));
		g += glint * 0.8 * pow(max(0.0, 1.0 - length(p - vec2(-0.12, -0.15)) * 6.0), 2.0);
		c = mix(c, g, gem);
		c = mix(c, inlay * 0.8, (1.0 - smoothstep(0.01, 0.03, abs(gr - 0.44))) * 0.8);
	}
	c = mix(c, c * 0.32, dark);  // empty pile: the same token, darker
	// mostly self-lit, so tokens keep their true colour anywhere on the table
	ALBEDO = c * 0.22;
	EMISSION = c * 1.0;
	ROUGHNESS = 0.3;
	METALLIC = 0.1;
	SPECULAR = 0.8;
}
