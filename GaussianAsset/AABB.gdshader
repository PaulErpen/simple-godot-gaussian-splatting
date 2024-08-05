shader_type spatial;
render_mode cull_disabled;

uniform vec3 wireframeColor;

varying vec3 fragPos;
varying vec3 baryCentric;

void vertex() {
	vec4 clipspace = PROJECTION_MATRIX * MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	fragPos = vec3((MODEL_MATRIX * vec4(VERTEX, 1.0)).rgb);
	
	// Calculate barycentric coordinates based on vertex ID
    if (VERTEX_ID % 3 == 0) {
        baryCentric = vec3(1.0, 0.0, 0.0);
    } else if (VERTEX_ID % 3 == 1) {
        baryCentric = vec3(0.0, 1.0, 0.0);
    } else {
        baryCentric = vec3(0.0, 0.0, 1.0);
    }
	POSITION = vec4(clipspace.xyz / clipspace.w, 1.0);
}

void fragment() {
	// Calculate the minimum distance to the edge
    float minEdgeDistance = min(min(baryCentric.x, baryCentric.y), baryCentric.z);
    
    // Smooth the edges
    float edgeFactor = step(fwidth(minEdgeDistance) * 0.5, minEdgeDistance);
    
 	ALBEDO = wireframeColor * (1.0 - edgeFactor);
	ALPHA = 1.0 - edgeFactor;
}

//void light() {
	// Called for every pixel for every light affecting the material.
	// Uncomment to replace the default light processing function with this one.
//}
