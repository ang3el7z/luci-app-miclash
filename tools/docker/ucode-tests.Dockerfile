FROM ubuntu:22.04

ARG DEBIAN_FRONTEND=noninteractive
ARG UCODE_REVISION=3f64c8089bf3ea4847c96b91df09fbfcaec19e1d

RUN apt-get update \
	&& apt-get install -yq --no-install-recommends \
		build-essential \
		busybox-static \
		ca-certificates \
		cmake \
		git \
		iproute2 \
		libjson-c-dev \
		libmd-dev \
		pkg-config \
		util-linux \
	&& git clone --filter=blob:none https://github.com/jow-/ucode.git /tmp/ucode-src \
	&& git -C /tmp/ucode-src checkout --detach "$UCODE_REVISION" \
	&& cmake -S /tmp/ucode-src -B /opt/ucode-build \
		-DCMAKE_BUILD_TYPE=Release \
		-DDIGEST_SUPPORT=ON \
		-DFS_SUPPORT=ON \
		-DMATH_SUPPORT=ON \
		-DSOCKET_SUPPORT=ON \
		-DNL80211_SUPPORT=OFF \
		-DRESOLV_SUPPORT=OFF \
		-DRTNL_SUPPORT=OFF \
		-DSTRUCT_SUPPORT=ON \
		-DUBUS_SUPPORT=OFF \
		-DUCI_SUPPORT=OFF \
		-DULOOP_SUPPORT=OFF \
		-DDEBUG_SUPPORT=ON \
		-DLOG_SUPPORT=OFF \
	&& cmake --build /opt/ucode-build --parallel \
	&& /opt/ucode-build/ucode -e 'print("ucode host binary ready\n")' \
	&& rm -rf /tmp/ucode-src /var/lib/apt/lists/*

ENV UCODE_BIN=/opt/ucode-build/ucode
ENV LD_LIBRARY_PATH=/opt/ucode-build

WORKDIR /workspace
