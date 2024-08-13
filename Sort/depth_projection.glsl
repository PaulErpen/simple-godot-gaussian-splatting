#[compute]
#version 450

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

// Model-view matrix
layout(set = 0, binding = 0) buffer ModelView {
    mat4 model_view_matrix;
};

// Input vertex positions
layout(set = 0, binding = 1) buffer Vertices {
    float vertices[];
};

// Output depth buffer
layout(set = 0, binding = 2) buffer DepthBuffer {
    float depths[];
};

layout(set = 0, binding = 4) buffer ProjectionMatrix {
    mat4 projection_matrix;
};

float sigmoid(float x) {
    return 1.0 / (1.0 + exp(-x));
}

void main() {
    uint idx = gl_GlobalInvocationID.x;
    
    if(idx >= depths.length()) {
        return;
    }

    vec4 vertex = vec4(vertices[idx * 3], vertices[idx * 3 + 1], vertices[idx * 3 + 2], 1.0);
    
    // Apply model-view-projection matrix
    //vec4 projected_vertex = projection_matrix * model_view_matrix * vertex;
    vec4 projected_vertex = projection_matrix * (model_view_matrix * vertex);
    
    // Write depth value to the buffer
    depths[idx] = length(projected_vertex.xyz);
    //depths[gl_GlobalInvocationID.x] = vertex.y;
}
