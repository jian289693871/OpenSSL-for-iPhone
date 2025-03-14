#!/bin/sh

#  Automatic build script for libssl and libcrypto
#  for iPhoneOS and iPhoneSimulator
#
#  Created by Felix Schulze on 16.12.10.
#  Copyright 2010-2019 Felix Schulze. All rights reserved.
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#  http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.
#

# -u  Attempt to use undefined variable outputs error message, and forces an exit
set -u

# SCRIPT DEFAULTS

# Default version in case no version is specified
DEFAULTVERSION="1.1.1q"

# Default (=full) set of targets to build
# DEFAULTTARGETS="ios-sim-cross-x86_64 ios-sim-cross-arm64 ios-cross-arm64 mac-catalyst-x86_64 mac-catalyst-arm64 tvos-sim-cross-x86_64 tvos-sim-cross-arm64 tvos-cross-arm64 watchos-sim-cross-x86_64 watchos-sim-cross-arm64 watchos-cross-armv7k watchos-cross-arm64_32"
DEFAULTTARGETS="ios-sim-cross-x86_64 ios-cross-arm64"

# Excluded targets:
#   ios-sim-cross-i386  Legacy
#   ios-cross-armv7s    Dropped by Apple in Xcode 6 (https://www.cocoanetics.com/2014/10/xcode-6-drops-armv7s/)
#   ios-cross-arm64e    Not in use as of Xcode 12

# Minimum iOS/tvOS SDK version to build for

IOS_MIN_SDK_VERSION="15.0"
TVOS_MIN_SDK_VERSION="15.0"
WATCHOS_MIN_SDK_VERSION="8.5"
MACOSX_MIN_SDK_VERSION="12.3"

# Init optional env variables (use available variable or default to empty string)
CURL_OPTIONS="${CURL_OPTIONS:-}"
CONFIG_OPTIONS="${CONFIG_OPTIONS:-}"

echo_help()
{
  echo "Usage: $0 [options...]"
  echo "Generic options"
  echo "     --branch=BRANCH               Select OpenSSL branch to build. The script will determine and download the latest release for that branch"
  echo "     --cleanup                     Clean up build directories (bin, include/openssl, lib, src) before starting build"
  echo "     --ec-nistp-64-gcc-128         Enable configure option enable-ec_nistp_64_gcc_128 for 64 bit builds"
  echo " -h, --help                        Print help (this message)"
  echo "     --ios-sdk=SDKVERSION          Override iOS SDK version"
  echo "     --macosx-sdk=SDKVERSION       Override MacOSX SDK version"
  echo "     --noparallel                  Disable running make with parallel jobs (make -j)"
  echo "     --tvos-sdk=SDKVERSION         Override tvOS SDK version"
  echo "     --disable-bitcode             Disable embedding Bitcode"
  echo " -v, --verbose                     Enable verbose logging"
  echo "     --verbose-on-error            Dump last 500 lines from log file if an error occurs (for Travis builds)"
  echo "     --version=VERSION             OpenSSL version to build (defaults to ${DEFAULTVERSION})"
  echo "     --deprecated                  Exclude no-deprecated configure option and build with deprecated methods"
  echo "     --targets=\"TARGET TARGET ...\" Space-separated list of build targets"
  echo "                                     Options: ${DEFAULTTARGETS} mac-catalyst-x86_64"
  echo
  echo "For custom configure options, set variable CONFIG_OPTIONS"
  echo "For custom cURL options, set variable CURL_OPTIONS"
  echo "  Example: CURL_OPTIONS=\"--proxy 192.168.1.1:8080\" ./build-libssl.sh"
}

