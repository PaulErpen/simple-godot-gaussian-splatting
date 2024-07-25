shader_type spatial;

// splat data
uniform sampler2D data;
uniform int n_splats;
uniform int n_properties;

// parameters
uniform float modifier;
uniform float tan_fovx;
uniform float tan_fovy;
uniform float focal_x;
uniform float focal_y;
uniform vec2 viewport_size;

//varyings
varying vec3 color;
varying float opacity;
varying vec3 vConic;
varying vec2 vUv;

mat3 computeCov3D(vec3 scale, vec4 rot) {
	mat3 S = mat3(
		vec3(modifier * exp(scale.x), 0.0, 0.0),
		vec3(0.0, modifier * exp(scale.y), 0.0),
		vec3(0.0, 0.0, modifier * exp(scale.z))
	);

    rot = normalize(rot);
	float r = rot.x;
	float x = rot.y;
	float y = rot.z;
	float z = rot.w;

	mat3 R = mat3(
		vec3(1.0 - 2.0 * (y * y + z * z), 2.0 * (x * y - r * z), 2.0 * (x * z + r * y)),
		vec3(2.0 * (x * y + r * z), 1.0 - 2.0 * (x * x + z * z), 2.0 * (y * z - r * x)),
		vec3(2.0 * (x * z - r * y), 2.0 * (y * z + r * x), 1.0 - 2.0 * (x * x + y * y))
	);

	mat3 M = S * R;

	mat3 Sigma = transpose(M) * M;
	
	return Sigma;
}

vec3 computeCov2D(vec3 position, vec3 log_scale, vec4 rot, mat4 viewMatrix) {
    mat3 cov3D = computeCov3D(log_scale, rot);

    vec4 t = viewMatrix * vec4(position, 1.0);

    float limx = 1.3 * tan_fovx;
    float limy = 1.3 * tan_fovy;
    float txtz = t.x / t.z;
    float tytz = t.y / t.z;
    t.x = min(limx, max(-limx, txtz)) * t.z;
    t.y = min(limy, max(-limy, tytz)) * t.z;

    mat4 J = mat4(
        vec4(focal_x / t.z, 0.0, -(focal_x * t.x) / (t.z * t.z), 0.0),
        vec4(0.0, focal_y / t.z, -(focal_y * t.y) / (t.z * t.z), 0.0),
        vec4(0.0, 0.0, 0.0, 0.0),
		vec4(0.0, 0.0, 0.0, 0.0)
    );

    mat4 W = transpose(viewMatrix);

    mat4 T = W * J;

    mat4 Vrk = mat4(
        vec4(cov3D[0][0], cov3D[0][1], cov3D[0][2], 0.0),
        vec4(cov3D[0][1], cov3D[1][1], cov3D[1][2], 0.0),
        vec4(cov3D[0][2], cov3D[1][2], cov3D[2][2], 0.0),
        vec4(0.0, 0.0, 0.0, 0.0)
    );
	
    mat4 cov = transpose(T) * transpose(Vrk) * T;

    cov[0][0] += 0.3;
    cov[1][1] += 0.3;
    return vec3(cov[0][0], cov[0][1], cov[1][1]);
}

float ndc2Pix(float v, float S) {
    return ((v + 1.) * S - 1.) * .5;
}


float sigmoid(float x) {
    if (x >= 0.0) {
        return 1.0 / (1.0 + exp(-x));
    } else {
        float z = exp(x);
        return z / (1.0 + z);
    }
}

void vertex() {
	// retrieve data from texture
	vec3 mu = texture(data, vec2(float(INSTANCE_ID) / float(n_splats), 0.0)).xyz;
	vec3 scale = texture(data, vec2(float(INSTANCE_ID) / float(n_splats), 1.0 / float(n_properties))).xyz;
	vec4 rot = texture(data, vec2(float(INSTANCE_ID) / float(n_splats), 2.0  / float(n_properties)));
	
	//calculate clip space position and culling
	vec4 clipSpace = PROJECTION_MATRIX * VIEW_MATRIX * vec4(mu, 1.0);
    float clip = 1.2 * clipSpace.w;
    if (clipSpace.z < -clip || clipSpace.z > clip || clipSpace.x < -clip || clipSpace.x > clip || clipSpace.y < -clip || clipSpace.y > clip) {
        POSITION = vec4(0, 0, 2, 1);
    } else 
	{
		//noramlized device coordinates
		vec4 ndc = clipSpace / clipSpace.w;
		
		//conic of covariance calculation
		vec3 cov2d = computeCov2D(mu, scale, rot, VIEW_MATRIX);
		float det = cov2d.x * cov2d.z - cov2d.y * cov2d.y;
	    if (det == 0.) {
	        POSITION = vec4(0, 0, 2, 1);
	    } else {
			float det_inv = 1.0 / det;
			vec3 conic = vec3(cov2d.z * det_inv, -cov2d.y * det_inv, cov2d.x * det_inv);
			float mid = 0.5 * (cov2d.x + cov2d.z);
			
			// compute eigenvalues
			float lambda_1 = mid + sqrt(max(0.1, mid * mid - det));
    		float lambda_2 = mid - sqrt(max(0.1, mid * mid - det));
			float radius_px = ceil(3. * sqrt(max(lambda_1, lambda_2)));
			// compute pixel in image space
    		vec2 point_image = vec2(ndc2Pix(ndc.x, viewport_size.x), ndc2Pix(ndc.y, viewport_size.y));
			
			color = COLOR.rgb;
			opacity = sigmoid(COLOR.a);
			vConic = conic;
			
			vec2 corner = vec2(float((VERTEX_ID << 1) & 2), float(VERTEX_ID & 2)) - 1.;
			vec2 screen_pos = point_image + radius_px * corner;
			vUv = point_image - screen_pos;
			POSITION = vec4(screen_pos / viewport_size * 2.0 - 1.0, ndc.z, 1);
			//POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(VERTEX, 1.0);
		}
	}
}

void fragment() {
	//vec2 d = vUv;
	//vec3 conic = vConic;
	//float power = -0.5 * (conic.x * d.x * d.x + conic.z * d.y * d.y) + conic.y * d.x * d.y;
	//
	//if (power > 0.0) {
	//	discard;
	//}
//
	//float alpha = min(0.99, opacity * exp(power));
//
	//if (alpha < 1.0/255.0) {
	//	discard;
	//}
	ALBEDO = color.rgb;
	//ALPHA = alpha;
}

//void light() {
	// Called for every pixel for every light affecting the material.
	// Uncomment to replace the default light processing function with this one.
//}
