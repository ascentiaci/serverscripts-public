#!/bin/bash

#schedule via crontab
# * * */1 * * $HOME/serverscripts-public/docker-hosts/daily.sh

echo "Running daily.sh"

echo "Cleaning Docker"

if ( command -v docker > /dev/null)
then
    echo "Docker is installed"
else
    echo "Docker is not installed"
    echo "This script requires docker to be installed"
    exit 1
fi

echo "Cleaning Docker"




if ! docker system prune -a -f; then
    echo "Docker cleanup failed"
    curl 'https://uptime.888ltd.ca/api/push/RqHXLf4ntT?status=down&msg=Docker%20Cleanup%20Failed'
    exit 1
else
    echo "Docker cleanup succeeded"
    curl 'https://uptime.888ltd.ca/api/push/RqHXLf4ntT?status=up&msg=Docker%20Cleanup%20Succeeded'
fi

echo "Done"
