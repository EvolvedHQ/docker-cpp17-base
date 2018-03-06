# A Docker image for general-purpose C++17 CI builds

This Docker container provides `13coders/cpp17-base`, [located in
DockerHub](https://hub.docker.com/r/13coders/cpp17-base/)

The intention of this container is to provide a "good to go"
environment for a complete CI build server for modern C++
codebases. It extends from the Jenkins docker image, and adds the
underlying C++ toolchains and utilities for a CI build to operate.

The docker container does not itself contain any description of the
structure of the CI build pipleine - the
[Jenkinsfile](https://jenkins.io/doc/book/pipeline/syntax/) for your
codebase, which you should commit alongside your code, provides the
pipeline description.

In your project's Jenkinsfile, you can reference and use the tools and
libraries installed as part of the Docker build. This provides an
environment in which a pipeline can be created, and C++ build, test
and instrumentation executed.

## Features

Extending [from the official Jenkins
image](https://github.com/jenkinsci/docker/blob/master/README.md),
additional, features are:

| Component | Source | Version | Notes |
| --- | ---| --- | --- |
| [Debian build-essential](https://packages.debian.org/stretch/build-essential) | apt-get | multiple | GCC, libc-dev, GNU make, binutils |
| [GCC](https://gcc.gnu.org/) | apt-get | 6.3.0 | Supplants GCC version from build-essential |
| [Boost](http://www.boost.org/) | S3/source | 1.65.1 | Complete, supported by CMake find_package |
| [CMake](https://cmake.org/) | S3/binary | 3.10.2 | Current stable release of CMake |
| [Clang + tools](https://clang.llvm.org/) | S3/binary | 5.0.1 | Complete install with all tools and libs |
| [libc++](https://libcxx.llvm.org/) | S3/source | 5.0.1 | MSAN-instrumented libc++ version for MSAN builds |
| [Robot Framework](http://robotframework.org/) | pip install  | 3.0.2 | Python-based acceptance test framework |
| [PMD CPD](https://pmd.github.io/pmd-6.1.0/#cpd) | S3/binary | 6.0.1 | Tool for detecting duplicated code sections |
| [Valgrind](http://valgrind.org/) | apt-get | 3.12.0 | Leak detection, cache and heap profiling and trace |
| [Google microbenchmark](https://github.com/google/benchmark) | Git | 1.3.0 | Framework for microbenchmarking tests |
| [Conan](https://www.conan.io/) | pip install | 1.1.1 | C++ package management system |
| [CppCheck](http://cppcheck.sourceforge.net/) | S3/source | 1.8.2 | C++ static analysis tool |
| [lcov](http://ltp.sourceforge.net/coverage/lcov.php) | apt-get | 1.13 | Code coverage reporting tool for gcov |

## Running the CI server

To run the server, it's common to map a volume from the host to the
Docker container `/var/jenkins_home` directory, used for all working
storage needed for the CI server:

```
$ docker run \
  -p 8080:8080 \
  -p 50000:50000 \
  -v /path/to/local/dir:/var/jenkins_home \
  --cap-add SYS_PTRACE \
  13coders/cpp17-base

```

The SYS_PTRACE capability is only needed if you plan to use the Clang
address sanitizer. We'd recommend that you add only targeted, specific
capabilities rather than running the container as `--privileged`.

If you want to conduct performance benchmarks using the Google
microbenchark framework within this Docker container, you'll need to
disable CPU frequency scaling in the host system and *not in the
container*. For example, on an 8-core Xeon system running Debian, we
would disable scaling as:

```
$ for i in {0..7}; do cpufreq-set -c $i -g performance ; done
```

And then re-enable:

```
$ for i in {0..7}; do cpufreq-set -c $i -g powersave ; done
```

The details will vary depending on your host system - please consult
your system's own documentation.

## Building the Docker image

We recommend that the image is fetched by you with a `docker pull`
directly from Docker Hub rather than building from scratch. For robust
reproducibility and fast build times, the image pulls many of its
dependencies from an AWS S3 bucket, and this bucket is private (for
reasons of pay-per-use charging as well as the presence of proprietary
software in the same bucket that can't be publicly redistributed).

If you want to use this Dockerfile to build the image yourself, you'll
need to provision an S3 bucket of your own, containing the necessary
dependencies - essentially everything that you see in the Dockerfile
fetched with a `RUN aws s3 cp ...` command. If you're doing this, we'd
also strongly recommend setting up an IAM user in AWS with minimal,
highly-constrained privileges for this task, ideally limiting those
solely to read-only access to the specific S3 bucket from where the
binary dependencies are fetched.

The AWS API keys need to be passed as a number of `--build-arg
<variable>=<value>` arguments to the `docker build` command. All are
required to fetch from S3.

Build the image using:

```
$ docker build \
  -t 13coders/cpp17-base:<x.y.z> \
  -t 13coders/cpp17-base:latest \
  --build-arg AWS_ACCESS_KEY_ID=<your aws api key> \
  --build-arg AWS_SECRET_ACCESS_KEY=<your aws secret key> \
  --build-arg AWS_DEFAULT_REGION=<the region your S3 bucket is in> \
  --build-arg AWS_BUCKET=<your bucket name> .
```

Security note: this will leave the access keys for the AWS account in
your (host) shell history as plain text, which you should clear, but
the access keys will **not** be persisted in the built Docker
image. Also note the point above about constraining the IAM role for
this task.

