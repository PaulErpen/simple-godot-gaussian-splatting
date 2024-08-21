shader_type spatial;
render_mode unshaded;

uniform sampler2D rendered_image_texture;

void vertex() {
	// Called for every vertex the material is visible on.
}

void fragment() {
	vec4 tex_val = texture(rendered_image_texture, vec2(1.0, 1.0) - SCREEN_UV);
	ALBEDO = tex_val.rgb;
	//ALPHA = tex_val.a;
}

//void light() {
	// Called for every pixel for every light affecting the material.
	// Uncomment to replace the default light processing function with this one.
//}
