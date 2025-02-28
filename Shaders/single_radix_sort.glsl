// VkRadixSort written by Mirco Werner: https://github.com/MircoWerner/VkRadixSort
// Based on implementation of Intel's Embree: https://github.com/embree/embree/blob/v4.0.0-ploc/kernels/rthwif/builder/gpu/sort.h
#[compute]
#version 450
#extension GL_GOOGLE_include_directive: enable
#extension GL_KHR_shader_subgroup_basic: enable
#extension GL_KHR_shader_subgroup_arithmetic: enable

#define WORKGROUP_SIZE 256
#define RADIX_SORT_BINS 256
#define SUBGROUP_SIZE 32

layout (local_size_x = WORKGROUP_SIZE) in;

layout (set = 0, binding = 0) buffer elements_in {
    uint index_in[];
};

layout (set = 0, binding = 1) buffer elements_out {
    uint index_out[];
};

layout(set = 0, binding = 2) buffer DepthBuffer {
    float depths[];
};

layout (push_constant, std430) uniform PushConstants {
    uint num_elements;
};

shared uint[RADIX_SORT_BINS] histogram;
shared uint[RADIX_SORT_BINS] prefix_sums;
shared uint[WORKGROUP_SIZE] shared_data;
shared uint[WORKGROUP_SIZE] global_offsets;

struct BinFlags {
    uint flags[WORKGROUP_SIZE / 32];
};
shared BinFlags[RADIX_SORT_BINS] bin_flags;

#define ELEMENT_IN(index, iteration) (iteration % 2 == 0 ? index_in[index] : index_out[index])

uint my_uint_cast(float f) { 
    return floatBitsToUint(f);
}

void main() {
    uint lID = gl_LocalInvocationID.x;

    for (uint iteration = 0; iteration < 4; iteration++) {
        uint shift = 8 * iteration;

        // initialize histogram
        if (lID < RADIX_SORT_BINS) {
            histogram[lID] = 0U;
        }
        barrier();

        for (uint ID = lID; ID < num_elements; ID += WORKGROUP_SIZE) {
            uint element = ELEMENT_IN(ID, iteration);
            uint depth = my_uint_cast(depths[element]);
            // determine the bin
            uint bin = (depth >> shift) & (RADIX_SORT_BINS - 1);
            // increment the histogram
            atomicAdd(histogram[bin], 1U);
        }
        barrier();

        // prefix sum
        if (lID < RADIX_SORT_BINS) {
            shared_data[lID] = histogram[lID];
            prefix_sums[lID] = 0U;
        }
        barrier();

        for (uint stride = 1; stride < WORKGROUP_SIZE; stride *= 2) {
            uint value = 0;

            if (lID >= stride) {
                value = shared_data[lID - stride];
            }
            barrier();

            atomicAdd(prefix_sums[lID], value);
            atomicAdd(shared_data[lID], value);
            barrier();
        }


        // scatter
        const uint flags_bin = lID / 32;
        const uint flags_bit = 1 << (lID % 32);

        if(lID < RADIX_SORT_BINS) {
            global_offsets[lID] = 0U;
        }
        barrier();

        for (uint blockID = 0; blockID < num_elements; blockID += WORKGROUP_SIZE) {
            barrier();

            const uint ID = blockID + lID;

            // initialize bin flags
            if (lID < RADIX_SORT_BINS) {
                for (int i = 0; i < WORKGROUP_SIZE / 32; i++) {
                    bin_flags[lID].flags[i] = 0U;// init all bin flags to 0
                }
            }
            barrier();

            uint element = 0;
            uint binID = 0;
            uint binOffset = 0;
            if (ID < num_elements) {
                element = ELEMENT_IN(ID, iteration);
                uint depth = my_uint_cast(depths[element]);
                binID = uint(depth >> shift) & uint(RADIX_SORT_BINS - 1);
                // offset for group
                global_offsets[lID] = prefix_sums[binID];
                // add bit to flag
                atomicAdd(bin_flags[binID].flags[flags_bin], flags_bit);
            }
            barrier();

            if (ID < num_elements) {
                // calculate output index of element
                uint prefix = 0;
                uint count = 0;
                for (uint i = 0; i < WORKGROUP_SIZE / 32; i++) {
                    const uint bits = bin_flags[binID].flags[i];
                    const uint full_count = bitCount(bits);
                    const uint partial_count = bitCount(bits & (flags_bit - 1));
                    prefix += (i < flags_bin) ? full_count : 0U;
                    prefix += (i == flags_bin) ? partial_count : 0U;
                    count += full_count;
                }
                if (iteration % 2 == 0) {
                    index_out[global_offsets[lID] + prefix] = element;
                } else {
                    index_in[global_offsets[lID] + prefix] = element;
                }
                if (prefix == count - 1) {
                    atomicAdd(prefix_sums[binID], count);
                }
            }
        }
    }
}