#!/usr/bin/env bash

# Script that is used by CI to build the static libs, or by external users to download a build from
# Github. Will do nothing if there already is a copy of the static libs in external.
#
# Adjust the 'version' variable as needed to get the right version for the current code.
#

set -e

if [ "${1:-}" == "--verify-only" ]; then
    verify_only=true
    shift
else
    verify_only=false
fi

if [ "${1:-}" == "--staging" ]; then
    staging_repo=true
    shift
else
    staging_repo=false
fi

# macOS does not have realpath and readlink does not have -f option, so do this instead:
my_dir=$( cd "$(dirname "$0")" ; pwd -P )

cd "$my_dir"
code_dir="${my_dir}/external/objectbox"
dest_dir="${my_dir}/external/objectbox-static"

if [ "$verify_only" = true ]; then
  echo "Skipping fetch, only verifying"
else

if [ -d "$code_dir" ] && [ "$staging_repo" != "true" ]; then # Do we have an existing code repo? Then build it...
    xcode_version="$(xcodebuild -version | head -n 1 | tr -cd '[a-zA-Z0-9]._-')"
    echo "Xcode version: $xcode_version"

    pushd "$code_dir"  # note: this also "fixed" building into cbuild dir in "our" objectbox-swift dir
    build_params="" # must also part of the cache key
    commit_id=$(git rev-parse HEAD)
    cache_dir="$HOME/Library/Caches/ObjectBox"
    mkdir -p "${cache_dir}"
    find "${cache_dir}" -name "objectbox-static-*.zip" -type f -mtime +30 # -delete # TODO enable delete once this looks good
    cache_key="${commit_id}-$xcode_version"
    if [ -n "$build_params" ]; then
      cache_key="${cache_key}-$(echo "$build_params" | tr -cd '[a-zA-Z0-9]._-')"
    fi
    cache_zip="${cache_dir}/objectbox-static-${cache_key}.zip"
    do_build=true
    git_clean=false
    git_status=$(git status --porcelain)
    # ignore untracked uws submodule (left over when switching from a sync to a non-sync branch)
    git_status=${git_status#"?? objectbox/src/main/cpp/external/uws-objectbox/"}
     # Note: doing a mini pause so the color state emoji can be perceived before scrolling it off the screen
    if [ -z "$git_status" ]; then
      git_clean=true
      if [ -f "${cache_zip}" ]; then
        echo "🟢 ObjectBox core is clean and cache ZIP found for ${cache_key}."
        echo "📦 Extracting..."
        sleep 0.5
        unzip -o "${cache_zip}" -d "${dest_dir}"
        do_build=false
      else
        echo "⚪ ObjectBox core is clean but no cache ZIP found for ${cache_key}."
        echo "🏗️ Building..."
        sleep 0.5
      fi
    else
      git status
      echo "🔴 ObjectBox core is not clean, won't use caching. 🏗️ Building..."
      echo "🏗️ Building..."
      sleep 0.5
    fi
    if [ "$do_build" = true ]; then
      "$code_dir/scripts/apple-build-static-libs.sh" $build_params "$dest_dir" release
      if [ "$git_clean" = true ] ; then  # clean before?
        git_status=${git_status#"?? objectbox/src/main/cpp/external/uws-objectbox/"}
        if [ -z "$git_status" ]; then  # still clean
          cp "${dest_dir}/objectbox-static.zip" "${cache_zip}"
          echo "Cache ZIP created: ${cache_zip}"
        else
          echo "Git status is not clean anymore; skipped caching the ZIP"
        fi
      fi
    fi
    popd
else # Download static public release and unzip into $dest
    if [ ! -d "${dest_dir}" ] || [ ! -e "${dest_dir}/libObjectBoxCore-iOS.a" ]; then
        version=1.7.0
        c_version=0.15.2
        archive_path="${my_dir}/external/objectbox-static.zip"
        if [ "$staging_repo" == "true" ]; then
          release_url_path="https://github.com/objectbox/objectbox-swift-spec-staging/releases/download/v1.x"
        else
          release_url_path="https://github.com/objectbox/objectbox-swift/releases/download/v${version}"
        fi
        OBXLIB_URL_apple_static="release_url_path/ObjectBoxCore-static-${c_version}.zip"

        mkdir -p "${dest_dir}"

        curl -L --fail "${OBXLIB_URL_apple_static}" --output "${archive_path}"

        pushd "${dest_dir}"
        unzip "${archive_path}"
        popd

        if [ -d "${dest_dir}/build-artifacts/" ]; then
            mv "${dest_dir}/build-artifacts/"* "${dest_dir}/"
            rm -r "${dest_dir}/build-artifacts/"
        fi

        rm "${archive_path}"
    fi
fi
fi # verify_only

# Update the header file actually used by our Swift sources
c_header_dir="ios-framework/CommonSource/Internal"
cp "$dest_dir/objectbox.h" "${c_header_dir}/objectbox-c.h"
cp "$dest_dir/objectbox-sync.h" "${c_header_dir}/objectbox-c-sync.h"
sed -i '' 's/#include "objectbox.h"/#include "objectbox-c.h"/' "${c_header_dir}/objectbox-c-sync.h"

# Print versions for allow verification of built libs (is it the one we expect?)
echo "============================================================================================"
echo "Please check that the found libs are available (macOS, iOS) and contain the expected symbols"
echo "Available libs in '$dest_dir':"
cd ${dest_dir}
for filename in ./*.a; do
  echo ""
  ls -lha "$filename"
  # Match our version/date pattern like "2.6.1-2020-06-09"
  obx_version=$(strings "$filename" | grep "[0-9]\.[0-9]\.[0-9]-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]")
  echo "  >> Version found: $obx_version"
  obx_symbols=$(nm -gj "$filename" | grep -c obx_) || true
  obx_sync_symbols=$(nm -gj "$filename" | grep -c obx_sync_) || true
  # Also include "external libs" to expose potential build problems
  obx_lws_symbols=$(nm -gj "$filename" | grep -c lws_) || true
  obx_mbedtls_symbols=$(nm -gj "$filename" | grep -c mbedtls_) || true
  echo "  >> Symbols found: $obx_symbols obx, $obx_sync_symbols obx_sync, $obx_lws_symbols lws, $obx_mbedtls_symbols mbedtls"
  obx_archs=$(lipo -archs "$filename")
  echo "  >> Architectures: $obx_archs"
  sha=($(shasum -a 256 "$filename"))
  echo "  >> SHA256: $sha"
done