#!/usr/bin/env bash
#
# This file is part of the KubeVirt project
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Copyright 2017 Red Hat, Inc.
#

set -e

source hack/common.sh
source hack/config.sh

skipj2=false
if [ "$1" == "--skipj2" ]; then
    skipj2=true
fi

manifest_docker_prefix=${manifest_docker_prefix-${docker_prefix}}
kubevirt_logo_path="assets/kubevirt_logo.png"

rm -rf ${MANIFESTS_OUT_DIR}
rm -rf ${MANIFEST_TEMPLATES_OUT_DIR}

(cd ${KUBEVIRT_DIR}/tools/manifest-templator/ && go build)

# first process file includes only
args=$(cd ${KUBEVIRT_DIR}/manifests && find . -type f -name "*.yaml.in" -not -path "./generated/*")
for arg in $args; do
    infile=${KUBEVIRT_DIR}/manifests/${arg}
    outfile=${KUBEVIRT_DIR}/manifests/${arg}.tmp

    ${KUBEVIRT_DIR}/tools/manifest-templator/manifest-templator \
        --process-files \
        --generated-manifests-dir=${KUBEVIRT_DIR}/manifests/generated/ \
        --input-file=${infile} >${outfile}
done

bundle_out_dir=${MANIFESTS_OUT_DIR}/release/olm/bundle

# potentially parse image push log file for getting sha sums of virt images
source hack/parse-shasums.sh

# then process variables
args=$(cd ${KUBEVIRT_DIR}/manifests && find . -type f -name "*.yaml.in.tmp")
for arg in $args; do

    infile=${KUBEVIRT_DIR}/manifests/${arg}

    final_out_dir=$(dirname ${MANIFESTS_OUT_DIR}/${arg})
    mkdir -p ${final_out_dir}

    final_templates_out_dir=$(dirname ${MANIFEST_TEMPLATES_OUT_DIR}/${arg})
    mkdir -p ${final_templates_out_dir}

    manifest=$(basename -s .in.tmp ${arg})
    manifest="${manifest/VERSION/${csv_version}}"

    outfile=${final_out_dir}/${manifest}
    template_outfile=${final_templates_out_dir}/${manifest}.j2

    ${KUBEVIRT_DIR}/tools/manifest-templator/manifest-templator \
        --process-vars \
        --namespace=${namespace} \
        --cdi-namespace=${cdi_namespace} \
        --csv-namespace=${csv_namespace} \
        --container-prefix=${manifest_docker_prefix} \
        --image-prefix=${image_prefix} \
        --container-tag=${docker_tag} \
        --image-pull-policy=${image_pull_policy} \
        --verbosity=${verbosity} \
        --csv-version=${csv_version} \
        --kubevirt-logo-path=${kubevirt_logo_path} \
        --package-name=${package_name} \
        --input-file=${infile} \
        --bundle-out-dir=${bundle_out_dir} \
        --quay-repository=${QUAY_REPOSITORY} \
        --virt-operator-sha=${VIRT_OPERATOR_SHA} \
        --virt-api-sha=${VIRT_API_SHA} \
        --virt-controller-sha=${VIRT_CONTROLLER_SHA} \
        --virt-handler-sha=${VIRT_HANDLER_SHA} \
        --virt-launcher-sha=${VIRT_LAUNCHER_SHA} \
        >${outfile}

    if [ "$skipj2" = true ]; then
        echo "skipping j2 template for $infile"
        continue
    fi

    ${KUBEVIRT_DIR}/tools/manifest-templator/manifest-templator \
        --process-vars \
        --namespace="{{ namespace }}" \
        --cdi-namespace="{{ cdi_namespace }}" \
        --container-prefix="{{ docker_prefix }}" \
        --container-tag="{{ docker_tag }}" \
        --image-pull-policy="{{ image_pull_policy }}" \
        --verbosity=${verbosity} \
        --csv-version=${csv_version} \
        --kubevirt-logo-path=${kubevirt_logo_path} \
        --package-name=${package_name} \
        --input-file=${infile} \
        --quay-repository=${QUAY_REPOSITORY} \
        >${template_outfile}
done

# Remove tmp files
(cd ${KUBEVIRT_DIR}/manifests && find . -type f -name "*.yaml.in.tmp" -exec rm {} \;)

# Remove empty lines at the end of files which are added by go templating
find ${MANIFESTS_OUT_DIR}/ -type f -exec sed -i {} -e '${/^$/d;}' \;
find ${MANIFEST_TEMPLATES_OUT_DIR}/ -type f -exec sed -i {} -e '${/^$/d;}' \;

# we can't test this when we have image shasums, because shassums are not used in templates, so they will always differ
if [ "$skipj2" = true ] || [ ! -z $VIRT_OPERATOR_SHA ]; then
    exit 0
fi

# make sure that template manifests align with release manifests
export namespace=${namespace}
export cdi_namespace=${cdi_namespace}
export docker_tag=${docker_tag}
export docker_prefix=${manifest_docker_prefix}
export image_pull_policy=${image_pull_policy}

TMP_DIR=$(mktemp -d)
cleanup() {
    ret=$?
    rm -rf "${TMP_DIR}"
    exit ${ret}
}
trap "cleanup" INT TERM EXIT

for file in $(find ${MANIFEST_TEMPLATES_OUT_DIR}/ -type f); do
    mkdir -p ${TMP_DIR}/$(dirname ${file})
    j2 ${file} | sed -e '/.$/a\' >${TMP_DIR}/${file%.j2}
done

# If diff fails then we have an issue
diff -ru -x "bundle" ${MANIFESTS_OUT_DIR} ${TMP_DIR}/${MANIFEST_TEMPLATES_OUT_DIR} || (
    echo "Error: Generated manifests don't match"
    false
)
