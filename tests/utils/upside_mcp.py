from fastmcp import FastMCP
import subprocess
import os 

mcp = FastMCP("Upside MCP Server")

up_home = os.environ.get("UPSIDE_HOME")

@mcp.tool
def run_upside(gpu_mode: bool) -> str:
    """Run Upside and Return Errors if Necessary"""
    
    global up_home
    
    if not up_home:
        return "Error: UPSIDE_HOME environment variable not set"
    
    if gpu_mode:
        try:
            result = subprocess.run(
                [
                    f"{up_home}/obj/upside",
                    "--duration", "10",
                    "--frame-interval", "1",
                    "--temperature", "0.8",
                    "--seed", "1",
                    "--cuda-acceleration",
                    "--log-level", "extensive",
                    f"{up_home}/example/01.GettingStarted/outputs/gpu/chig.run.up"
                ],  
                capture_output=True,
                text=True,
                timeout=180
            )
            return result.stdout.strip() if result.returncode == 0 else result.stderr
        except Exception as e:
            return f"Error: {str(e)}"
    else:
        try:
            result = subprocess.run(
                [
                    f"{up_home}/obj/upside",
                    "--duration", "10",
                    "--frame-interval", "1",
                    "--temperature", "0.8",
                    "--seed", "1",
                    "--log-level", "extensive", 
                    f"{up_home}/example/01.GettingStarted/outputs/simple_test/chig.run.up"
                ],  
                capture_output=True,
                text=True,
                timeout=180
            )
            return result.stdout.strip() if result.returncode == 0 else result.stderr
        except Exception as e:
            return f"Error: {str(e)}"

@mcp.tool
def compile_upside() -> str:
    """Compile Upside and Return Errors if Necessary"""

    global up_home
    
    if not up_home:
        return "Error: UPSIDE_HOME environment variable not set"

    try:
        result = subprocess.run(
            [f"{up_home}/install.sh"],
            capture_output=True,
            text=True,
            timeout=180
        )
        return "Upside Compilation Successful!" if result.returncode == 0 else result.stderr
    except Exception as e:
        return f"Error: {str(e)}"

@mcp.tool
def debug_upside(node: str) -> str:
    """Compare state of runs on provided node"""
    
    global up_home
    
    if not up_home:
        return "Error: UPSIDE_HOME environment variable not set"
    
    try:
        # Activate conda environment and run the diff script
        conda_cmd = f"source $(conda info --base)/etc/profile.d/conda.sh && conda activate upside-env && python {up_home}/tests/utils/diff.py"
        
        result = subprocess.run(
            [
                "bash", "-c", 
                f"{conda_cmd} {up_home}/example/01.GettingStarted/outputs/cpu/chig.run.up {up_home}/example/01.GettingStarted/outputs/gpu/chig.run.up {node}"
            ],
            capture_output=True,
            text=True,
            timeout=100
        )
        return result.stdout.strip() if result.returncode == 0 else result.stderr
    except Exception as e:
        return f"Error: {str(e)}"

if __name__ == "__main__":
    mcp.run()