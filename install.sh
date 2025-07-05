#!/bin/bash

echo `pwd`
upside_path=$(pwd |sed -e 's/\//\\\//g')

# Detect ARM macOS and use appropriate source file
if [[ "$(uname -m)" == "arm64" ]]; then
    cp source_arm source.sh
    sed -i '' "s/UP_PATH/$upside_path/g" source.sh
else
    cp source_x86 source.sh
    sed -i "s/UP_PATH/$upside_path/g" source.sh
fi

source source.sh

rm -rf obj/*
cd obj

cmake ../src/  -DEIGEN3_INCLUDE_DIR=$EIGEN_HOME
make
