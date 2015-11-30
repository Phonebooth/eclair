#!/bin/bash -e
readonly TARGET="/tmp/configstaging"

function config-target {
    mkdir -p "$TARGET"
}

function config-download {
    local app_target
    app_target="$1"
    local s3_root
    s3_root=$(find-s3-root)
    config-target
    s3cmd sync s3://"$s3_root"/"$app_target" "$TARGET"
}

function config-upload {
    local app_target
    app_target="$1"
    local s3_root
    s3_root=$(find-s3-root)
    s3cmd sync "$TARGET"/"$app_target"/ s3://"$s3_root"/"$app_target"/
}

function find-s3-root {
    # hack
    grep root .eclair/secure.config | awk -F\" '{print $2}'
}

function main {
    local command
    command="$1"
    local app_target
    app_target="$2"
    case "$command" in
        "download")
            config-download "$app_target"
            ;;
        "upload")
            config-upload "$app_target"
            ;;
        *)
            echo "Error. Bad command: $command" 1>&2
            exit 1
            ;;
    esac
}

main $@
