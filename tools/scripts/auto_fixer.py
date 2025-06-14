#!/usr/bin/env python3

import subprocess
import argparse
import os
import re
import sys
import shutil

# --- Configuration ---

try:
    PROJECT_DIR = os.environ['UPSIDE_HOME']
except KeyError:
    print("Error: The UPSIDE_HOME environment variable is not set.")
    print("Please set it to the root directory of your project, e.g., `export UPSIDE_HOME=$(pwd)`")
    sys.exit(1)

SRC_DIR = os.path.join(PROJECT_DIR, 'src')
BUILD_DIR = os.path.join(PROJECT_DIR, 'obj')

try:
    print(f"Searching for source files in: {SRC_DIR}")
    initial_src_files = [
        os.path.join('src', f) 
        for f in os.listdir(SRC_DIR) 
        if os.path.isfile(os.path.join(SRC_DIR, f))
    ]
    print(f"Found {len(initial_src_files)} files in 'src'.")
except FileNotFoundError:
    print(f"Error: 'src' directory not found at {SRC_DIR}")
    print(f"Please make sure UPSIDE_HOME is set correctly to '{PROJECT_DIR}'.")
    sys.exit(1)

INITIAL_FILES = initial_src_files + ['CMakeLists.txt']
if not initial_src_files:
    print("Warning: No files found in the 'src' directory.")

INITIAL_PROMPT = """
Hello. We are refactoring this C++ project to use a new `device_buffer` class for GPU data management.
I have already:
1. Created the `device_buffer` class using the pImpl idiom to hide CUDA details (`device_buffer.h`, `device_buffer.cpp`).
2. Replaced the Eigen-based `VecArrayStorage` with `device_buffer<float>` inside the `CoordNode` struct in `deriv_engine.h`.
3. Added `device_buffer.cpp` to the `CMakeLists.txt`.

This has broken the build, as the new class has a different API. I have added all files from the `/src` directory to your context. Your task is to fix the compilation errors across the entire project.

Please adhere to these rules:
1.  **Change as few lines as possible.** This is a surgical refactoring task.
2.  The `device_buffer` API provides `get_host_ptr()`, `get_mutable_host_ptr()`.
3.  The old code used the `()` operator for 2D array access, like `node->output(row, col)`. This must be replaced. The new pattern is to get a pointer and calculate the 1D index manually. The `CoordNode` stores the dimensions `n_elem` and `elem_width`. The data is column-major, so the index is `col * elem_width + row`.
4.  The old code used `std::swap` on the `VecArrayStorage` objects. I have added a `swap` method and free function for `device_buffer`, so calls like `swap(a.output, b.output)` should now work.

Please begin fixing the compilation errors based on the provided error output.
"""

def parse_arguments():
    """Parses command-line arguments for the script."""
    parser = argparse.ArgumentParser(
        description="Automatically fix C++ compilation errors using aider."
    )
    parser.add_argument(
        "--model",
        type=str,
        default="gemini-2.5-flash-latest",
        help="The AI model to use with aider."
    )
    parser.add_argument(
        "--max-compiles",
        type=int,
        default=15,
        help="The maximum number of times to try compiling and fixing."
    )
    parser.add_argument(
        "--max-tries-per-error",
        type=int,
        default=3,
        help="The maximum number of times to try fixing the same compilation error."
    )
    return parser.parse_args()

# --- MODIFICATION START: Cost parsing added to run_command ---
def run_command(command, cwd=PROJECT_DIR, text=True, state=None):
    """
    Runs a command, streams its output, parses `aider` cost, and returns a result object.
    """
    effective_cwd = cwd if os.path.isabs(cwd) else os.path.join(PROJECT_DIR, cwd)
    if command[0] == 'aider':
        effective_cwd = PROJECT_DIR

    print(f"\n> Running: {' '.join(command)} in {effective_cwd}")
    
    process = subprocess.Popen(
        command,
        cwd=effective_cwd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=text,
        bufsize=1,
        universal_newlines=True
    )

    output_lines = []
    if process.stdout:
        for line in iter(process.stdout.readline, ''):
            print(line, end='', flush=True)
            output_lines.append(line)
            # --- Cost parsing logic ---
            if state is not None and command[0] == 'aider':
                match = re.search(r'Cost: \$([\d\.]+)', line)
                if match:
                    try:
                        cost = float(match.group(1))
                        state['total_cost'] += cost
                        print(f"[COST_TRACKER: Added ${cost:.4f}, Cumulative Cost: ${state['total_cost']:.4f}]", flush=True)
                    except (ValueError, IndexError):
                        pass # Ignore if parsing the cost fails for any reason
        process.stdout.close()

    return_code = process.wait()

    return subprocess.CompletedProcess(
        args=command,
        returncode=return_code,
        stdout="".join(output_lines),
        stderr=""
    )
