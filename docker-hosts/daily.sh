#!/bin/bash

if ( command -v docker > /dev/null)
then
    echo "Docker is installed"
else
    echo "Docker is not installed"
    echo "This script requires docker to be installed"
    exit 1
fi

echo "Cleaning Docker"

docker system prune -a -f

echo "Done"
