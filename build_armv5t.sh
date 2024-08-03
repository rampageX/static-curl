#!/bin/sh

ARCH=armv5 HTTP_PROXY="http://192.168.2.20:7776" HTTPS_PROXY="http://192.168.2.20:7776" STATIC_LIBRARY=1 CURL_VERSION=8.9.1 CONTAINER_IMAGE=alpine:latest sh curl-static-cross-armv5.sh