#!/bin/bash

echo `pwd`
upside_path=$(pwd |sed -e 's/\//\\\//g')
cp source_sh source.sh
sed -i "s/UP_PATH/$upside_path/g" source.sh

source source.sh

rm -rf obj/*
cd obj

cmake ../src/ \
    -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
    -DCMAKE_CUDA_COMPILER_LAUNCHER=ccache \
    -DEIGEN3_INCLUDE_DIR=$EIGEN_HOME
make
