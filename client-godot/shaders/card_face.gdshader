// Face of a development card (landscape). With its gem's frame (art), the
// painting shows only through the frame's window and the frame carries the
// gem, the points medallion and the cost band. Without the frame, a drawn
// frame and a gem-coloured stand-in keep the card readable.
shader_type spatial;
render_mode cull_disabled, depth_draw_opaque;

#include "res://shaders/common.gdshaderinc"

uniform sampler2D art : source_color, filter_linear_mipmap, repeat_disable;
uniform float has_art = 0.0;
uniform sampler2D frame : source_color, filter_linear_mipmap, repeat_disable;
uniform float has_frame = 0.0;
uniform vec4 win = vec4(0.06, 0.14, 0.88, 0.56); // the frame's window: x, y, w, h (UV)
uniform vec3 gem_col : source_color = vec3(0.8, 0.1, 0.1);
uniform vec3 tier_col : source_color = vec3(0.16, 0.4, 0.2);
uniform vec2 size_px = vec2(280.0, 200.0);
uniform float border_px = 8.4;
uniform float seed = 0.0;
uniform float highlight = 0.0;   // pointer over the card
uniform float glow = 0.0;        // affordable now
uniform vec3 glow_col : source_color = vec3(0.45, 1.0, 0.55);
uniform float flash = 0.0;
uniform float dim = 0.0;
uniform float dissolve = 0.0;

vec3 painted(vec2 uv) {
	float n = fbm(uv * vec2(5.0, 3.5) + seed * 7.3);
	float n2 = fbm(uv * vec2(14.0, 9.0) - seed * 3.1);
	vec3 sky = mix(gem_col * 0.95 + 0.12, vec3(0.95, 0.88, 0.7), 0.25);
	vec3 ground = gem_col * 0.32 + vec3(0.05, 0.04, 0.03);
	float horizon = 0.55 + 0.12 * (n - 0.5);
	vec3 c = mix(sky, ground, smoothstep(horizon - 0.05, horizon + 0.12, uv.y));
	return c * (0.75 + 0.45 * n2);
}


// the painting, cover-fitted into a rect r (x, y, w, h in UV)
vec3 window_art_in(vec2 uv, vec4 r) {
	vec2 w = clamp((uv - r.xy) / r.zw, 0.0, 1.0);
	float win_aspect = r.z * size_px.x / (r.w * size_px.y);
	float art_aspect = 1.5;
	vec2 a = w;
	if (win_aspect > art_aspect) {
		a.y = 0.45 + (w.y - 0.5) * art_aspect / win_aspect;
	} else {
		a.x = 0.5 + (w.x - 0.5) * win_aspect / art_aspect;
	}
	return has_art > 0.5 ? texture(art, a).rgb : painted(a);
}

// the painting, cover-fitted into the frame's window
vec3 window_art(vec2 uv) {
	vec2 w = clamp((uv - win.xy) / win.zw, 0.0, 1.0);
	float win_aspect = win.z * size_px.x / (win.w * size_px.y);
	float art_aspect = 1.5;
	vec2 a = w;
	if (win_aspect > art_aspect) {
		a.y = 0.45 + (w.y - 0.5) * art_aspect / win_aspect;
	} else {
		a.x = 0.5 + (w.x - 0.5) * win_aspect / art_aspect;
	}
	return has_art > 0.5 ? texture(art, a).rgb : painted(a);
}

void fragment() {
	vec2 uv = UV;
	vec2 px = uv * size_px;
	float d = min(min(px.x, size_px.x - px.x), min(px.y, size_px.y - px.y));
	vec3 c;
	if (has_frame > 0.5) {
		vec4 f = texture(frame, uv);
		c = mix(window_art(uv), f.rgb, f.a);
	} else {
		// the host's card: the painting inside a white (pearl) border with a
		// fine gold line outside and a thin dark line where the painting starts
		vec2 lo = vec2(border_px) / size_px;
		vec3 painting = window_art_in(uv, vec4(lo, 1.0 - 2.0 * lo));
		vec3 pearl = mix(vec3(0.98, 0.96, 0.92), vec3(0.86, 0.82, 0.74), smoothstep(0.0, border_px, d) * 0.6);
		c = mix(pearl, painting, smoothstep(border_px - 0.6, border_px + 0.6, d));
		c = mix(c, vec3(0.42, 0.32, 0.2), (1.0 - smoothstep(0.0, 1.1, abs(d - border_px))) * 0.55);
		c = mix(c, vec3(0.78, 0.6, 0.3), 1.0 - smoothstep(0.8, 2.0, d));
	}
	c = mix(c, vec3(dot(c, vec3(0.3, 0.59, 0.11))) * 0.45, dim);
	vec3 wp = world_pos(INV_VIEW_MATRIX, VERTEX);
	float hl = highlight * (0.12 + 0.25 * pointer_glow(wp));
	vec3 rim_glow = glow_col * glow * (1.0 - smoothstep(0.0, 14.0, d));
	ALBEDO = c * 0.45;
	EMISSION = c * (0.62 + hl) + rim_glow * 1.4 + vec3(1.0, 0.85, 0.55) * flash;
	ROUGHNESS = 0.45;
	SPECULAR = 0.35;
	if (dissolve > 0.0) {
		float n = fbm(UV * 5.0 + 3.1);
		float th = mix(-0.05, 1.0, dissolve);
		EMISSION += vec3(1.0, 0.62, 0.22) * 2.0 * (1.0 - smoothstep(th, th + 0.1, n));
		if (n < th - 0.01) {
			discard;
		}
	}
}