spinner()
{
  local pid=$!
  local delay=0.75
  local spinstr='|/-\'
  while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
    local temp=${spinstr#?}
    printf "  [%c]" "$spinstr"
    local spinstr=$temp${spinstr%"$temp"}
    sleep $delay
    printf "\b\b\b\b\b"
  done

  wait $pid
  return $?
}

# Prepare target and source dir in build loop
prepare_target_source_dirs()
{
  # Prepare target dir
  TARGETDIR="${CURRENTPATH}/bin/${PLATFORM}${SDKVERSION}-${ARCH}.sdk"
  mkdir -p "${TARGETDIR}"
  LOG="${TARGETDIR}/build-openssl-${VERSION}.log"

  echo "Building openssl-${VERSION} for ${PLATFORM} ${SDKVERSION} ${ARCH}..."
  echo "  Logfile: ${LOG}"

  # Prepare source dir
  SOURCEDIR="${CURRENTPATH}/src/${PLATFORM}-${ARCH}"
  mkdir -p "${SOURCEDIR}"
  tar zxf "${CURRENTPATH}/${OPENSSL_ARCHIVE_FILE_NAME}" -C "${SOURCEDIR}"
  cd "${SOURCEDIR}/${OPENSSL_ARCHIVE_BASE_NAME}"
  chmod u+x ./Configure
}

# Check for error status
check_status()
{
  local STATUS=$1
  local COMMAND=$2

  if [ "${STATUS}" != 0 ]; then
    if [[ "${LOG_VERBOSE}" != "verbose"* ]]; then
      echo "Problem during ${COMMAND} - Please check ${LOG}"
    fi

    # Dump last 500 lines from log file for verbose-on-error
    if [ "${LOG_VERBOSE}" == "verbose-on-error" ]; then
      echo "Problem during ${COMMAND} - Dumping last 500 lines from log file"
      echo
      tail -n 500 "${LOG}"
    fi

    exit 1
  fi
}

# Run Configure in build loop
run_configure()
{
  echo "  Configure..."
  set +e
  if [ "${LOG_VERBOSE}" == "verbose" ]; then
    ./Configure ${LOCAL_CONFIG_OPTIONS} no-tests | tee "${LOG}"
  else
    (./Configure ${LOCAL_CONFIG_OPTIONS} no-tests > "${LOG}" 2>&1) & spinner
  fi

  # Check for error status
  check_status $? "Configure"
}

# Run make in build loop
run_make()
{
  echo "  Make (using ${BUILD_THREADS} thread(s))..."
  if [ "${LOG_VERBOSE}" == "verbose" ]; then
    make -j "${BUILD_THREADS}" | tee -a "${LOG}"
  else
    (make -j "${BUILD_THREADS}" >> "${LOG}" 2>&1) & spinner
  fi

  # Check for error status
  check_status $? "make"
}

# Cleanup and bookkeeping at end of build loop
finish_build_loop()
{
  # Return to ${CURRENTPATH} and remove source dir
  cd "${CURRENTPATH}"
  rm -r "${SOURCEDIR}"

  # Add references to library files to relevant arrays
  if [[ "${PLATFORM}" == iPhoneOS ]]; then
    LIBSSL_IOS+=("${TARGETDIR}/lib/libssl.a")
    LIBCRYPTO_IOS+=("${TARGETDIR}/lib/libcrypto.a")
    OPENSSLCONF_SUFFIX="ios_${ARCH}"
  elif [[ "${PLATFORM}" == iPhoneSimulator ]]; then
    LIBSSL_IOSSIM+=("${TARGETDIR}/lib/libssl.a")
    LIBCRYPTO_IOSSIM+=("${TARGETDIR}/lib/libcrypto.a")
    OPENSSLCONF_SUFFIX="ios_${ARCH}"
  elif [[ "${PLATFORM}" == AppleTVOS ]]; then
    LIBSSL_TVOS+=("${TARGETDIR}/lib/libssl.a")
    LIBCRYPTO_TVOS+=("${TARGETDIR}/lib/libcrypto.a")
    OPENSSLCONF_SUFFIX="tvos_${ARCH}"
  elif [[ "${PLATFORM}" == AppleTVSimulator ]]; then
    LIBSSL_TVOSSIM+=("${TARGETDIR}/lib/libssl.a")
    LIBCRYPTO_TVOSSIM+=("${TARGETDIR}/lib/libcrypto.a")
    OPENSSLCONF_SUFFIX="tvos_${ARCH}"
  elif [[ "${PLATFORM}" == WatchOS ]]; then
    LIBSSL_WATCHOS+=("${TARGETDIR}/lib/libssl.a")
    LIBCRYPTO_WATCHOS+=("${TARGETDIR}/lib/libcrypto.a")
    OPENSSLCONF_SUFFIX="watchos_${ARCH}"
  elif [[ "${PLATFORM}" == WatchSimulator ]]; then
    LIBSSL_WATCHOSSIM+=("${TARGETDIR}/lib/libssl.a")
    LIBCRYPTO_WATCHOSSIM+=("${TARGETDIR}/lib/libcrypto.a")
    OPENSSLCONF_SUFFIX="watchos_${ARCH}"
  else # Catalyst
    LIBSSL_CATALYST+=("${TARGETDIR}/lib/libssl.a")
    LIBCRYPTO_CATALYST+=("${TARGETDIR}/lib/libcrypto.a")
    OPENSSLCONF_SUFFIX="catalyst_${ARCH}"
  fi

  # Copy opensslconf.h to bin directory and add to array
  OPENSSLCONF="opensslconf_${OPENSSLCONF_SUFFIX}.h"
  cp "${TARGETDIR}/include/openssl/opensslconf.h" "${CURRENTPATH}/bin/${OPENSSLCONF}"
  OPENSSLCONF_ALL+=("${OPENSSLCONF}")

  # Keep reference to first build target for include file
  if [ -z "${INCLUDE_DIR}" ]; then
    INCLUDE_DIR="${TARGETDIR}/include/openssl"
  fi
}

# Init optional command line vars
ARCHS=""
BRANCH=""
CLEANUP=""
CONFIG_ENABLE_EC_NISTP_64_GCC_128=""
CONFIG_DISABLE_BITCODE=""
CONFIG_NO_DEPRECATED=""
IOS_SDKVERSION=""
MACOSX_SDKVERSION=""
LOG_VERBOSE=""
PARALLEL=""
TARGETS=""
TVOS_SDKVERSION=""
VERSION=""
WATCHOS_SDKVERSION=""
REPOROOT=$(pwd)

# Process command line arguments
for i in "$@"
do
case $i in
  --archs=*)
    ARCHS="${i#*=}"
    shift
    ;;
  --branch=*)
    BRANCH="${i#*=}"
    shift
    ;;
  --cleanup)
    CLEANUP="true"
    ;;
  --deprecated)
    CONFIG_NO_DEPRECATED="false"
    ;;
  --ec-nistp-64-gcc-128)
    CONFIG_ENABLE_EC_NISTP_64_GCC_128="true"
    ;;
  --disable-bitcode)
    CONFIG_DISABLE_BITCODE="true"
    ;;
  -h|--help)
    echo_help
    exit
    ;;
  --ios-sdk=*)
    IOS_SDKVERSION="${i#*=}"
    shift
    ;;
  --macosx-sdk=*)
    MACOSX_SDKVERSION="${i#*=}"
    shift
    ;;
  --noparallel)
    PARALLEL="false"
    ;;
  --targets=*)
    TARGETS="${i#*=}"
    shift
    ;;
  --tvos-sdk=*)
    TVOS_SDKVERSION="${i#*=}"
    shift
    ;;
  --watchos-sdk=*)
    WATCHOS_SDKVERSION="${i#*=}"
    shift
    ;;
  -v|--verbose)
    LOG_VERBOSE="verbose"
    ;;
  --verbose-on-error)
    LOG_VERBOSE="verbose-on-error"
    ;;
  --version=*)
    VERSION="${i#*=}"
    shift
    ;;
  --reporoot=*)
    REPOROOT="${i#*=}"
    mkdir -p "${REPOROOT}"
    shift
    ;;
  *)
    echo "Unknown argument: ${i}"
    ;;
