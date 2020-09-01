FROM alpine:latest AS builder

LABEL maintainer=chuiyouwu@gmail.com


ARG HUGO_VERSION=0.68.3
ARG HUGO_EXTENDED=_extended


RUN apk add --update git asciidoctor libc6-compat libstdc++ make\
    && apk upgrade \
    && apk add --no-cache ca-certificates

ADD https://github.com/gohugoio/hugo/releases/download/v${HUGO_VERSION}/hugo${HUGO_EXTENDED}_${HUGO_VERSION}_Linux-64bit.tar.gz /tmp

RUN tar -xf /tmp/hugo${HUGO_EXTENDED}_${HUGO_VERSION}_Linux-64bit.tar.gz -C   /usr/local/bin/


ARG GIT_REPOSITORY=https://github.com/YouEclipse/blog.git
ARG GIT_REPOSITORY_NAME=blog

WORKDIR /tmp

RUN git clone  ${GIT_REPOSITORY} 

WORKDIR /tmp/${GIT_REPOSITORY_NAME} 


CMD make run

EXPOSE 1313
