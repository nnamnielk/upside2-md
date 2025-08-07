import os
import re
import sys

def find_node_structs(base_dir):
    results = []
    # Regex: struct <Name> : public CoordNode OR PotentialNode
    struct_pattern = re.compile(
        r'\bstruct\s+(\w+)\s*:\s*public\s+(CoordNode|PotentialNode)\b')
    compute_pattern = re.compile(r'virtual\s+void\s+compute_value\s*\(')

    for root, _, files in os.walk(base_dir):
        for fname in files:
            if fname.endswith('.cpp') or fname.endswith('.h'):
                path = os.path.join(root, fname)
                try:
                    with open(path, encoding='utf-8', errors='ignore') as f:
                        lines = f.readlines()
                except Exception as e:
                    print(f"Could not read {path}: {e}", file=sys.stderr)
                    continue

                inside_struct = False
                cur_struct = None
                cur_parent = None
                brace_count = 0
                for idx, line in enumerate(lines):
                    # Look for struct definition
                    struct_match = struct_pattern.search(line)
                    if struct_match:
                        cur_struct = struct_match.group(1)
                        cur_parent = struct_match.group(2)
                        inside_struct = True
                        brace_count = line.count('{') - line.count('}')
                        continue

                    if inside_struct:
                        brace_count += line.count('{') - line.count('}')
                        # Look for compute_value method
                        if compute_pattern.search(line):
                            results.append({
                                'struct': cur_struct,
                                'parent': cur_parent,
                                'file': path,
                                'line': idx + 1
                            })
                        # End of struct
                        if brace_count <= 0:
                            inside_struct = False
                            cur_struct = None
                            cur_parent = None

    return results

if __name__ == '__main__':
    upside_home = os.environ.get('UPSIDE_HOME')
    if not upside_home:
        print("Environment variable UPSIDE_HOME is not set.", file=sys.stderr)
        sys.exit(1)
    base_dir = os.path.join(upside_home, 'src/')
    if not os.path.isdir(base_dir):
        print(f"Directory does not exist: {base_dir}", file=sys.stderr)
        sys.exit(1)

    matches = find_node_structs(base_dir)
    output_lines = []
    for match in matches:
        line = f"{match['struct']} : public {match['parent']} in {match['file']} at line {match['line']}"
        print(line)
        output_lines.append(line)

    # Make sure tmp directory exists
    tmp_dir = os.path.abspath(os.path.join(base_dir, "../tests/tmp"))
    os.makedirs(tmp_dir, exist_ok=True)
    log_path = os.path.join(tmp_dir, "nodes.list.txt")
    try:
        with open(log_path, 'w', encoding='utf-8') as logfile:
            for line in output_lines:
                logfile.write(line + "\n")
        print(f"\nLog written to {log_path}")
    except Exception as e:
        print(f"Failed to write log file: {e}", file=sys.stderr)