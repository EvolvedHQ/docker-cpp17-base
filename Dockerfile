# For a detailed description and guide on how best to use this Docker
# image, please look at the README.  Note that this image is set up to
# pull many of its requirements from an S3 bucket rather than the
# public internet. Unless you want to build this Docker image
# yourself, we'd recommend just using as-is with a docker pull.

# The image extends from the base Jenkins CI image (always an
# identified version, never latest...), and adds additional tooling
# that's specific to modern C++ development. It's expected that this
# image will be extended further for specific use cases - especially
# for embedded C++.

FROM jenkins/jenkins:2.184
MAINTAINER Mike Ritchie <mike@13coders.com>
LABEL description="Docker base image for C++17 CI builds"

# These environment variables for the AWS command line need to be
# passed to the docker build command. This is preferable to persisting
# credentials in the Docker image. Note that these credentials will be
# visible in your (host) shell history, so clear them down. Also use
# an IAM role in AWS with highly constrained privileges - potentially
# read-only access to the single S3 bucket containing the
# dependencies.

ARG AWS_ACCESS_KEY_ID
ARG AWS_SECRET_ACCESS_KEY
ARG AWS_DEFAULT_REGION
ARG AWS_BUCKET

# Switch to root for installation of additional C++ tooling - we
# switch back to Jenkins user before the end of the image build.

USER root

# Update the apt repositories and install common development
# dependencies.

RUN apt-get update && apt-get install -y build-essential gcc-6 gdb git valgrind \
    python3-pip python3-venv python-dev linux-perf google-perftools \
    zlib1g-dev lcov mc && \
    apt-get clean

# Install and configure python dependencies: (1) AWS command line
# tools for fetching binaries from a private S3 bucket (2) install
# Robot Framework for BDD-style testing of C++ libraries (3)
# virtualenv systemwide to allow in-CI creation of Python environments
# (4) install Conan package management system with pip.

RUN pip3 install awscli robotframework virtualenv conan

# Versions of tools that are used in this build. File extensions are
# appended later in the script at the point where assets are
# downloaded and extracted. Note that these are not expected to be
# passed as build args when invoking Docker build, just a
# cheap-and-cheerful way of defining filenames only once.

ARG v_clang_llvm_bin=clang+llvm-5.0.1-x86_64-linux-gnu-debian8.tar.xz
ARG v_clang_llvm_src=llvm-5.0.1.src.tar.xz
ARG v_clang_libcxx_src=libcxx-5.0.1.src.tar.xz
ARG v_clang_libcxxabi_src=libcxxabi-5.0.1.src.tar.xz
ARG v_pmd=pmd-bin-6.0.1.zip
ARG v_boost=boost_1_65_1.tar.gz
ARG v_cmake=cmake-3.10.2-Linux-x86_64.tar.gz

# Install a more recent (than the Debian Stretch version) CMake from
# the binary distribution into /usr

RUN aws s3 cp s3://${AWS_BUCKET}/${v_cmake} . \
    && tar xf ${v_cmake} -C /usr --strip 1 \
    && aws s3 cp s3://${AWS_BUCKET}/${v_clang_llvm_bin} .\
    && tar xf ${v_clang_llvm_bin} -C /usr --strip 1 \
    && rm /${v_cmake} && rm /${v_clang_llvm_bin}

# Fetch the sources needed to compile an MSAN-sanitized version of
# libc++. The versions of these sources need to correspond exactly to
# the clang/llvm version we're using to compile the host (amd64)

RUN mkdir -p /opt/tools/llvm-build/projects/libcxx && \
    mkdir -p /opt/tools/llvm-build/projects/libcxxabi && \
    aws s3 cp s3://${AWS_BUCKET}/${v_clang_llvm_src} . && \
    tar xf ${v_clang_llvm_src} -C /opt/tools/llvm-build --strip 1 && \
    aws s3 cp s3://${AWS_BUCKET}/${v_clang_libcxxabi_src} . && \
    tar xf ${v_clang_libcxxabi_src} -C /opt/tools/llvm-build/projects/libcxxabi --strip 1 && \
    aws s3 cp s3://${AWS_BUCKET}/${v_clang_libcxx_src} . && \
    tar xf ${v_clang_libcxx_src} -C /opt/tools/llvm-build/projects/libcxx --strip 1 && \
    rm /${v_clang_llvm_src} && \
    rm /${v_clang_libcxxabi_src} && \
    rm /${v_clang_libcxx_src}

# Now build libc++ as a MSAN-instrumented library. It's necessary to
# link to both this and libc++abi when building the MSAN-instrumented
# binary for unit tests, otherwise many false positives will result
# from any use of C++ Standard Library API. Building this needs a
# fairly complete clang/llvm source tree, although we only build the
# libcxx target within that tree.

