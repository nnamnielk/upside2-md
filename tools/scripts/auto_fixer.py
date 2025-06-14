#!/usr/bin/env python3

import subprocess
import argparse
import os
import re
import sys
import google.generativeai as genai
from difflib import unified_diff

# --- Configuration ---

# Try to get the project directory from an environment variable.
try:
    # Ensure this environment variable is set to your C++ project's root directory.
    PROJECT_DIR = os.environ['UPSIDE_HOME']
except KeyError:
    print("Error: The UPSIDE_HOME environment variable is not set.")
    print("Please set it to the root directory of your project, e.g., `export UPSIDE_HOME=$(pwd)`")
    sys.exit(1)

# Configure the source and build directories for your project.
SRC_DIR = os.path.join(PROJECT_DIR, 'src')
BUILD_DIR = os.path.join(PROJECT_DIR, 'obj')

# --- Gemini API Configuration ---

# Ensure your GOOGLE_API_KEY environment variable is set.
try:
    genai.configure(api_key=os.environ['GOOGLE_API_KEY'])
except KeyError:
    print("Error: The GOOGLE_API_KEY environment variable is not set.")
    print("Please set it to your Google API key.")
    sys.exit(1)


# --- Prompts for the Gemini Model ---

# The initial prompt provides general context about the C++ project and the task.
INITIAL_PROMPT = """
You are an expert C++ programmer specializing in high-performance and GPU computing.
Your task is to fix compilation errors in a C++ source file.

**RULES:**
1.  You MUST respond with the complete, corrected source code for the file.
2.  Enclose the full source code in a single markdown block, like this: ```cpp ... ```.
3.  Change as few lines as possible to fix the error.

**CONTEXT:**
The project is being refactored to use a new `device_buffer` class for managing data between the CPU and GPU.
- The `device_buffer` API uses `get_host_ptr()` or `get_mutable_host_ptr()` to get a raw pointer to CPU data.
- The old code used `(row, col)` access, which is now invalid.
- The new pattern is to get the pointer and manually calculate the 1D index for the column-major layout: `index = col * elem_width + row`.

**TASK:**
The following C++ code has a compilation error. Please fix it.
"""

# The prompt for fixing a specific error includes the error message from the compiler.
FIX_PROMPT_TEMPLATE = """
The previous attempt to fix the code resulted in the following compilation error.
Please fix this new error.

**COMPILATION ERROR:**
{error_message}

**FULL SOURCE CODE:**
"""

# --- Core Functions ---

def compile_project():
    """
    Compiles the C++ project using 'make'.
    Returns a tuple: (return_code, output).
    """
    print("--- Attempting to compile the project... ---")
    # This assumes you have a Makefile in your PROJECT_DIR.
    process = subprocess.run(['make', '-C', PROJECT_DIR], capture_output=True, text=True)
    return process.returncode, process.stdout + process.stderr

def extract_error_message(compile_output):
    """
    Extracts the relevant error message from the compiler output.
    This function looks for the part of the output after a build progress indicator (e.g., [x%]).
    """
    # This regex is designed to find the error message that follows the build percentage.
    match = re.search(r'\[\s*\d+%] Building CXX object.*?\n(.*?)(?=make\[\d+]:)', compile_output, re.DOTALL)
    if match:
        return match.group(1).strip()
    return "Could not extract a specific error message. Full output:\n" + compile_output

def extract_code_from_response(response):
    """
    Extracts the C++ code from the model's markdown response.
    """
    # This regex finds the code within a ```cpp ... ``` block.
    match = re.search(r'```cpp\n(.*?)\n```', response, re.DOTALL)
    if match:
        return match.group(1)
    return None

def get_file_path_from_error(error_message):
    """
    Parses the error message to find the path to the problematic file.
    """
    # This regex looks for a file path pattern in the error message.
    match = re.search(r'([\w/.-]+\.(?:cpp|h|cu|cuh)):', error_message)
    if match:
        return os.path.join(PROJECT_DIR, match.group(1))
    return None

# --- Main Application Logic ---

def main():
    """
    The main function that orchestrates the auto-fixing process.
    """
    parser = argparse.ArgumentParser(description="Automatically fix C++ compilation errors using Gemini.")
    parser.add_argument("model", help="The name of the Gemini model to use (e.g., 'gemini-1.5-flash').")
    parser.add_argument("max_compilations", type=int, help="The maximum number of times to try compiling.")
    parser.add_argument("max_retries_per_error", type=int, help="The maximum number of times to try fixing the same error.")
    args = parser.parse_args()

    # Initialize the Gemini model.
    model = genai.GenerativeModel(args.model)

    compilation_attempts = 0
    last_error = None
    error_retries = 0

    while compilation_attempts < args.max_compilations:
        compilation_attempts += 1
        print(f"\n--- Compilation Attempt #{compilation_attempts} ---")

        return_code, output = compile_project()

        if return_code == 0:
            print("\n🎉 Compilation successful! The project has been fixed. 🎉")
            break

        print("\n❌ Compilation failed. Attempting to fix...")
        error_message = extract_error_message(output)
        print("\n--- COMPILATION ERROR ---")
        print(error_message)
        print("-------------------------\n")

        if error_message == last_error:
            error_retries += 1
        else:
            last_error = error_message
            error_retries = 1

        if error_retries > args.max_retries_per_error:
            print(f"❌ Failed to fix the same error after {args.max_retries_per_error} attempts. Aborting.")
            break

        filepath = get_file_path_from_error(error_message)
        if not filepath or not os.path.exists(filepath):
            print("❌ Could not determine the file to fix from the error message. Aborting.")
            print("Full compiler output:", output)
            break
        
        try:
            with open(filepath, 'r') as f:
                original_code = f.read()
        except FileNotFoundError:
            print(f"❌ File not found: {filepath}. Aborting.")
            break

        # Construct the prompt for the model.
        if compilation_attempts == 1:
            prompt = f"{INITIAL_PROMPT}\n\n```cpp\n{original_code}\n```"
        else:
            prompt = f"{FIX_PROMPT_TEMPLATE.format(error_message=error_message)}\n\n```cpp\n{original_code}\n```"

        try:
            print("🤖 Asking Gemini for a fix...")
            response = model.generate_content(prompt)
            new_code = extract_code_from_response(response.text)

            if not new_code:
                print("❌ Gemini did not return valid code. Aborting this attempt.")
                continue

            # Display the changes.
            print("\n--- PROPOSED CHANGES ---")
            diff = unified_diff(
                original_code.splitlines(keepends=True),
                new_code.splitlines(keepends=True),
                fromfile='a/' + os.path.basename(filepath),
                tofile='b/' + os.path.basename(filepath),
            )
            sys.stdout.writelines(diff)
            print("------------------------\n")

            # Overwrite the file with the proposed fix.
            with open(filepath, 'w') as f:
                f.write(new_code)
            
            print(f"✅ Applied fix to {filepath}.")

        except Exception as e:
            print(f"An error occurred while interacting with the Gemini API: {e}")
            break

    else:
        # This else block runs if the while loop finishes without a 'break'.
        print(f"\n❌ Maximum compilation attempts ({args.max_compilations}) reached. Aborting.")

if __name__ == "__main__":
    main()
