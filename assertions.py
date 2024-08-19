#%%

# read in file as array of integers
def read_input(file):
    with open(file) as f:
        return eval(f.readline())
# %%
sort_out = read_input("sort_out.txt")
# %%
def arr_is_sorted(depth, index):
    for i in range(1, len(index)):
        if depth[index[i-1]] > depth[index[i]]:
            print(f"Array is not sorted at index {i}")
            print(f"Index {depth[index[i-1]]} > {depth[index[i]]}")
            return False
    return True
# %%
debug_depths = read_input("debug_depths.txt")
# %%
assert arr_is_sorted(debug_depths, sort_out)
# %%
assert len(sort_out) == 12828
# %%
assert len(debug_depths) == 12828
# %%

def all_floats(arr):
    for i in arr:
        if type(i) != float:
            print(f"Element {i}: {arr[i]} is not a float")
            return False
    return True

assert all_floats(debug_depths)
# %%