RUN mkdir -p /opt/lib/libcxx-msan && \
    cd /opt/lib/libcxx-msan && \
    cmake -DCMAKE_BUILD_TYPE=Release -DLLVM_USE_SANITIZER=Memory \
    -DCMAKE_C_COMPILER=/usr/bin/clang \
    -DCMAKE_CXX_COMPILER=/usr/bin/clang++ /opt/tools/llvm-build && \
    cd /opt/lib/libcxx-msan && make cxx cxxabi -j4

# Fetch, build and install a complete suite of Boost framework
# libraries to /usr/local. Note that 1.65.x is the last version that
# plays nicely with the "find boost" component in CMake - 1.66 breaks
# compatibility. First, linked against libc++

RUN aws s3 cp s3://${AWS_BUCKET}/${v_boost} . && \
    mkdir -p boostlibcxx && \
    tar xf ${v_boost} -C boostlibcxx --strip 1 && \
    cd boostlibcxx && ./bootstrap.sh --prefix=/opt/lib/boost/libcxx && \
    ./b2 toolset=clang cxxflags="-stdlib=libc++" linkflags="-stdlib=libc++" install && \
    rm -rf /boostlibcxx

# Now again as a memory sanitized build, linked against the sanitized
# version of libc++

RUN mkdir -p boostlibcxxmsan && \
    tar xf ${v_boost} -C boostlibcxxmsan --strip 1 && \
    cd boostlibcxxmsan && ./bootstrap.sh --prefix=/opt/lib/boost/libcxxmsan && \
    ./b2 toolset=clang \
       cxxflags="-stdlib=libc++ -Wall -Wno-register -O1 -g -fsanitize=memory -fno-omit-frame-pointer -fno-optimize-sibling-calls" \
       linkflags="-stdlib=libc++ -Wl,-rpath,/opt/lib/libcxx-msan/lib" install && \
    rm -rf /boostlibcxxmsan

# ...And again, finally, this time linked against libstdc++

RUN mkdir -p boostlibstdc++ && \
    tar xf ${v_boost} -C boostlibstdc++ --strip 1 && \
    cd boostlibstdc++ && ./bootstrap.sh --prefix=/opt/lib/boost/libstdc++ && \
    ./b2 toolset=gcc install && \
    rm /${v_boost} && rm -rf /boostlibstdc++

# Fetch, build and install the Google microbenchmark support library
# from sources.

RUN git clone https://github.com/google/benchmark.git -b v1.3.0 && \
   mkdir -p benchmark/build && \
   cd benchmark/build && cmake .. -DCMAKE_BUILD_TYPE=Release && \
   make && make install && \
   rm -rf /benchmark
    
# Fetch and install the (Java) CPD tool for detecting sections of
# duplicated code. PMD is only distributed (in binary form) as a zip
# file, and there's no --strip option, hence small dance with
# the directory move.

RUN aws s3 cp s3://${AWS_BUCKET}/${v_pmd} . && \
    unzip ${v_pmd} -d /opt/tools && \
    mv /opt/tools/pmd-bin-* /opt/tools/pmd && \
    rm /${v_pmd}

# Done with everything that needs root permissions. Revert now to the
# Jenkins user.

USER jenkins

# Set the path to pick up the additional tools we've added. We do this
# for the Jenkins user, and it has to persist.

ENV PATH "$PATH:/opt/tools/pmd/bin"

# Set convenience paths for libraries to simplify CI build pipeline
# configuration.

ENV LIB_CXX_MSAN             "/opt/lib/libcxx-msan"
ENV LIB_BOOST_LIBCXX         "/opt/lib/boost/libcxx"
ENV LIB_BOOST_LIBCXX_MSAN    "/opt/lib/boost/libcxxmsan"
ENV LIB_BOOST_LIBSTDC++      "/opt/lib/boost/libstdc++"

# Update the number of executors. Typical pipeline design is using a
# max of 4 parallel steps for 4x sanitizers.

COPY executors.groovy /usr/share/jenkins/ref/init.groovy.d/executors.groovy

# Install additional Jenkins plugins for the pipeline design to
# operate. On creating and starting a new Jenkins instance from this
# Docker image, the usual startup screens will be displayed, but the
# "install plugins" page can be skipped (select "none" in the plugins
# list when prompted). Switch back to the jenkins user for this step.

COPY plugins.txt /usr/share/jenkins/plugins.txt
RUN xargs /usr/local/bin/install-plugins.sh < /usr/share/jenkins/plugins.txt
