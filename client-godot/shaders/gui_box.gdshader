// Every panel and button of the table HUD: a rounded box with a vertical
// gradient, a soft sheen, a bevelled gold edge and an optional outer glow.
// The control is `pad` px larger than the box on each side, for the glow.
shader_type canvas_item;

uniform vec2 size = vec2(200.0, 60.0);
uniform float pad = 10.0;
uniform float radius = 14.0;
uniform vec4 top_col : source_color = vec4(0.13, 0.12, 0.11, 0.94);
uniform vec4 bottom_col : source_color = vec4(0.05, 0.05, 0.06, 0.94);
uniform vec4 edge_col : source_color = vec4(0.92, 0.72, 0.36, 1.0);
uniform float edge = 2.0;
uniform float glow = 0.0;
uniform vec4 glow_col : source_color = vec4(1.0, 0.8, 0.4, 1.0);
uniform float sheen = 0.1;
uniform float pressed = 0.0;

float sd_box(vec2 p, vec2 b, float r) {
	vec2 q = abs(p) - b + r;
	return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

void fragment() {
	vec2 p = (UV - 0.5) * size;
	vec2 half_box = size * 0.5 - pad;
	float d = sd_box(p, half_box, radius);
	float v = clamp((p.y + half_box.y) / (2.0 * half_box.y), 0.0, 1.0);
	vec4 fill = mix(top_col, bottom_col, v);
	fill.rgb *= 1.0 - pressed * 0.25;
	fill.rgb += vec3(1.0) * sheen * (1.0 - smoothstep(0.0, 0.45, v)) * (1.0 - pressed);
	float inside = 1.0 - smoothstep(-0.6, 0.6, d);
	float band = (1.0 - smoothstep(edge - 0.6, edge + 0.6, -d)) * inside;
	vec3 ec = edge_col.rgb * mix(1.25, 0.7, v);
	vec4 c = vec4(mix(fill.rgb, ec, band * edge_col.a), fill.a * inside);
	c.a = max(c.a, band * edge_col.a);
	float outer = (1.0 - inside) * exp(-max(d, 0.0) / (pad * 0.45)) * glow;
	c = mix(vec4(glow_col.rgb, outer * glow_col.a), c, c.a);
	c.a = max(c.a, outer * glow_col.a);
	COLOR = c;
}
