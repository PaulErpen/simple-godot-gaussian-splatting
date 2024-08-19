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
    uint depths[];
};

layout(set = 0, binding = 3) buffer ProjectionMatrix {
    mat4 projection_matrix;
};

layout (push_constant, std430) uniform PushConstants {
    uint num_elements;
};

void main() {
    uint idx = gl_GlobalInvocationID.x;
    
    if(idx < num_elements) {
        vec4 vertex = vec4(vertices[idx * 3], vertices[idx * 3 + 1], vertices[idx * 3 + 2], 1.0);
    
        // Apply model-view-projection matrix
        vec4 projected_vertex = projection_matrix * (model_view_matrix * vertex);
        
        // Write depth value to the buffer
        depths[idx] = (num_elements - idx) % 1000;
    }
}
