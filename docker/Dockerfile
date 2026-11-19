# Development and test image for the HTTP-TPC multi-stream work.
#
# AlmaLinux 9 is used on purpose: it ships the libcurl (7.76.1) that most
# production XRootD servers run, and libcurl behaviour is central to the
# multi-stream code path.
FROM almalinux:9

RUN dnf install -y dnf-plugins-core epel-release \
 && dnf config-manager --set-enabled crb \
 && dnf install -y \
      gcc-c++ cmake make git-core which pkgconfig gdb \
      openssl openssl-devel libcurl-devel libuuid-devel zlib-devel libxml2-devel \
      readline-devel json-c-devel libxcrypt-devel \
      scitokens-cpp-devel libmacaroons-devel \
      gtest-devel gmock-devel \
      python3 iproute iproute-tc iputils procps-ng jq attr sqlite \
      util-linux diffutils findutils hostname \
 && dnf clean all

# Needed by bdp/measure.sh to turn off segmentation offload on the test link.
RUN dnf install -y ethtool && dnf clean all

# The tests refuse to run as root; use an unprivileged user whose uid matches
# the owner of the bind-mounted source tree.
ARG UID=1000
ARG GID=1000
RUN groupadd -g ${GID} dev && useradd -u ${UID} -g ${GID} -m dev
USER dev