esac
done

# Don't mix version and branch
if [[ -n "${VERSION}" && -n "${BRANCH}" ]]; then
  echo "Either select a branch (the script will determine and build the latest version) or select a specific version, but not both."
  exit 1

# Specific version: Verify version number format. Expected: dot notation
elif [[ -n "${VERSION}" && ! "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+[a-z]*$ ]]; then
  echo "Unknown version number format. Examples: 1.1.0, 1.1.0l"
  exit 1

# Specific branch
elif [ -n "${BRANCH}" ]; then
  # Verify version number format. Expected: dot notation
  if [[ ! "${BRANCH}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Unknown branch version number format. Examples: 1.1.0, 1.2.0"
    exit 1

  # Valid version number, determine latest version
  else
    echo "Checking latest version of ${BRANCH} branch on openssl.org..."
    # Get directory content listing of /source/ (only contains latest version per branch), limit list to archives (so one archive per branch),
    # filter for the requested branch, sort the list and get the last item (last two steps to ensure there is always 1 result)
    VERSION=$(curl ${CURL_OPTIONS} -s https://ftp.openssl.org/source/ | grep -Eo '>openssl-[0-9]\.[0-9]\.[0-9][a-z]*\.tar\.gz<' | grep -Eo "${BRANCH//./\.}[a-z]*" | sort | tail -1)

    # Verify result
    if [ -z "${VERSION}" ]; then
      echo "Could not determine latest version, please check https://www.openssl.org/source/ and use --version option"
      exit 1
    fi
  fi

# Script default
elif [ -z "${VERSION}" ]; then
  VERSION="${DEFAULTVERSION}"
fi

BUILD_TYPE="targets"

# Set default for TARGETS if not specified
if [ ! -n "${TARGETS}" ]; then
  TARGETS="${DEFAULTTARGETS}"
fi

# Add no-deprecated config option (if not overwritten)
if [ "${CONFIG_NO_DEPRECATED}" != "false" ]; then
  CONFIG_OPTIONS="${CONFIG_OPTIONS} no-deprecated"
fi

# Determine SDK versions
if [ ! -n "${IOS_SDKVERSION}" ]; then
  IOS_SDKVERSION=$(xcrun -sdk iphoneos --show-sdk-version)
fi
if [ ! -n "${MACOSX_SDKVERSION}" ]; then
  MACOSX_SDKVERSION=$(xcrun -sdk macosx --show-sdk-version)
fi
if [ ! -n "${TVOS_SDKVERSION}" ]; then
  TVOS_SDKVERSION=$(xcrun -sdk appletvos --show-sdk-version)
fi
if [ ! -n "${WATCHOS_SDKVERSION}" ]; then
  WATCHOS_SDKVERSION=$(xcrun -sdk watchos --show-sdk-version)
fi

# Determine number of cores for (parallel) build
BUILD_THREADS=1
if [ "${PARALLEL}" != "false" ]; then
  BUILD_THREADS=$(sysctl hw.ncpu | awk '{print $2}')
fi

# Determine script directory
SCRIPTDIR=$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd)

# Write files relative to current location and validate directory
CURRENTPATH=$REPOROOT
case "${CURRENTPATH}" in
  *\ * )
    echo "Your path contains whitespaces, which is not supported by 'make install'."
    exit 1
  ;;
esac
cd "${CURRENTPATH}"

# Validate Xcode Developer path
DEVELOPER=$(xcode-select -print-path)
if [ ! -d "${DEVELOPER}" ]; then
  echo "Xcode path is not set correctly ${DEVELOPER} does not exist"
  echo "run"
  echo "sudo xcode-select -switch <Xcode path>"
  echo "for default installation:"
  echo "sudo xcode-select -switch /Applications/Xcode.app/Contents/Developer"
  exit 1
fi

case "${DEVELOPER}" in
  *\ * )
    echo "Your Xcode path contains whitespaces, which is not supported."
    exit 1
  ;;
esac

# Show build options
echo
echo "Build options"
echo "  OpenSSL version: ${VERSION}"
echo "  Targets: ${TARGETS}"
echo "  iOS SDK: ${IOS_SDKVERSION}"
echo "  tvOS SDK: ${TVOS_SDKVERSION}"
echo "  watchOS SDK: ${WATCHOS_SDKVERSION}"
echo "  MacOSX SDK: ${MACOSX_SDKVERSION}"

if [ "${CONFIG_DISABLE_BITCODE}" == "true" ]; then
  echo "  Bitcode embedding disabled"
fi
echo "  Number of make threads: ${BUILD_THREADS}"
if [ -n "${CONFIG_OPTIONS}" ]; then
  echo "  Configure options: ${CONFIG_OPTIONS}"
fi
echo "  Build location: ${CURRENTPATH}"
echo

# Download OpenSSL when not present
OPENSSL_ARCHIVE_BASE_NAME="openssl-${VERSION}"
OPENSSL_ARCHIVE_FILE_NAME="${OPENSSL_ARCHIVE_BASE_NAME}.tar.gz"
if [ ! -e ${OPENSSL_ARCHIVE_FILE_NAME} ]; then
  echo "Downloading ${OPENSSL_ARCHIVE_FILE_NAME}..."
  OPENSSL_ARCHIVE_URL="https://www.openssl.org/source/${OPENSSL_ARCHIVE_FILE_NAME}"

  # Check whether file exists here (this is the location of the latest version for each branch)
  # -s be silent, -f return non-zero exit status on failure, -I get header (do not download)
  curl ${CURL_OPTIONS} -sfI "${OPENSSL_ARCHIVE_URL}" > /dev/null

  # If unsuccessful, try the archive
  if [ $? -ne 0 ]; then
    BRANCH=$(echo "${VERSION}" | grep -Eo '^[0-9]\.[0-9]\.[0-9]')
    OPENSSL_ARCHIVE_URL="https://www.openssl.org/source/old/${BRANCH}/${OPENSSL_ARCHIVE_FILE_NAME}"

    curl ${CURL_OPTIONS} -sfI "${OPENSSL_ARCHIVE_URL}" > /dev/null
  fi

  # Both attempts failed, so report the error
  if [ $? -ne 0 ]; then
    echo "An error occurred trying to find OpenSSL ${VERSION} on ${OPENSSL_ARCHIVE_URL}"
    echo "Please verify that the version you are trying to build exists, check cURL's error message and/or your network connection."
    exit 1
  fi

  # Archive was found, so proceed with download.
  # -O Use server-specified filename for download
  curl ${CURL_OPTIONS} -O "${OPENSSL_ARCHIVE_URL}"

else
  echo "Using ${OPENSSL_ARCHIVE_FILE_NAME}"
fi

# Set reference to custom configuration (OpenSSL 1.1.0)
# See: https://github.com/openssl/openssl/commit/afce395cba521e395e6eecdaf9589105f61e4411
export OPENSSL_LOCAL_CONFIG_DIR="${SCRIPTDIR}/config"

# -e  Abort script at first error, when a command exits with non-zero status (except in until or while loops, if-tests, list constructs)
# -o pipefail  Causes a pipeline to return the exit status of the last command in the pipe that returned a non-zero return value
set -eo pipefail

# Clean up target directories if requested and present
if [ "${CLEANUP}" == "true" ]; then
  if [ -d "${CURRENTPATH}/bin" ]; then
    rm -r "${CURRENTPATH}/bin"
  fi
  if [ -d "${CURRENTPATH}/include/openssl" ]; then
    rm -r "${CURRENTPATH}/include/openssl"
  fi
  if [ -d "${CURRENTPATH}/lib" ]; then
    rm -r "${CURRENTPATH}/lib"
  fi
  if [ -d "${CURRENTPATH}/src" ]; then
    rm -r "${CURRENTPATH}/src"
  fi
fi

# (Re-)create target directories
mkdir -p "${CURRENTPATH}/bin"
mkdir -p "${CURRENTPATH}/lib"
mkdir -p "${CURRENTPATH}/src"

# Init vars for library references
INCLUDE_DIR=""
OPENSSLCONF_ALL=()
LIBSSL_IOS=()
LIBSSL_IOSSIM=()
LIBCRYPTO_IOS=()
LIBCRYPTO_IOSSIM=()
LIBSSL_TVOS=()
LIBSSL_TVOSSIM=()
LIBCRYPTO_TVOS=()
LIBCRYPTO_TVOSSIM=()
LIBSSL_WATCHOS=()
LIBSSL_WATCHOSSIM=()
LIBCRYPTO_WATCHOS=()
LIBCRYPTO_WATCHOSSIM=()
LIBSSL_CATALYST=()
LIBCRYPTO_CATALYST=()

# Run relevant build loop
source "${SCRIPTDIR}/scripts/build-loop-targets.sh"

# Build iOS/Simulator library if selected for build
# if [ ${#LIBSSL_IOS[@]} -gt 0 ]; then
#   echo "Build library for iOS..."
#   lipo -create ${LIBSSL_IOS[@]} -output "${CURRENTPATH}/lib/libssl-iOS.a"
#   lipo -create ${LIBCRYPTO_IOS[@]} -output "${CURRENTPATH}/lib/libcrypto-iOS.a"
#   echo "\n=====>iOS SSL and Crypto lib files:"
#   echo "${CURRENTPATH}/lib/libssl-iOS.a"
#   echo "${CURRENTPATH}/lib/libcrypto-iOS.a"
# fi
# if [ ${#LIBSSL_IOSSIM[@]} -gt 0 ]; then
#   echo "Build library for iOS Simulator..."
#   lipo -create ${LIBSSL_IOSSIM[@]} -output "${CURRENTPATH}/lib/libssl-iOS-Sim.a"
#   lipo -create ${LIBCRYPTO_IOSSIM[@]} -output "${CURRENTPATH}/lib/libcrypto-iOS-Sim.a"
#   echo "\n=====>iOS Simulator SSL and Crypto lib files:"
#   echo "${CURRENTPATH}/lib/libssl-iOS-Sim.a"
#   echo "${CURRENTPATH}/lib/libcrypto-iOS-Sim.a"
# fi

# 合并模拟和真机架构
if [[ ${#LIBSSL_IOS[@]} -gt 0 &&  ${#LIBSSL_IOSSIM[@]} -gt 0 ]]; then
  echo "Build library for iOS..."
  mkdir -p "${CURRENTPATH}/lib/ios"
  lipo -create ${LIBSSL_IOS[@]} ${LIBSSL_IOSSIM[@]} -output "${CURRENTPATH}/lib/ios/libssl.a"
  lipo -create ${LIBCRYPTO_IOS[@]} ${LIBCRYPTO_IOSSIM[@]} -output "${CURRENTPATH}/lib/ios/libcrypto.a"
  echo "\n=====>iOS SSL and Crypto lib files:"
  echo "${CURRENTPATH}/lib/ios/libssl.a"
  echo "${CURRENTPATH}/lib/ios/libcrypto.a"
fi


# Build tvOS/Simulator library if selected for build
if [ ${#LIBSSL_TVOS[@]} -gt 0 ]; then
  echo "Build library for tvOS..."
  mkdir -p "${CURRENTPATH}/lib/tvOS"
  lipo -create ${LIBSSL_TVOS[@]} -output "${CURRENTPATH}/lib/tvOS/libssl-tvOS.a"
  lipo -create ${LIBCRYPTO_TVOS[@]} -output "${CURRENTPATH}/lib/tvOS/libcrypto-tvOS.a"
  echo "\n=====>tvOS SSL and Crypto lib files:"
  echo "${CURRENTPATH}/lib/tvOS/libssl-tvOS.a"
  echo "${CURRENTPATH}/lib/tvOS/libcrypto-tvOS.a"
fi
if [ ${#LIBSSL_TVOSSIM[@]} -gt 0 ]; then
  echo "Build library for tvOS..."
  mkdir -p "${CURRENTPATH}/lib/tvOS"
  lipo -create ${LIBSSL_TVOSSIM[@]} -output "${CURRENTPATH}/lib/tvOS/libssl-tvOS-Sim.a"
  lipo -create ${LIBCRYPTO_TVOSSIM[@]} -output "${CURRENTPATH}/lib/tvOS/libcrypto-tvOS-Sim.a"
  echo "\n=====>tvOS Simulator SSL and Crypto lib files:"
  echo "${CURRENTPATH}/lib/tvOS/libssl-tvOS-Sim.a"
  echo "${CURRENTPATH}/lib/tvOS/libcrypto-tvOS-Sim.a"
fi

# Build watchOS/Simulator library if selected for build
if [ ${#LIBSSL_WATCHOS[@]} -gt 0 ]; then
  echo "Build library for watchOS..."
  mkdir -p "${CURRENTPATH}/lib/watchOS"
  lipo -create ${LIBSSL_WATCHOS[@]} -output "${CURRENTPATH}/lib/watchOS/libssl-watchOS.a"
  lipo -create ${LIBCRYPTO_WATCHOS[@]} -output "${CURRENTPATH}/lib/watchOS/libcrypto-watchOS.a"
  echo "\n=====>watchOS SSL and Crypto lib files:"
  echo "${CURRENTPATH}/lib/watchOS/libssl-watchOS.a"
  echo "${CURRENTPATH}/lib/watchOS/libcrypto-watchOS.a"
fi
if [ ${#LIBSSL_WATCHOSSIM[@]} -gt 0 ]; then
  echo "Build library for watchOS Simulator..."
  mkdir -p "${CURRENTPATH}/lib/watchOS"
  lipo -create ${LIBSSL_WATCHOSSIM[@]} -output "${CURRENTPATH}/lib/watchOS/libssl-watchOS-Sim.a"
  lipo -create ${LIBCRYPTO_WATCHOSSIM[@]} -output "${CURRENTPATH}/lib/watchOS/libcrypto-watchOS-Sim.a"
  echo "\n=====>watchOS Simulator SSL and Crypto lib files:"
  echo "${CURRENTPATH}/lib/lwatchOS/ibssl-watchOS-Sim.a"
  echo "${CURRENTPATH}/lib/watchOS/libcrypto-watchOS-Sim.a"
fi

# Build Catalyst library if selected for build
if [ ${#LIBSSL_CATALYST[@]} -gt 0 ]; then
  echo "Build library for Catalyst..."
  mkdir -p "${CURRENTPATH}/lib/catalyst"
  lipo -create ${LIBSSL_CATALYST[@]} -output "${CURRENTPATH}/lib/catalyst/libssl-Catalyst.a"
  lipo -create ${LIBCRYPTO_CATALYST[@]} -output "${CURRENTPATH}/lib/catalyst/libcrypto-Catalyst.a"
  echo "\n=====>Catalyst SSL and Crypto lib files:"
  echo "${CURRENTPATH}/lib/catalyst/libssl-Catalyst.a"
  echo "${CURRENTPATH}/lib/catalyst/libcrypto-Catalyst.a"
fi

# Copy include directory
mkdir -p "${CURRENTPATH}/include/"
cp -R "${INCLUDE_DIR}" "${CURRENTPATH}/include/"

echo "\n=====>Include directory:"
echo "${CURRENTPATH}/include/"

# Only create intermediate file when building for multiple targets
# For a single target, opensslconf.h is still present in $INCLUDE_DIR (and has just been copied to the target include dir)
if [ ${#OPENSSLCONF_ALL[@]} -gt 1 ]; then

  # Prepare intermediate header file
  # This overwrites opensslconf.h that was copied from $INCLUDE_DIR
  OPENSSLCONF_INTERMEDIATE="${CURRENTPATH}/include/openssl/opensslconf.h"
  # cp "${CURRENTPATH}/include/opensslconf-template.h" "${OPENSSLCONF_INTERMEDIATE}"
  cp "${SCRIPTDIR}/include/opensslconf-template.h" "${OPENSSLCONF_INTERMEDIATE}"

  # Loop all header files
  LOOPCOUNT=0
  for OPENSSLCONF_CURRENT in "${OPENSSLCONF_ALL[@]}" ; do

    # Copy specific opensslconf file to include dir
    cp "${CURRENTPATH}/bin/${OPENSSLCONF_CURRENT}" "${CURRENTPATH}/include/openssl"

    # Determine define condition
    case "${OPENSSLCONF_CURRENT}" in
      *_ios_x86_64.h)
        DEFINE_CONDITION="TARGET_OS_IOS && TARGET_OS_SIMULATOR && TARGET_CPU_X86_64"
      ;;
      *_ios_i386.h)
        DEFINE_CONDITION="TARGET_OS_IOS && TARGET_OS_SIMULATOR && TARGET_CPU_X86"
      ;;
      *_ios_arm64.h)
        DEFINE_CONDITION="TARGET_OS_IOS && (TARGET_OS_EMBEDDED || TARGET_OS_SIMULATOR) && TARGET_CPU_ARM64"
      ;;
      *_ios_arm64e.h)
        DEFINE_CONDITION="TARGET_OS_IOS && TARGET_OS_EMBEDDED && TARGET_CPU_ARM64E"
      ;;
      *_ios_armv7s.h)
        DEFINE_CONDITION="TARGET_OS_IOS && TARGET_OS_EMBEDDED && TARGET_CPU_ARM && defined(__ARM_ARCH_7S__)"
      ;;
      *_ios_armv7.h)
        DEFINE_CONDITION="TARGET_OS_IOS && TARGET_OS_EMBEDDED && TARGET_CPU_ARM && !defined(__ARM_ARCH_7S__)"
      ;;
      *_catalyst_x86_64.h)
        DEFINE_CONDITION="(TARGET_OS_MACCATALYST || (TARGET_OS_IOS && TARGET_OS_SIMULATOR)) && TARGET_CPU_X86_64"
      ;;
      *_catalyst_arm64.h)
        DEFINE_CONDITION="(TARGET_OS_MACCATALYST || (TARGET_OS_IOS && TARGET_OS_SIMULATOR)) && TARGET_CPU_ARM64"
      ;;
      *_tvos_x86_64.h)
        DEFINE_CONDITION="TARGET_OS_TV && TARGET_OS_SIMULATOR && TARGET_CPU_X86_64"
      ;;
      *_tvos_arm64.h)
        DEFINE_CONDITION="TARGET_OS_TV && TARGET_OS_EMBEDDED && TARGET_CPU_ARM64"
      ;;
      *_watchos_i386.h)
        DEFINE_CONDITION="TARGET_OS_WATCH && TARGET_OS_SIMULATOR && TARGET_CPU_X86"
      ;;
      *_watchos_x86_64.h)
        DEFINE_CONDITION="TARGET_OS_WATCH && TARGET_OS_SIMULATOR && TARGET_CPU_X86_64"
      ;;
      *_watchos_armv7k.h)
        DEFINE_CONDITION="TARGET_OS_WATCH && TARGET_CPU_ARM"
      ;;
      *_watchos_arm64.h)
        DEFINE_CONDITION="TARGET_OS_WATCH && TARGET_CPU_ARM64"
      ;;
      *_watchos_arm64_32.h)
        DEFINE_CONDITION="TARGET_OS_WATCH && TARGET_CPU_ARM64"
      ;;
      *)
        # Don't run into unexpected cases by setting the default condition to false
        DEFINE_CONDITION="0"
      ;;
    esac

    # Determine loopcount; start with if and continue with elif
    LOOPCOUNT=$((LOOPCOUNT + 1))
    if [ ${LOOPCOUNT} -eq 1 ]; then
      echo "#if ${DEFINE_CONDITION}" >> "${OPENSSLCONF_INTERMEDIATE}"
    else
      echo "#elif ${DEFINE_CONDITION}" >> "${OPENSSLCONF_INTERMEDIATE}"
    fi

    # Add include
    echo "# include <openssl/${OPENSSLCONF_CURRENT}>" >> "${OPENSSLCONF_INTERMEDIATE}"
  done

  # Finish
  echo "#else" >> "${OPENSSLCONF_INTERMEDIATE}"
  echo '# error Unable to determine target or target not included in OpenSSL build' >> "${OPENSSLCONF_INTERMEDIATE}"
  echo "#endif" >> "${OPENSSLCONF_INTERMEDIATE}"
fi

echo "Done."

