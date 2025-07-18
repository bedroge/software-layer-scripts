#!/bin/bash

set -e

base_dir=$(dirname $(realpath $0))

if [ $# -ne 5 ]; then
    echo "ERROR: Usage: $0 <EESSI tmp dir (example: /tmp/$USER/EESSI)> <version (example: 2023.06)> <CPU arch subdir (example: x86_64/amd/zen2)> <accelerator subdir (example: accel/nvidia/cc80)> <path to tarball>" >&2
    exit 1
fi
eessi_tmpdir=$1
eessi_version=$2
cpu_arch_subdir=$3
accel_subdir=$4
target_tgz=$5

tmpdir=`mktemp -d`
echo ">> tmpdir: $tmpdir"

os="linux"
source ${base_dir}/init/eessi_defaults
cvmfs_repo=${EESSI_CVMFS_REPO}
software_dir="${cvmfs_repo}/versions/${eessi_version}/software/${os}/${cpu_arch_subdir}"
if [ ! -d ${software_dir} ]; then
    echo "Software directory ${software_dir} does not exist?!" >&2
    exit 2
fi

# Need to extract the cvmfs_repo_name from the cvmfs_repo variable
# - remove /${EESSI_DEV_PROJECT} from the end (if it exists)
# - remove /cvmfs/ from the beginning
cvmfs_repo_name=${cvmfs_repo%"/${EESSI_DEV_PROJECT}"}
cvmfs_repo_name=${cvmfs_repo_name#/cvmfs/}
overlay_upper_dir="${eessi_tmpdir}/${cvmfs_repo_name}/overlay-upper${EESSI_DEV_PROJECT:+/$EESSI_DEV_PROJECT}"

software_dir_overlay="${overlay_upper_dir}/versions/${eessi_version}"
if [ ! -d ${software_dir_overlay} ]; then
    echo "Software directory overlay ${software_dir_overlay} does not exist?!" >&2
    exit 3
fi

current_workdir=${PWD}
cd ${overlay_upper_dir}/versions/
echo ">> Collecting list of files/directories to include in tarball via ${PWD}..."

files_list=${tmpdir}/files.list.txt
module_files_list=${tmpdir}/module_files.list.txt

if [ -d ${eessi_version}/software/${os}/${cpu_arch_subdir}/.lmod ]; then
    # include Lmod cache and configuration file (lmodrc.lua),
    # skip whiteout files (.wh.*) and backup copies of Lmod cache (spiderT.old.*)
    find ${eessi_version}/software/${os}/${cpu_arch_subdir}/.lmod -type f \( \! -name 'spiderT.old.*' -a \! -name '.wh.*' \) >> ${files_list}
fi

# include scripts that were copied by install_scripts.sh, which we want to ship in EESSI repository
if [ -d ${eessi_version}/scripts ]; then
    find ${eessi_version}/scripts -type f \! -name '.wh.*' >> ${files_list}
fi

# also include init, which is also copied by install_scripts.sh
if [ -d ${eessi_version}/init ]; then
    find ${eessi_version}/init -type f \! -name '.wh.*' >> ${files_list}
fi

# consider both CPU-only and accelerator subdirectories (if an accelerator was configured)
sw_subdirs=${cpu_arch_subdir}
if [ -n "${accel_subdir}" ]; then
    sw_subdirs="${sw_subdirs} ${cpu_arch_subdir}/${accel_subdir}"
fi
for subdir in ${sw_subdirs}; do

    if [ -d ${eessi_version}/software/${os}/${subdir}/modules ]; then
        # module files
        find ${eessi_version}/software/${os}/${subdir}/modules -type f \! -name '.wh.*' >> ${files_list}
        # module symlinks
        find ${eessi_version}/software/${os}/${subdir}/modules -type l \! -name '.wh.*' >> ${files_list}
        # module files and symlinks
        find ${eessi_version}/software/${os}/${subdir}/modules/all -type f,l \! -name '.wh.*' \
            | grep -v '/\.modulerc\.lua' | sed -e 's/.lua$//' | sed -e 's@.*/modules/all/@@g' | sort -u \
            >> ${module_files_list}
    fi

    if [ -d ${eessi_version}/software/${os}/${subdir}/software -a -r ${module_files_list} ]; then
        # installation directories but only those for which module files were created
        # Note, we assume that module names (as defined by 'PACKAGE_NAME/VERSION.lua'
        # using EasyBuild's standard module naming scheme) match the name of the
        # software installation directory (expected to be 'PACKAGE_NAME/VERSION/').
        # If either side changes (module naming scheme or naming of software
        # installation directories), the procedure will likely not work.
        for package_version in $(cat ${module_files_list}); do
            echo "handling ${package_version}"
            find ${eessi_version}/software/${os}/${subdir}/software/${package_version} -maxdepth 0 -type d \! -name '.wh.*' >> ${files_list}
            # if there is a directory for this installation in the stack's reprod directory, include that too
            if [ -d ${eessi_version}/software/${os}/${subdir}/reprod ]; then
                find ${eessi_version}/software/${os}/${subdir}/reprod/${package_version} -maxdepth 0 -type d \! -name '.wh.*' >> ${files_list}
            fi
        done
    fi

done

# add a bit debug output
if [ -r ${files_list} ]; then
    echo "wrote file list to ${files_list}"
    cat ${files_list}
fi
if [ -r ${module_files_list} ]; then
    echo "wrote module file list to ${module_files_list}"
    cat ${module_files_list}

    # Copy the module files list to current workindg dir for later use in the test step
    cp ${module_files_list} ${current_workdir}/module_files.list.txt
fi

topdir=${cvmfs_repo}/versions/

echo ">> Creating tarball ${target_tgz} from ${topdir}..."
tar cfvz ${target_tgz} -C ${topdir} --files-from=${files_list}

echo ${target_tgz} created!

echo ">> Cleaning up tmpdir ${tmpdir}..."
rm -r ${tmpdir}
