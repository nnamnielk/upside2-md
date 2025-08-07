Upside has a lot of impure methods. Getting real test data is important:

input_capture.py captures the variable data from file at line_number, for
max_hits. You can specify gdb custom_commands at the top of the file (changeme).
batch_capture.py is an example to run input_capture.py on all nodes. Nodes
represent 90% of Upside's codebase. 

regression.sh does all regression tests on everythig in examples by default. You
can also run subsets (e.g. --example=01,03,05,07). 