# --- MODIFICATION END ---


def compile_project():
    """Runs the custom build process based on the user's install.sh script."""
    os.makedirs(BUILD_DIR, exist_ok=True)
    
    print(f"> Clearing contents of build directory: {BUILD_DIR}")
    for item in os.listdir(BUILD_DIR):
        item_path = os.path.join(BUILD_DIR, item)
        try:
            if os.path.isfile(item_path) or os.path.islink(item_path):
                os.unlink(item_path)
            elif os.path.isdir(item_path):
                shutil.rmtree(item_path)
        except Exception as e:
            print(f'Failed to delete {item_path}. Reason: {e}')

    eigen_home = os.environ.get('EIGEN_HOME')
    if not eigen_home:
        print("\n---\nWARNING: EIGEN_HOME environment variable is not set.\n---\n")
    
    cmake_cmd = ['cmake', os.path.join(PROJECT_DIR, 'src')]
    if eigen_home:
        cmake_cmd.append(f'-DEIGEN3_INCLUDE_DIR={eigen_home}')

    cmake_result = run_command(cmake_cmd, cwd=BUILD_DIR)
    if cmake_result.returncode != 0:
        print("> CMake configuration failed.")
        return cmake_result

    make_result = run_command(['make'], cwd=BUILD_DIR)
    return make_result

def extract_error(compile_output):
    """Extracts a concise, relevant error block from the compiler output."""
    match = re.search(r'((?:.*:\d+:\d+:\s+error:.*)|(?:make\[\d+\]:\s\*\*\*.*Error\s\d+))', compile_output, re.DOTALL)
    if match:
        error_lines = match.group(1).splitlines()
        context_end_index = min(len(error_lines), 20)
        return "\n".join(error_lines[:context_end_index])
    return "Could not extract a specific error. Full output:\n" + compile_output[:2000]

def get_last_aider_diff():
    """Gets the diff from the last commit made by aider."""
    result = run_command(['git', 'show', '--pretty=medium', 'HEAD'])
    if result.returncode == 0:
        return result.stdout
    return "Could not retrieve diff."

def main():
    """The main compile-fix loop."""
    args = parse_arguments()
    # --- MODIFICATION: Added script_state to track cost ---
    script_state = {'total_cost': 0.0}
    compile_count, error_try_count, last_error_message = 0, 0, ""

    if run_command(['which', 'aider']).returncode != 0:
        print("Error: `aider` not found. Please `pip install aider-chat`.")
        sys.exit(1)
        
    print("--- Starting Auto-Fixer Loop ---")
    print(f"Project directory set to: {PROJECT_DIR}")
    print(f"Aider will be initialized with {len(INITIAL_FILES)} files.")
    print(f"Using model: {args.model}")

    while compile_count < args.max_compiles:
        compile_result = compile_project()

        if compile_result.returncode == 0:
            print(f"\n✅ ✅ ✅ COMPILE SUCCESSFUL! ✅ ✅ ✅")
            print(f"Total script cost: ${script_state['total_cost']:.4f}")
            print("Exiting.")
            break

        print("\n❌ COMPILE FAILED. Attempting to fix...")
        compile_count += 1
        
        error_output = compile_result.stdout
        current_error = extract_error(error_output)

        print("\n--- Current Error ---")
        print(current_error)
        print("---------------------")

        if current_error == last_error_message:
            error_try_count += 1
        else:
            last_error_message = current_error
            error_try_count = 1

        if error_try_count > args.max_tries_per_error:
            print(f"\n❌ FAILED: Stuck on the same error for {args.max_tries_per_error} attempts.")
            print(f"Total script cost: ${script_state['total_cost']:.4f}")
            print("Exiting.")
            break

        if compile_count == 1:
            aider_cmd = ['aider'] + INITIAL_FILES
            prompt = INITIAL_PROMPT
        else:
            aider_cmd = ['aider']
            prompt = f"The compilation failed. Please fix this error, remembering to change as few lines as possible.\n\nError:\n```\n{current_error}\n```"

        aider_cmd.extend(['--model', args.model, '--message', prompt])
        # --- MODIFICATION: Pass state to run_command ---
        run_command(aider_cmd, state=script_state)
        
        print("\n--- Aider's Changes ---")
        diff = get_last_aider_diff()
        print(diff)
        print("-----------------------")
        print(f"--- Cumulative Cost: ${script_state['total_cost']:.4f} ---")
        
        if compile_count >= args.max_compiles:
            print(f"\n❌ FAILED: Reached max compile attempts ({args.max_compiles}).")
            print(f"Total script cost: ${script_state['total_cost']:.4f}")

if __name__ == "__main__":
    main()