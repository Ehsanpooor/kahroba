// A gem token, as the host's Frame 45 tokens: a heavy chip with rounded
// edges. Its faces carry the painted token art (projected straight down, so
// the art also wraps over the rounded edge), its side the enamel colour of
// the art's rim. The light is drawn here (a warm key from the upper left plus
// a soft fill), so the rounded edges catch a bright line on top and fall
// dark underneath: stacked chips show the grooves between them.
shader_type spatial;
render_mode unshaded, cull_disabled;

uniform sampler2D tex : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform float has_tex = 0.0;
uniform vec3 col : source_color = vec3(0.8, 0.1, 0.1);
uniform vec3 side : source_color = vec3(0.8, 0.1, 0.1);
uniform vec3 inlay : source_color = vec3(0.95, 0.75, 0.36);
uniform vec3 glint : source_color = vec3(1.0);
uniform float dark = 0.0;

varying vec3 lpos;
varying vec3 lnrm;

void vertex() {
	lpos = VERTEX;
	lnrm = NORMAL;
}

// The face without its picture: enamel, an inlaid ring and a cut gem.
vec3 plain_face(vec2 p) {
	float r = length(p);
	float ang = atan(p.y, p.x);
	vec3 c = col * (0.85 + 0.2 * (1.0 - r));
	float fw = fwidth(r) * 1.5;
	c = mix(c, inlay, 1.0 - smoothstep(0.02, 0.02 + fw, abs(r - 0.78)));
	float k = cos(PI / 8.0) / cos(mod(ang, PI / 4.0) - PI / 8.0);
	float gr = r / k;
	float facet = 0.5 + 0.5 * cos(ang * 8.0 + 0.4);
	vec3 g = mix(col * (0.6 + 0.6 * facet), col * 1.2 + 0.15, 1.0 - smoothstep(0.2, 0.2 + fw, gr));
	return mix(c, g, 1.0 - smoothstep(0.45, 0.45 + fw, gr));
}

void fragment() {
	vec3 ln = normalize(lnrm);
	vec2 p = lpos.xz;
	if (ln.y < 0.0) {
		p.x = -p.x;  // the back reads the right way round once the chip flips
	}
	vec3 face = has_tex > 0.5 ? texture(tex, 0.5 + p * 0.497).rgb : plain_face(p);
	// face on the flat and over most of the rounded edge, enamel down the side
	float on_face = smoothstep(0.3, 0.8, abs(ln.y));
	vec3 base = mix(side, face, on_face);

	vec3 n = normalize(NORMAL);
	vec3 key = normalize((VIEW_MATRIX * vec4(-0.5, 1.0, 0.45, 0.0)).xyz);
	vec3 fill = normalize((VIEW_MATRIX * vec4(0.7, 0.3, 0.6, 0.0)).xyz);
	float d = dot(n, key) * 0.5 + 0.5;  // wrapped, so the dark side keeps some colour
	float f = max(dot(n, fill), 0.0);
	// the painted face already carries its own light: shade it gently
	float shade = mix(0.42 + 0.78 * d * d + 0.2 * f, 1.06 + 0.3 * d, on_face);
	vec3 h = normalize(key + vec3(0.0, 0.0, 1.0));
	float spec = pow(max(dot(n, h), 0.0), 36.0) * mix(0.55, 0.18, on_face);
	vec3 c = base * shade + spec * mix(vec3(1.0), glint, 0.35);
	c = mix(c, c * 0.32, dark);  // empty pile: the same token, darker
	ALBEDO = c;
}
